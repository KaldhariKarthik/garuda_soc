`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 4: Data SRAM (64 KB as 4 x 16 KB banks, AHB-Lite slave S2)
// dsram_top.v - block boundary, bank decode and read mux
//
// Spec reference: GARUDA-MEM-SPEC-001 Rev 2.0, Sec. 6.2, Sec. 7, Sec. 13.3
//
// =============================================================================
// THERE IS NO BANK ARBITER HERE, AND THERE MUST NOT BE ONE
// =============================================================================
// This is the single most important thing about this file, it contradicts the
// TRM as originally written, and it is a ruling on the record - see
// docs/DECISIONS.md D-1.
//
// An earlier draft of the memory specification placed a bank arbiter inside
// this block that granted the DMA priority over the CPU on a same-bank
// conflict. It was removed, because it is not merely redundant - it is
// UNIMPLEMENTABLE. The AHB-Lite interconnect un-gates exactly one master at a
// time (AHB Sec. 7.3) and presents a single transaction to slave S2 through one
// shared address/control bundle. This block therefore sees at most one
// transaction per cycle, and its interface carries no signal identifying which
// master issued it. There is nothing to arbitrate and no way to tell the
// contenders apart.
//
// The behaviour the TRM was describing is real - the DMA does take priority and
// the CPU does wait a beat - but it lives in the Block 6 arbiter, where the DMA
// already holds highest priority because a stalled DMA can overflow a
// peripheral FIFO and lose sensor data irrecoverably, while a stalled CPU loses
// a cycle of compute. Duplicating that policy into a block that cannot enforce
// it is how two specifications come to disagree in silicon.
//
// Consequently: accesses to DIFFERENT banks are serialised exactly as accesses
// to the same bank are. Banking buys access energy and array delay (Sec. 7.1),
// not concurrency. The functional bank map below is a locality and ownership
// convention enforced by the linker script, not a contention-avoidance
// mechanism, and the bank index has no effect on timing whatsoever.
//
//   Bank 0  0x2000_0000-3FFF  sensor DMA landing buffers      (DMA)
//   Bank 1  0x2000_4000-7FFF  EKF state and matrices          (CPU)
//   Bank 2  0x2000_8000-BFFF  APF working set, comms buffers  (CPU/DMA)
//   Bank 3  0x2000_C000-FFFF  FreeRTOS stacks and heap        (CPU)
//
// =============================================================================
// THE READ MUX SELECTS ON THE REGISTERED BANK INDEX (Sec. 7.4)
// =============================================================================
// The bank index comes out of the same register as the word address, so the
// mux selection is stable for the whole data phase and hrdata is glitch-free.
// Selecting on the ADDRESS-phase bank index would return the wrong bank's word
// whenever two consecutive accesses hit different banks - which, given the bank
// map above, is the normal case the moment the CPU and the DMA are both busy.
// =============================================================================

`include "mem_defs.vh"

module dsram_top (
    input  wire        hclk_i,
    input  wire        hreset_n_i,

    // AHB-Lite slave port S2 (frozen bundle, AHB Sec. 5.3)
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

    localparam integer AW = 14;      // 16,384 words across the four banks

    wire [AW-1:0] arr_addr;          // [13:12] = bank, [11:0] = word in bank
    wire [3:0]    arr_we;
    wire [31:0]   arr_wdata;
    wire [1:0]    arr_bank;
    wire          dp_oor;
    wire [31:0]   arr_rdata;

    ahb_mem_slave_if #(
        .ABITS    (`MEM_DSRAM_ABITS),
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
        .arr_bank_o  (arr_bank),
        .dp_oor_o    (dp_oor)
    );

    // -----------------------------------------------------------------------
    // Bank decode. One-of-four, and an out-of-depth access selects NO bank at
    // all (Sec. 6.4) - the read mux then returns zero rather than an aliased
    // word from bank 0.
    // -----------------------------------------------------------------------
    wire [`MEM_DSRAM_NBANKS-1:0] bank_ce;
    assign bank_ce[0] = !dp_oor && (arr_bank == 2'd0);
    assign bank_ce[1] = !dp_oor && (arr_bank == 2'd1);
    assign bank_ce[2] = !dp_oor && (arr_bank == 2'd2);
    assign bank_ce[3] = !dp_oor && (arr_bank == 2'd3);

    wire [31:0] bank_rdata [0:`MEM_DSRAM_NBANKS-1];

    genvar b;
    generate
        for (b = 0; b < `MEM_DSRAM_NBANKS; b = b + 1) begin : g_bank
            dsram_bank u_bank (
                .clk_i   (hclk_i),
                .ce_i    (bank_ce[b]),
                .addr_i  (arr_addr[11:0]),
                .we_i    (arr_we),
                .wdata_i (arr_wdata),
                .rdata_o (bank_rdata[b])
            );
        end
    endgenerate

    // -----------------------------------------------------------------------
    // Read mux on the registered bank index (Sec. 7.4). ~0.2 ns after the
    // array, inside the cycle budget of Sec. 9.1.
    // -----------------------------------------------------------------------
    reg [31:0] rmux;
    always @(*) begin
        case (arr_bank)
            2'd0:    rmux = bank_rdata[0];
            2'd1:    rmux = bank_rdata[1];
            2'd2:    rmux = bank_rdata[2];
            default: rmux = bank_rdata[3];
        endcase
    end

    assign arr_rdata = dp_oor ? 32'h0000_0000 : rmux;

    // -----------------------------------------------------------------------
    // Backdoor access for testbenches. Simulation only.
    //
    // Presented at the BLOCK boundary, taking a byte address, so a testbench
    // never has to know about banking. That matters more than convenience: a
    // testbench that did its own bank arithmetic would be encoding this block's
    // internal geometry, and would silently check the wrong location the day
    // the bank count changes with the PDK (Sec. 13.6).
    // -----------------------------------------------------------------------
`ifndef SYNTHESIS
    task bd_write;
        input [31:0] byte_addr;
        input [31:0] data;
        begin
            case (byte_addr[`MEM_DSRAM_BANK_SEL_HI:`MEM_DSRAM_BANK_SEL_LO])
                2'd0: g_bank[0].u_bank.u_array.bd_write(byte_addr[13:2], data);
                2'd1: g_bank[1].u_bank.u_array.bd_write(byte_addr[13:2], data);
                2'd2: g_bank[2].u_bank.u_array.bd_write(byte_addr[13:2], data);
                2'd3: g_bank[3].u_bank.u_array.bd_write(byte_addr[13:2], data);
            endcase
        end
    endtask

    function [31:0] bd_read;
        input [31:0] byte_addr;
        begin
            case (byte_addr[`MEM_DSRAM_BANK_SEL_HI:`MEM_DSRAM_BANK_SEL_LO])
                2'd0: bd_read = g_bank[0].u_bank.u_array.bd_read(byte_addr[13:2]);
                2'd1: bd_read = g_bank[1].u_bank.u_array.bd_read(byte_addr[13:2]);
                2'd2: bd_read = g_bank[2].u_bank.u_array.bd_read(byte_addr[13:2]);
                2'd3: bd_read = g_bank[3].u_bank.u_array.bd_read(byte_addr[13:2]);
            endcase
        end
    endfunction
`endif

    wire _unused = |{hburst_i, hprot_i};

endmodule

`default_nettype wire
