`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 3 : Instruction SRAM, 64 KiB at 0x0000_0000
// isram_top.v
//
// Spec: GARUDA-MEM-SPEC-001 Rev 2.0 (Rev 4.0 set) §5.1, §7.4
//
// Zero-wait AHB slave on one 16K x 32 macro. Writes are refused (two-cycle
// ERROR, no array effect) while MEMCTL.ILOCK is set, unless the granted master
// is the Debug SBA (hmaster_is_sba_i) - [N-7.8], [N-7.9]. ILOCK lives in the
// reset_ctrl APB block (window 9, offset 0x20); it is a pclk flop read here in
// hclk, a synchronous path.
// =============================================================================
`include "mem_defs.vh"

module isram_top (
    input  wire        hclk_i,
    input  wire        hreset_n_i,

    input  wire        hsel_i,
    input  wire [31:0] haddr_i,
    input  wire [1:0]  htrans_i,
    input  wire        hwrite_i,
    input  wire [2:0]  hsize_i,
    input  wire [2:0]  hburst_i,
    input  wire [3:0]  hprot_i,
    input  wire [31:0] hwdata_i,
    input  wire        hready_i,
    output wire [31:0] hrdata_o,
    output wire        hreadyout_o,
    output wire        hresp_o,

    input  wire        ilock_i,            // MEMCTL.ILOCK
    input  wire        hmaster_is_sba_i    // from ahb_interconnect
);

    localparam integer AW = 14;             // 16,384 words

    wire          ce, we;
    wire [AW-1:0] addr;
    wire [3:0]    be;
    wire [31:0]   wdata, rdata;

    ahb_mem_slave_if #(.AW(AW), .WRITABLE(1)) u_if (
        .hclk_i(hclk_i), .hreset_n_i(hreset_n_i),
        .hsel_i(hsel_i), .haddr_i(haddr_i), .htrans_i(htrans_i),
        .hwrite_i(hwrite_i), .hsize_i(hsize_i), .hwdata_i(hwdata_i),
        .hready_i(hready_i), .hrdata_o(hrdata_o), .hreadyout_o(hreadyout_o),
        .hresp_o(hresp_o),
        .wr_lock_i(ilock_i), .lock_bypass_i(hmaster_is_sba_i),
        .arr_ce_o(ce), .arr_addr_o(addr), .arr_we_o(we), .arr_be_o(be),
        .arr_wdata_o(wdata), .arr_rdata_i(rdata));

    sram_wrapper #(.WORDS(`MEM_ISRAM_WORDS), .AW(AW)) u_array (
        .clk(hclk_i), .ce(ce), .addr(addr), .wdata(wdata), .rdata(rdata),
        .we(we), .be(be));

`ifndef SYNTHESIS
    task bd_write;     input [31:0] byte_addr; input [31:0] data;
        u_array.bd_write(byte_addr[AW+1:2], data);
    endtask
    function [31:0] bd_read; input [31:0] byte_addr;
        bd_read = u_array.bd_read(byte_addr[AW+1:2]);
    endfunction
    task bd_load_hex;  input [1023:0] path;
        u_array.bd_load_hex(path);
    endtask
`endif

    wire _unused = |{hburst_i, hprot_i};

endmodule

`default_nettype wire
