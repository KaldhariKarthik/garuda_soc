// =============================================================================
// GARUDA SoC - Block 21 : clock divider
// clk_div.v
//
// Spec: GARUDA-CLKRST-SPEC-001 Rev 2.0 (Rev 4.0 set), Sec.5.1, Sec.7.1, Sec.7.6
//       Rulings: Docs/DECISIONS.md D-5 (pclk exists), D-14 (always-on clock)
//
//   refclk 500 MHz --> [/2 toggle] - t1 (250 MHz) -> aon_clk, and DIV2 source
//                           |
//                           `-> [3-bit counter clocked by t1] - t2, t3, t4
//
//   hclk_o = one of t1/t2/t3/t4 (DIV 2/4/8/16), switched glitch-free
//   pclk_o = hclk / 2 toggle flop, 50% duty (blocking assignment: SIM-1, below)
// pclk_phase_o = 1 on the hclk cycle whose closing edge raises pclk (own flop)
//
// -----------------------------------------------------------------------------
// WHY t2..t4 ARE A COUNTER ON t1 (and not on refclk, and not a ripple chain)
// -----------------------------------------------------------------------------
// [N-7.19]/[R-10]: the refclk net may reach exactly one flop, the pad-adjacent
// toggle `u_t1`. Everything else is clocked by its output or slower. A 4-bit
// counter on refclk would put four flops and an adder on the 500 MHz net.
//
// CHANGE PD-11 (2026-11-12). t2, t3 and t4 were a ripple chain: t3 was clocked
// by t2 and t4 by t3. Each stage added one clock-to-Q and one clock buffer
// stage to the clock it made, so in the ASAP7 run hclk at DIV16 arrived
// ~535 ps after aon_clk (t1) and aon_clk -> hclk/pclk paths failed hold at
// DIV4/8/16 only (PD-9). Now all three are flops on t1, so t2, t3 and t4 come
// out of the same clock edge with the same insertion delay at every DIVSEL.
// The waveforms are the same as the ripple chain's, cycle for cycle: t2
// toggles on every t1 rising edge; t3 toggles on the t1 edge where t2 rises
// (t2 was 0); t4 toggles on the edge where t3 rises (t2 and t3 were 0).
//
// Every flop changes on a RISING edge of t1, so every rising edge of t2/t3/t4
// coincides with a rising edge of t1 (and of refclk). That is what makes
// hclk/pclk a synchronous multi-frequency set at any DIVSEL: every pclk rising
// edge is an hclk rising edge ([N-7.4]).
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
// pclk resets high so pclk_phase_o resets low (Sec.5.1 reset value).
// =============================================================================

module clk_div
    import garuda_pkg::*;
(
    input wire refclk,  // 500 MHz, pad
    input wire ext_rst_n,  // ext_rst_n, unstretched, unsynchronised
    // 00=DIV2 01=DIV4 10=DIV8 11=DIV16 (RSTCTL.DIVSEL)
    input wire [DIV_SEL_W-1:0] div_sel_i,
    output reg aon_clk,  // refclk/2, always on, ratio-independent (D-14)
    output wire hclk,  // 250 MHz at DIV2
    output wire pclk,  // hclk/2
    output wire pclk_phase_o,  // hclk domain
    output wire [DIV_SEL_W-1:0] div_act_o,  // CLKSTAT.DIVACT
    // CLKSTAT.DIVBUSY
    output wire div_busy_o
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned SEL_REQ_W = 32'd2;
    localparam int unsigned SEL_ACT_W = 32'd2;

    // ---- the only 500 MHz flop in the chip ([N-7.1]) ------------------------
    always_ff @(posedge refclk or negedge ext_rst_n) begin : p_aon_clk
        if (!ext_rst_n) begin
            aon_clk <= 1'b0;
        end else begin
            aon_clk <= ~aon_clk;
        end
    end

    // ---- programmable further division, all three flops clocked by t1 -------
    // (PD-11: was a ripple chain t1 -> t2 -> t3 -> t4; same waveforms.)
    reg t2_q;
    reg t3_q;
    reg t4_q;
    always_ff @(posedge aon_clk or negedge ext_rst_n) begin : p_tx
        if (!ext_rst_n) begin
            t2_q <= 1'b0;
            t3_q <= 1'b0;
            t4_q <= 1'b0;
        end else begin
            t2_q <= ~t2_q;
            t3_q <= t3_q ^ ~t2_q;  // toggles where t2 rises
            t4_q <= t4_q ^ (~t2_q & ~t3_q);  // toggles where t3 rises
        end
    end

    // ---- ratio select -------------------------------------------------------
    // div_sel_i comes from a pclk-domain register. It is first registered on
    // the t1 rising edge (a synchronous path: pclk edges are t1 edges), then
    // moved into the active select on the t1 falling edge at the all-low point.
    reg [SEL_REQ_W-1:0] sel_req_q;
    always_ff @(posedge aon_clk or negedge ext_rst_n) begin : p_sel_req
        if (!ext_rst_n) begin
            sel_req_q <= 2'b00;
        end else begin
            sel_req_q <= div_sel_i;
        end
    end

    // At a t1 falling edge t2..t4 are stable (they only move on t1 rising
    // edges); if all are low they will all rise on the next t1 rising edge.
    wire all_low_next = ~t2_q & ~t3_q & ~t4_q;

    reg [SEL_ACT_W-1:0] sel_act_q;
    always_ff @(negedge aon_clk or negedge ext_rst_n) begin : p_sel_act
        if (!ext_rst_n) begin
            sel_act_q <= 2'b00;
        end else if (all_low_next) begin
            sel_act_q <= sel_req_q;
        end
    end

    // Output clock mux. Select only changes while every input is low.
    wire hclk_mux = (sel_act_q == 2'b00) ? aon_clk :
                    (sel_act_q == 2'b01) ? t2_q    :
                    (sel_act_q == 2'b10) ? t3_q    : t4_q;

    // ---- pclk = hclk / 2 toggle ([N-7.3]) -----------------------------------
    // ERRATUM SIM-1 (2026-10-14). pclk is a CLOCK made by a flop on hclk.
    // Written with a non-blocking assignment, the pclk edge reached the
    // simulator one step AFTER every hclk flop had taken its new value, so a
    // pclk flop that captures from an hclk flop saw the value launched on that
    // same edge. On silicon the two clock trees are balanced and it sees the
    // value from before the edge. RTL simulation and the chip disagreed by one
    // hclk cycle on every such capture: a WDTVAL read returned one count less
    // than the chip will. The assignment below is BLOCKING for that reason and
    // no other: the pclk edge is then in the same simulation step as the hclk
    // edge, before any non-blocking update, as two balanced clocks are.
    // Synthesis builds the same toggle flop. (HAL reports the blocking
    // assignment in a clocked block; it is waived in
    // flow/2_static/hal_waivers.txt with this reason.)
    reg pclk_q;
    always_ff @(posedge hclk_mux or negedge ext_rst_n) begin : p_pclk
        if (!ext_rst_n) begin
            pclk_q = 1'b1;
        end else begin
            pclk_q = ~pclk_q;
        end
    end

    // pclk_phase is DATA in the hclk domain: 1 in the hclk cycle whose closing
    // edge raises pclk. It has a flop of its own, non-blocking like every other
    // hclk flop, so that hclk logic sampling it has no race against the
    // blocking toggle above; it is ~pclk_q at every instant between edges.
    reg phase_q;
    always_ff @(posedge hclk_mux or negedge ext_rst_n) begin : p_phase
        if (!ext_rst_n) begin
            phase_q <= 1'b0;
        end else begin
            phase_q <= ~phase_q;
        end
    end

    assign hclk       = hclk_mux;
    assign pclk       = pclk_q;
    assign pclk_phase_o = phase_q;
    assign div_act_o    = sel_act_q;
    assign div_busy_o   = (sel_act_q != sel_req_q) || (sel_req_q != div_sel_i);

endmodule
