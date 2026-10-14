// =============================================================================
// apb_fv_env.sv -- formal environment of ahb2apb_bridge (Track A bus plan B2).
// Bound into ahb2apb_bridge; the properties are rtl/ahb2apb/ahb2apb_sva.sv.
// SINGLE CLOCK: without `multiclock on` SBY clocks every flop once per step, so
// pclk = hclk here. The bridge's request / acknowledge toggles make "one request,
// one response" independent of the hclk:pclk ratio (bridge header, BRG-1), so a
// property PROVEN here holds for the real pclk = hclk/2; the ratio itself and the
// shared-edge rule are checked by clk_div_sva in every simulation (D-5).
//   FB-1 reset: hreset_n and preset_n low for the first RST_CYCLES cycles, then high
//        (the split-reset gap of [N-9.2] is a simulation item, t_apb_reset_skew).
//   FB-2 AHB-Lite master: HTRANS IDLE or NONSEQ (SINGLE word/half/byte; the
//        GARUDA masters never send BUSY or a SEQ into the bridge region); IDLE in
//        reset; a presented address phase is held while HREADY is low; HWDATA is
//        held through the bridge's data phase.
//   FB-3 global HREADY: during the bridge's own data phase it is the bridge's
//        HREADYOUT (the bridge is the data-phase slave); otherwise free (another
//        slave's data phase, or an idle bus).
//   FB-4 (prove task only): x bits after techmap become free values (setundef -anyseq),
//        an over-approximation; see apb.toml.
//   APB targets: PREADY, PSLVERR and PRDATA are completely free on every window, in
//        every cycle (never-ready included): the bridge must work for any target.
// =============================================================================
`timescale 1ns/1ps
module apb_fv_env #(parameter integer RST_CYCLES = 2) (
    input wire        clk,
    input wire        hreset_n_i,
    input wire        preset_n_i,
    input wire        hsel_i,
    input wire [31:0] haddr_i,
    input wire [1:0]  htrans_i,
    input wire        hwrite_i,
    input wire [2:0]  hsize_i,
    input wire [31:0] hwdata_i,
    input wire        hready_i,
    input wire        hreadyout_o
);
    reg [2:0]  cyc = 3'd0;
    reg        dp = 1'b0;                 // the bridge has a data phase
    reg        pres_q = 1'b0, rdy_q = 1'b1, sel_q = 1'b0, wr_q = 1'b0;
    reg [31:0] addr_q = 32'd0, wdata_q = 32'd0;
    reg [2:0]  size_q = 3'd0;
    reg [1:0]  trans_q = 2'd0;
    always @(posedge clk) begin
        if (cyc != 3'd7) cyc <= cyc + 3'd1;
        if (!hreset_n_i) dp <= 1'b0;
        else if (hready_i) dp <= hsel_i && htrans_i[1];
        pres_q <= htrans_i[1]; rdy_q <= hready_i; sel_q <= hsel_i; wr_q <= hwrite_i;
        addr_q <= haddr_i; size_q <= hsize_i; trans_q <= htrans_i; wdata_q <= hwdata_i;
    end
    always @(*) begin
        if (cyc < RST_CYCLES) begin assume (!hreset_n_i); assume (!preset_n_i); end
        else                  begin assume (hreset_n_i);  assume (preset_n_i);  end
        assume (htrans_i == 2'b00 || htrans_i == 2'b10);
        if (!hreset_n_i) assume (htrans_i == 2'b00);
        if (cyc >= RST_CYCLES && pres_q && !rdy_q)
            assume (htrans_i == trans_q && haddr_i == addr_q && hsize_i == size_q && hwrite_i == wr_q && hsel_i == sel_q);
        assume (hsize_i <= 3'd2);
        if (dp) assume (hready_i == hreadyout_o);
        if (cyc >= RST_CYCLES && dp && !rdy_q) assume (hwdata_i == wdata_q);
    end
endmodule

bind ahb2apb_bridge apb_fv_env u_fv_env (.clk(hclk_i), .hreset_n_i(hreset_n_i), .preset_n_i(preset_n_i),
    .hsel_i(hsel_i), .haddr_i(haddr_i), .htrans_i(htrans_i), .hwrite_i(hwrite_i), .hsize_i(hsize_i),
    .hwdata_i(hwdata_i), .hready_i(hready_i), .hreadyout_o(hreadyout_o));
