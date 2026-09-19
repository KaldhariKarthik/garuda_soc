`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 5 : Data SRAM, 64 KiB at 0x2000_0000, 4 x 16 KiB macros
// dsram_top.v
//
// Spec: GARUDA-MEM-SPEC-001 Rev 2.0 (Rev 4.0 set) §5.2, §7.5; ADR-0007
//
// One AHB slave port, four macros selected by haddr[15:14] ([N-7.11]). All
// four see the same address and write data; only the selected bank gets CE
// ([N-7.13]), so the unselected macros see no access at all (the per-macro
// clock-enable of [N-9.4]). The bank of a read is registered with the access
// so the returning data is taken from the macro that was actually read.
// No bank-level concurrency exists or is needed ([N-7.12], D-1).
// =============================================================================
`include "mem_defs.vh"

module dsram_top (
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
    output wire        hresp_o
);

    localparam integer AW  = 14;            // 16,384 words total
    localparam integer BAW = 12;            // 4,096 words per bank

    wire          ce, we;
    wire [AW-1:0] addr;
    wire [3:0]    be;
    wire [31:0]   wdata;
    wire [31:0]   rdata [0:3];
    reg  [1:0]    rd_bank_q;

    ahb_mem_slave_if #(.AW(AW), .WRITABLE(1)) u_if (
        .hclk_i(hclk_i), .hreset_n_i(hreset_n_i),
        .hsel_i(hsel_i), .haddr_i(haddr_i), .htrans_i(htrans_i),
        .hwrite_i(hwrite_i), .hsize_i(hsize_i), .hwdata_i(hwdata_i),
        .hready_i(hready_i), .hrdata_o(hrdata_o), .hreadyout_o(hreadyout_o),
        .hresp_o(hresp_o),
        .wr_lock_i(1'b0), .lock_bypass_i(1'b0),
        .arr_ce_o(ce), .arr_addr_o(addr), .arr_we_o(we), .arr_be_o(be),
        .arr_wdata_o(wdata), .arr_rdata_i(rdata[rd_bank_q]));

    wire [1:0] bank = addr[AW-1:BAW];

    // bank of the most recent read; its data is what arrives next cycle
    always @(posedge hclk_i or negedge hreset_n_i)
        if (!hreset_n_i)     rd_bank_q <= 2'd0;
        else if (ce && !we)  rd_bank_q <= bank;

    genvar b;
    generate for (b = 0; b < 4; b = b + 1) begin : g_bank
        sram_wrapper #(.WORDS(`MEM_DSRAM_BANK_WORDS), .AW(BAW)) u_array (
            .clk(hclk_i), .ce(ce && bank == b), .addr(addr[BAW-1:0]),
            .wdata(wdata), .rdata(rdata[b]), .we(we), .be(be));
    end endgenerate

`ifndef SYNTHESIS
    // Byte-addressed backdoor; the testbench never sees the banking.
    task bd_write; input [31:0] byte_addr; input [31:0] data;
        case (byte_addr[15:14])
            2'd0: g_bank[0].u_array.bd_write(byte_addr[13:2], data);
            2'd1: g_bank[1].u_array.bd_write(byte_addr[13:2], data);
            2'd2: g_bank[2].u_array.bd_write(byte_addr[13:2], data);
            default: g_bank[3].u_array.bd_write(byte_addr[13:2], data);
        endcase
    endtask
    function [31:0] bd_read; input [31:0] byte_addr;
        case (byte_addr[15:14])
            2'd0: bd_read = g_bank[0].u_array.bd_read(byte_addr[13:2]);
            2'd1: bd_read = g_bank[1].u_array.bd_read(byte_addr[13:2]);
            2'd2: bd_read = g_bank[2].u_array.bd_read(byte_addr[13:2]);
            default: bd_read = g_bank[3].u_array.bd_read(byte_addr[13:2]);
        endcase
    endfunction
`endif

    wire _unused = |{hburst_i, hprot_i};

endmodule

`default_nettype wire
