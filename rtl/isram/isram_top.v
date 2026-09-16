`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 3: Instruction SRAM (64 KB, AHB-Lite slave S0)
// isram_top.v - block boundary
//
// Spec reference: GARUDA-MEM-SPEC-001 Rev 2.0, Sec. 2, Sec. 3.3, Sec. 6.3,
//                 Sec. 10.3
//
// 64 KB at 0x0000_0000, 16,384 x 32, single-port 6T, unbanked. Firmware is
// linked to run from 0x0000_0000 and this is where the bootloader copies it.
//
// -----------------------------------------------------------------------------
// WHY AN INSTRUCTION MEMORY IS WRITABLE
// -----------------------------------------------------------------------------
// Worth stating plainly because it looks wrong at first glance. The ISRAM is an
// ordinary read/write SRAM. It has no special programming mode and no back-door
// load port. The bootloader, executing from the Boot ROM, reads the firmware
// image from external flash over SPI and writes it here over the ordinary AHB
// write path, then jumps to 0x0000_0000 (Sec. 10.3).
//
// So the write traffic is confined to the boot window by SOFTWARE CONVENTION,
// not by hardware. Nothing in the flight firmware writes here afterwards, and
// nothing prevents it from doing so. A future revision that wants write
// protection has to add it deliberately; it is not present today and must not
// be assumed.
//
// -----------------------------------------------------------------------------
// WHAT IS NOT HERE
// -----------------------------------------------------------------------------
// No prefetch, no burst counter, no cache. The core already has a prefetch
// buffer (Core Sec. 6.3) and duplicating fetch-ahead here would be wasted area
// serving the same purpose twice. A burst is simply a run of consecutive
// single-cycle accesses, each carrying its own address (Sec. 8.5).
// =============================================================================

`include "mem_defs.vh"

module isram_top (
    input  wire        hclk_i,
    input  wire        hreset_n_i,

    // AHB-Lite slave port S0 (frozen bundle, AHB Sec. 5.3)
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

    localparam integer AW = 14;      // 16,384 words

    wire [AW-1:0] arr_addr;
    wire [3:0]    arr_we;
    wire [31:0]   arr_wdata;
    wire [31:0]   arr_rdata;
    wire [1:0]    arr_bank_unused;
    wire          dp_oor_unused;

    ahb_mem_slave_if #(
        .ABITS    (`MEM_ISRAM_ABITS),
        .AW       (AW),
        .WRITABLE (1)
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
        .WORDS     (`MEM_ISRAM_WORDS),
        .AW        (AW),
        .INIT_FILE ("")           // SRAM: undefined at power-up (Sec. 10.1)
    ) u_array (
        .clk_i   (hclk_i),
        .addr_i  (arr_addr),
        .we_i    (arr_we),
        .wdata_i (arr_wdata),
        .rdata_o (arr_rdata)
    );

    // -----------------------------------------------------------------------
    // Backdoor access for testbenches (byte-addressed). Simulation only.
    // This is how the boot-copy test preloads an image without running the
    // bootloader, and how a test confirms what the bootloader actually wrote.
    // -----------------------------------------------------------------------
`ifndef SYNTHESIS
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

    task bd_load_hex;
        input [1023:0] path;
        begin
            u_array.bd_load_hex(path);
        end
    endtask
`endif

    // HBURST and HPROT are accepted at the boundary because the frozen slave
    // bundle carries them, and deliberately not consumed: bursts need no
    // special handling (Sec. 8.5) and GARUDA is M-mode with no MPU, so the
    // protection hint has no meaning here. Referenced so lint sees them used.
    wire _unused = |{hburst_i, hprot_i, arr_bank_unused, dp_oor_unused};

endmodule

`default_nettype wire
