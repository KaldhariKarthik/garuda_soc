`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 9: DMA Controller
// dma_apb_slave.v - APB3 slave front end: address decode + access qualification
//
// Spec reference: GARUDA-DMA-SPEC-001 Rev 2.0, Sec. 3.1 (#1), Sec. 5.2, Sec. 6.2
// Protocol:       ARM AMBA 3 APB, IHI 0024B
//
// PURELY COMBINATIONAL - and why that is the whole story.
// Sec. 5.2 ties PREADY to 1 and PSLVERR to 0: zero wait states, no error
// response. With PREADY constant there is no wait state to count and no
// handshake to track, so the "simple FSM" of the Sec. 3.1 sub-block table has
// nothing to sequence. The two-phase APB timing is supplied by the master's
// PSEL/PENABLE, and the register bank's flops provide all the storage. Adding
// a state register here would only add a cycle of latency to a config write
// that Sec. 11.1 already budgets at ~6 pclk. This module therefore has no
// clock port, deliberately.
//
// WRITE QUALIFICATION
//   wr_en_o = PSEL & PENABLE & PWRITE
// PENABLE is what restricts the strobe to the ACCESS phase, so it is exactly
// one pclk wide. That single-cycle guarantee is load-bearing downstream: the
// register bank toggles its CDC event flops (arm, W1C clears) on this strobe,
// and a strobe stretched over two cycles would invert each toggle twice and
// the event would vanish in the hclk domain - a channel that silently refuses
// to start, or an interrupt that never clears.
//
// DECODE (Sec. 6.2)
//   paddr[7:5] channel select, 0-5 valid, 6-7 reserved
//   paddr[4:2] register select, 0-4 valid (SAR/DAR/TCR/CR/SR), 5-7 reserved
//   paddr[1:0] byte offset, always 00 (all registers word-addressed)
// Reserved encodings are dropped rather than aliased: an access to a reserved
// channel or register produces no write strobe and reads back zero. Aliasing
// channel 6 onto channel 0 (what a bare paddr[7:5] mux without a range check
// would do) means a stray pointer silently reprogramming a live IMU channel.
//
// paddr[1:0] is intentionally NOT decoded. Sec. 5.2 defines the port as
// word-aligned; APB3 has no byte strobes, so a sub-word access cannot be
// honoured at this interface anyway and must be handled by the CPU/bridge.
// =============================================================================

`include "dma_defs.vh"

module dma_apb_slave (
    // ---- APB slave port (Sec. 5.2) -----------------------------------------
    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [7:0]  paddr_i,
    input  wire [31:0] pwdata_i,
    output wire [31:0] prdata_o,
    output wire        pready_o,
    output wire        pslverr_o,

    // ---- decoded interface to the register bank ----------------------------
    output wire [2:0]  ch_sel_o,     // paddr[7:5]
    output wire [2:0]  reg_sel_o,    // paddr[4:2]
    output wire        sel_valid_o,  // channel AND register both in range
    output wire        wr_en_o,      // qualified, ACCESS-phase-only write strobe
    output wire [31:0] wdata_o,
    input  wire [31:0] rdata_i       // register bank read mux output
);

    assign ch_sel_o  = paddr_i[7:5];
    assign reg_sel_o = paddr_i[4:2];

    // Channel 0-5 (Sec. 6.2: 110 and 111 unused/reserved).
    wire ch_valid  = (paddr_i[7:5] < `DMA_NCH);
    // Register 0-4 (Sec. 6.2: 101-111 reserved).
    wire reg_valid = (paddr_i[4:2] <= `DMA_REG_SR);

    assign sel_valid_o = ch_valid && reg_valid;

    assign wr_en_o = psel_i && penable_i && pwrite_i && sel_valid_o;
    assign wdata_o = pwdata_i;

    // Reads are combinational out of the register bank. Driving 0 whenever the
    // slave is not selected keeps PRDATA quiet on a shared read bus and makes
    // an accidental read of a reserved address return a defined 0 rather than
    // the last selected register's contents.
    assign prdata_o = (psel_i && !pwrite_i && sel_valid_o) ? rdata_i : 32'h0000_0000;

    // Sec. 5.2: zero wait states, never signals an error.
    assign pready_o  = 1'b1;
    assign pslverr_o = 1'b0;

endmodule

`default_nettype wire
