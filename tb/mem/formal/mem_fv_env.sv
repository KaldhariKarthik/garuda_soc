// =============================================================================
// mem_fv_env.sv -- formal environment of the three memory slaves (Track A plan
// 6A.6, step M1). Bound into isram_top, dsram_top and bootrom_top, each proved
// at its real size; the properties are rtl/mem/mem_sva.sv (bound to the shared
// front end ahb_mem_slave_if, and dsram_sva bound to dsram_top). Every bus input
// is a free input of the proof, constrained only by the rules below. ILOCK and
// hmaster_is_sba (isram_top) are left completely free: they may change in any
// cycle, also with a transfer in flight (vPlan F13).
//
//   FM-1 reset: hreset_n low for the first RST_CYCLES cycles, then high.
//   FM-2 AHB-Lite master: HTRANS is IDLE, NONSEQ or SEQ (no GARUDA master emits
//        BUSY) and IDLE in reset; an address phase presented while HREADY is low
//        is held unchanged (HSEL, HADDR, HTRANS, HWRITE, HSIZE) until HREADY is
//        high. Misaligned and over-wide sizes are NOT excluded: the slave must
//        refuse them, so they stay in the input space.
//   FM-3 global HREADY: while this slave owns the data phase, HREADY is its own
//        HREADYOUT (no other slave can be in a data phase then); otherwise HREADY
//        is free (another slave's wait states). "Owns the data phase" is derived
//        here from the bus, not read from the RTL.
// =============================================================================
`timescale 1ns/1ps
module mem_fv_env #(
    parameter integer RST_CYCLES = 2
)(
    input wire        clk,
    input wire        hreset_n_i,
    input wire        hsel_i,
    input wire [31:0] haddr_i,
    input wire [1:0]  htrans_i,
    input wire        hwrite_i,
    input wire [2:0]  hsize_i,
    input wire        hready_i,
    input wire        hreadyout_o
);
    localparam [1:0] T_IDLE = 2'b00, T_BUSY = 2'b01;

    reg [2:0]  cyc = 3'd0;
    reg        own_dp = 1'b0;        // this slave has a data phase now
    reg        held = 1'b0;          // an address phase was presented with HREADY low
    reg        sel_q, wr_q;
    reg [31:0] addr_q;
    reg [1:0]  trans_q;
    reg [2:0]  size_q;

    always @(posedge clk) begin
        if (cyc != 3'd7) cyc <= cyc + 3'd1;
        sel_q <= hsel_i; addr_q <= haddr_i; trans_q <= htrans_i; wr_q <= hwrite_i; size_q <= hsize_i;
        held  <= hreset_n_i && htrans_i[1] && !hready_i;
        if (!hreset_n_i)   own_dp <= 1'b0;
        else if (hready_i) own_dp <= hsel_i && htrans_i[1];
    end

    always @(*) begin
        // ---- FM-1
        if (cyc < RST_CYCLES) assume (!hreset_n_i);
        else                  assume (hreset_n_i);
        // ---- FM-2
        assume (htrans_i != T_BUSY);
        if (!hreset_n_i) assume (htrans_i == T_IDLE);
        if (held) assume (hsel_i == sel_q && haddr_i == addr_q && htrans_i == trans_q &&
                          hwrite_i == wr_q && hsize_i == size_q);
        // ---- FM-3
        if (own_dp) assume (hready_i == hreadyout_o);
    end
endmodule

bind isram_top mem_fv_env u_fv_env (
    .clk(hclk_i), .hreset_n_i(hreset_n_i), .hsel_i(hsel_i), .haddr_i(haddr_i),
    .htrans_i(htrans_i), .hwrite_i(hwrite_i), .hsize_i(hsize_i),
    .hready_i(hready_i), .hreadyout_o(hreadyout_o));
bind dsram_top mem_fv_env u_fv_env (
    .clk(hclk_i), .hreset_n_i(hreset_n_i), .hsel_i(hsel_i), .haddr_i(haddr_i),
    .htrans_i(htrans_i), .hwrite_i(hwrite_i), .hsize_i(hsize_i),
    .hready_i(hready_i), .hreadyout_o(hreadyout_o));
bind bootrom_top mem_fv_env u_fv_env (
    .clk(hclk_i), .hreset_n_i(hreset_n_i), .hsel_i(hsel_i), .haddr_i(haddr_i),
    .htrans_i(htrans_i), .hwrite_i(hwrite_i), .hsize_i(hsize_i),
    .hready_i(hready_i), .hreadyout_o(hreadyout_o));
