`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 21 : clock divider
// clk_div.v
//
// Spec: GARUDA-CLKRST-SPEC-001 Rev 2.0 (Rev 4.0 set), §5.1, §7.1, §7.6
//       Rulings: Docs/DECISIONS.md D-5 (pclk exists), D-14 (always-on clock)
//
//   refclk 500 MHz ──▶ [÷2 toggle] ─ t1 (250 MHz) ─▶ aon_clk_o, and DIV2 source
//                           │
//                           └─▶ [÷2]─ t2 ─▶ [÷2]─ t3 ─▶ [÷2]─ t4   (ripple)
//
//   hclk_o = one of t1/t2/t3/t4 (DIV 2/4/8/16), switched glitch-free
//   pclk_o = hclk ÷ 2 toggle flop, 50% duty (blocking assignment: SIM-1, below)
//   pclk_phase_o = 1 on the hclk cycle whose closing edge raises pclk (own flop)
//
// -----------------------------------------------------------------------------
// WHY A RIPPLE CHAIN (and not a counter)
// -----------------------------------------------------------------------------
// [N-7.19]/[R-10]: the refclk net may reach exactly one flop, the pad-adjacent
// toggle `u_t1`. Everything else is clocked by its output or slower. A 4-bit
// counter on refclk would put four flops and an adder on the 500 MHz net.
//
// Every toggle flop changes on the RISING edge of its source, so every rising
// edge of t2/t3/t4 coincides with a rising edge of t1 (and of refclk). That is
// what makes hclk/pclk a synchronous multi-frequency set at any DIVSEL: every
// pclk rising edge is an hclk rising edge ([N-7.4]).
//
// -----------------------------------------------------------------------------
// GLITCH-FREE RATIO CHANGE ([N-7.5])
// -----------------------------------------------------------------------------
// Once every 16 refclk cycles the chain passes through t4..t1 = 0000, after
// which all four rise on the same edge. Immediately before that common edge
// all four candidates are low for a full refclk period. The active select
// (`sel_act_q`) is updated only on the t1 FALLING edge that enters that
// all-low interval, so the output mux switches between two inputs that are
// both low and both about to rise together. The first pulse at the new ratio
// is a full high phase of the new ratio; no pulse is shorter than half the
// faster ratio's period. `div_busy_o` is high while the request differs from
// the active ratio.
//
// -----------------------------------------------------------------------------
// RESET ([N-7.16])
// -----------------------------------------------------------------------------
// The divider flops use raw_rst_n_i (ext_rst_n straight from the pad): the
// divider must run during reset, because the reset stretch counter and the
// release synchronisers are clocked from it. The select resets to DIV2.
// pclk resets high so pclk_phase_o resets low (§5.1 reset value).
// =============================================================================

module clk_div (
    input  wire       refclk_i,       // 500 MHz, pad
    input  wire       raw_rst_n_i,    // ext_rst_n, unstretched, unsynchronised
    input  wire [1:0] div_sel_i,      // 00=DIV2 01=DIV4 10=DIV8 11=DIV16 (RSTCTL.DIVSEL)

    output wire       aon_clk_o,      // refclk/2, always on, ratio-independent (D-14)
    output wire       hclk_o,         // 250 MHz at DIV2
    output wire       pclk_o,         // hclk/2
    output wire       pclk_phase_o,   // hclk domain
    output wire [1:0] div_act_o,      // CLKSTAT.DIVACT
    output wire       div_busy_o      // CLKSTAT.DIVBUSY
);

    // ---- the only 500 MHz flop in the chip ([N-7.1]) ------------------------
    reg t1_q;
    always @(posedge refclk_i or negedge raw_rst_n_i)
        if (!raw_rst_n_i) t1_q <= 1'b0;
        else              t1_q <= ~t1_q;

    // ---- programmable further division, clocked from t1 and below ------------
    reg t2_q, t3_q, t4_q;
    always @(posedge t1_q or negedge raw_rst_n_i)
        if (!raw_rst_n_i) t2_q <= 1'b0;
        else              t2_q <= ~t2_q;

    always @(posedge t2_q or negedge raw_rst_n_i)
        if (!raw_rst_n_i) t3_q <= 1'b0;
        else              t3_q <= ~t3_q;

    always @(posedge t3_q or negedge raw_rst_n_i)
        if (!raw_rst_n_i) t4_q <= 1'b0;
        else              t4_q <= ~t4_q;

    // ---- ratio select --------------------------------------------------------
    // div_sel_i comes from a pclk-domain register. It is first registered on
    // the t1 rising edge (a synchronous path: pclk edges are t1 edges), then
    // moved into the active select on the t1 falling edge at the all-low point.
    reg [1:0] sel_req_q;
    always @(posedge t1_q or negedge raw_rst_n_i)
        if (!raw_rst_n_i) sel_req_q <= 2'b00;
        else              sel_req_q <= div_sel_i;

    // At a t1 falling edge t2..t4 are stable (they only move on t1 rising
    // edges); if all are low they will all rise on the next t1 rising edge.
    wire all_low_next = ~t2_q & ~t3_q & ~t4_q;

    reg [1:0] sel_act_q;
    always @(negedge t1_q or negedge raw_rst_n_i)
        if (!raw_rst_n_i)      sel_act_q <= 2'b00;
        else if (all_low_next) sel_act_q <= sel_req_q;

    // Output clock mux. Select only changes while every input is low.
    reg hclk_mux;
    always @(*) begin
        case (sel_act_q)
            2'b00:   hclk_mux = t1_q;
            2'b01:   hclk_mux = t2_q;
            2'b10:   hclk_mux = t3_q;
            default: hclk_mux = t4_q;
        endcase
    end

    // ---- pclk = hclk / 2 toggle ([N-7.3]) ------------------------------------
    // ERRATUM SIM-1 (2026-10-14). pclk is a CLOCK made by a flop on hclk. Written
    // with a non-blocking assignment, the pclk edge reached the simulator one
    // step AFTER every hclk flop had taken its new value, so a pclk flop that
    // captures from an hclk flop saw the value launched on that same edge. On
    // silicon the two clock trees are balanced and it sees the value from
    // before the edge. RTL simulation and the chip disagreed by one hclk cycle
    // on every such capture: a WDTVAL read returned one count less than the chip
    // will. The assignment below is BLOCKING for that reason and no other: the
    // pclk edge is then in the same simulation step as the hclk edge, before
    // any non-blocking update, as two balanced clocks are. Synthesis builds the
    // same toggle flop. (HAL reports the blocking assignment in a clocked
    // block; it is waived in flow/2_static/hal_waivers.txt with this reason.)
    reg pclk_q;
    always @(posedge hclk_mux or negedge raw_rst_n_i)
        if (!raw_rst_n_i) pclk_q = 1'b1;
        else              pclk_q = ~pclk_q;

    // pclk_phase is DATA in the hclk domain: 1 in the hclk cycle whose closing
    // edge raises pclk. It has a flop of its own, non-blocking like every other
    // hclk flop, so that hclk logic sampling it has no race against the
    // blocking toggle above; it is ~pclk_q at every instant between edges.
    reg phase_q;
    always @(posedge hclk_mux or negedge raw_rst_n_i)
        if (!raw_rst_n_i) phase_q <= 1'b0;
        else              phase_q <= ~phase_q;

    assign aon_clk_o    = t1_q;
    assign hclk_o       = hclk_mux;
    assign pclk_o       = pclk_q;
    assign pclk_phase_o = phase_q;
    assign div_act_o    = sel_act_q;
    assign div_busy_o   = (sel_act_q != sel_req_q) || (sel_req_q != div_sel_i);

endmodule

`default_nettype wire
