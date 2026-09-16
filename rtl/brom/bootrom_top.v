`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 5: Boot ROM (4 KB, AHB-Lite slave S1)
// bootrom_top.v - block boundary
//
// Spec reference: GARUDA-MEM-SPEC-001 Rev 2.0, Sec. 6.3, Sec. 8.6, Sec. 10.2,
//                 Sec. 10.3
//
// 4 KB at 0x1000_0000, 1024 x 32, mask/metal-programmed, read-only in silicon.
//
// -----------------------------------------------------------------------------
// THIS BLOCK HOLDS THE RESET VECTOR, AND THAT IS WHY IT IS A ROM
// -----------------------------------------------------------------------------
// Out of reset the core's PC loads 0x1000_0000 (Core Sec. 3), so the first live
// bus transaction in the SoC's life is an instruction fetch from this block.
// Every other memory in the chip has undefined contents at that instant: SRAM
// is not initialised by reset and firmware must not read a location before
// writing it (Sec. 10.1). The ROM's contents are fixed in metal at tapeout and
// are valid immediately, which is the entire reason the reset vector points
// here and not at 0x0000_0000.
//
// The bootloader that lives here initialises the stack pointer, configures the
// clock divider, brings up SPI, reads the firmware image from external flash,
// writes it into the Instruction SRAM, verifies a checksum and jumps to
// 0x0000_0000 (Sec. 10.3).
//
// -----------------------------------------------------------------------------
// A WRITE HERE IS ACCEPTED AND DISCARDED - NOT ERRORED (Sec. 8.6)
// -----------------------------------------------------------------------------
// WRITABLE=0 in the shared wrapper kills the write enable, so the transfer
// completes with HREADYOUT high and HRESP OKAY and no state changes. It
// deliberately does NOT return an error: that would mean building and verifying
// a two-cycle ERROR responder in a block that otherwise has no error path at
// all, to catch a condition correct firmware never produces. The wrapper's
// simulation assertion catches it instead, which is where a software bug of
// this kind should surface.
//
// -----------------------------------------------------------------------------
// INIT_FILE
// -----------------------------------------------------------------------------
// The mask-programmed contents. In silicon this is metal; here it is a hex
// image loaded at time zero, overridable per instantiation so a testbench can
// boot a different image without touching this file. Left empty by default so
// that an unconfigured build fails loudly (fetching X) rather than booting
// something plausible.
// =============================================================================

`include "mem_defs.vh"

module bootrom_top #(
    parameter INIT_FILE = ""
)(
    input  wire        hclk_i,
    input  wire        hreset_n_i,

    // AHB-Lite slave port S1 (frozen bundle, AHB Sec. 5.3)
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
    output wire        hresp_o
);

    localparam integer AW = 10;      // 1024 words

    wire [AW-1:0] arr_addr;
    wire [3:0]    arr_we;
    wire [31:0]   arr_wdata;
    wire [31:0]   arr_rdata;
    wire [1:0]    arr_bank_unused;
    wire          dp_oor_unused;

    ahb_mem_slave_if #(
        .ABITS    (`MEM_BROM_ABITS),
        .AW       (AW),
        .WRITABLE (0)                // read-only in silicon - see header
    ) u_if (
        .hclk_i      (hclk_i),
        .hreset_n_i  (hreset_n_i),
        .hsel_i      (hsel_i),
        .haddr_i     (haddr_i),
        .htrans_i    (htrans_i),
        .hwrite_i    (hwrite_i),
        .hsize_i     (hsize_i),
        .hwdata_i    (hwdata_i),
        .hready_i    (hready_i),
        .hrdata_o    (hrdata_o),
        .hreadyout_o (hreadyout_o),
        .hresp_o     (hresp_o),
        .arr_addr_o  (arr_addr),
        .arr_we_o    (arr_we),
        .arr_wdata_o (arr_wdata),
        .arr_rdata_i (arr_rdata),
        .arr_bank_o  (arr_bank_unused),
        .dp_oor_o    (dp_oor_unused)
    );

    mem_array_sp #(
        .WORDS     (`MEM_BROM_WORDS),
        .AW        (AW),
        .INIT_FILE (INIT_FILE)
    ) u_array (
        .clk_i   (hclk_i),
        .addr_i  (arr_addr),
        .we_i    (arr_we),           // held at 0 by WRITABLE=0
        .wdata_i (arr_wdata),
        .rdata_o (arr_rdata)
    );

    // -----------------------------------------------------------------------
    // Backdoor access for testbenches (byte-addressed). Simulation only.
    //
    // bd_load_hex is how every SoC test gets its boot image in: the ROM is
    // mask-programmed in silicon, so there is no run-time path to write it and
    // a testbench must load it out of band before releasing reset.
    // -----------------------------------------------------------------------
`ifndef SYNTHESIS
    task bd_load_hex;
        input [1023:0] path;
        begin
            u_array.bd_load_hex(path);
        end
    endtask

    task bd_write;
        input [31:0] byte_addr;
        input [31:0] data;
        begin
            u_array.bd_write(byte_addr[AW+1:2], data);
        end
    endtask

    function [31:0] bd_read;
        input [31:0] byte_addr;
        begin
            bd_read = u_array.bd_read(byte_addr[AW+1:2]);
        end
    endfunction
`endif

    wire _unused = |{hburst_i, hprot_i, arr_bank_unused, dp_oor_unused};

endmodule

`default_nettype wire
