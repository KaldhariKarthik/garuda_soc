`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 21 FPGA substitute : clk_div (KV260 prototype ONLY)
// rtl/fpga/clk_div_fpga.v
//
// SAME MODULE NAME AND PORTS as rtl/clk_div/clk_div.v. The FPGA filelist
// (fpga/kv260/filelist_fpga.f) compiles this file INSTEAD of the ASIC one.
// The ASIC file is not touched and nothing here reaches the ASIC flow.
//
// WHY: the ASIC divider is a ripple chain of toggle flops plus a clock mux.
// That puts generated clocks on fabric routing. On an FPGA they get no
// global-buffer skew control, and hold closure on the hclk<->pclk paths is
// not guaranteed.
//
//   refclk_i (raw MMCM CLKOUT0, NOT a BUFG output)
//        ├──▶ BUFGCE_DIV /1 ──▶ hclk_o  (= aon_clk_o)
//        └──▶ BUFGCE_DIV /2 ──▶ pclk_o
//
// Two BUFGCE_DIVs driven by the same source put both clocks on matched
// global routing. Every pclk rising edge coincides with an hclk rising edge,
// which is the ASIC's [N-7.4] property, so hclk<->pclk stays a synchronous,
// Vivado-timed pair with no CDC. That is the same as silicon (D-5).
//
// DEVIATIONS FROM SPEC (FPGA-only, flagged):
//   FD-1  refclk is the MMCM output at the hclk rate, not 500 MHz.
//         aon_clk = hclk, not refclk/2. Any logic on aon_clk runs at the
//         hclk rate, so reset stretch lengths in TIME scale by the ratio.
//         In CYCLES they are unchanged.
//   FD-2  DIVSEL is not applied. div_act_o echoes div_sel_i and div_busy_o
//         is 0, so firmware that writes DIVSEL sees it "take" immediately
//         but the frequency does not change. No chip test depends on this.
// =============================================================================
module clk_div (
    input  wire       refclk_i,
    input  wire       raw_rst_n_i,
    input  wire [1:0] div_sel_i,
    output wire       aon_clk_o,
    output wire       hclk_o,
    output wire       pclk_o,
    output wire       pclk_phase_o,
    output wire [1:0] div_act_o,
    output wire       div_busy_o
);
    wire hclk_b, pclk_b;

    BUFGCE_DIV #(.BUFGCE_DIVIDE(1)) u_bufg_h (
        .I(refclk_i), .CE(1'b1), .CLR(1'b0), .O(hclk_b));
    BUFGCE_DIV #(.BUFGCE_DIVIDE(2)) u_bufg_p (
        .I(refclk_i), .CE(1'b1), .CLR(1'b0), .O(pclk_b));

    // ---- reset for the phase flops: raw reset, synchronised to hclk ---------
    reg [1:0] rs_q;
    always @(posedge hclk_b or negedge raw_rst_n_i)
        if (!raw_rst_n_i) rs_q <= 2'b00;
        else              rs_q <= {rs_q[0], 1'b1};
    wire ph_rst_n = rs_q[1];

    // ---- pclk_phase: 1 on the hclk cycle whose closing edge raises pclk -----
    // tp toggles on every pclk rising edge. th follows tp one hclk later. In
    // the hclk cycle right after a pclk edge they differ. In the next cycle,
    // which is the one that ends in a pclk rise, they are equal.
    //   ASIC equivalent: pclk_phase_o = ~pclk_q.
    // tp -> th is a pclk->hclk path on edge-aligned clocks. Vivado times it
    // as synchronous.
    reg tp, th;
    always @(posedge pclk_b or negedge ph_rst_n)
        if (!ph_rst_n) tp <= 1'b0;
        else           tp <= ~tp;
    always @(posedge hclk_b or negedge ph_rst_n)
        if (!ph_rst_n) th <= 1'b0;
        else           th <= tp;

    assign aon_clk_o    = hclk_b;
    assign hclk_o       = hclk_b;
    assign pclk_o       = pclk_b;
    assign pclk_phase_o = (tp == th);
    assign div_act_o    = div_sel_i;
    assign div_busy_o   = 1'b0;
endmodule

`default_nettype wire
