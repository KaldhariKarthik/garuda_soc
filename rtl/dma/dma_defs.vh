// =============================================================================
// GARUDA SoC - Block 9: DMA Controller
// dma_defs.vh - Shared DMA definitions (single source of truth)
//
// Document: GARUDA-DMA-SPEC-001 Rev 2.0
//
// Every encoding in this file is a PRODUCER/CONSUMER contract between the
// register bank (which stores the raw CR bits written by software) and the
// channel FSM / AHB master (which decode them). They must have exactly one
// definition - if a second copy appears anywhere, the two drift silently and
// the failure mode is a transfer that uses the wrong size or direction with
// no elaboration error to warn you.
//
// Naming follows rtl/common/garuda_defs.vh: `define macros, not localparams,
// because these cross module boundaries.
// =============================================================================
`ifndef GARUDA_DMA_DEFS_VH
`define GARUDA_DMA_DEFS_VH

// -----------------------------------------------------------------------------
// Geometry (Sec. 2)
// -----------------------------------------------------------------------------
`define DMA_NCH        6     // channels
`define DMA_CR_W      13     // implemented CR bits, [12:0]
`define DMA_TCR_W     16     // TCR / xfer_cnt width (max 65535 beats, Sec. 6.5)

// -----------------------------------------------------------------------------
// APB register select, paddr[4:2] (Sec. 6.2)
// paddr[7:5] = channel, paddr[4:2] = register, paddr[1:0] = 00
// -----------------------------------------------------------------------------
`define DMA_REG_SAR   3'b000
`define DMA_REG_DAR   3'b001
`define DMA_REG_TCR   3'b010
`define DMA_REG_CR    3'b011
`define DMA_REG_SR    3'b100
// 3'b101..3'b111 reserved: writes ignored, reads return 0

// -----------------------------------------------------------------------------
// CR bit positions (Sec. 6.6). These MUST match sw's CR_* macros in Sec. 13.1.
// -----------------------------------------------------------------------------
`define DMA_CR_EN      0        // [0]     channel enable
`define DMA_CR_DIR_HI  2        // [2:1]   direction
`define DMA_CR_DIR_LO  1
`define DMA_CR_SZ_HI   4        // [4:3]   beat size
`define DMA_CR_SZ_LO   3
`define DMA_CR_SINC    5        // [5]     source auto-increment
`define DMA_CR_DINC    6        // [6]     destination auto-increment
`define DMA_CR_CIRC    7        // [7]     circular mode
`define DMA_CR_IE      8        // [8]     complete-interrupt enable
`define DMA_CR_EIE     9        // [9]     error-interrupt enable
`define DMA_CR_PRI_HI 12        // [12:10] priority, 7 = highest
`define DMA_CR_PRI_LO 10

// -----------------------------------------------------------------------------
// SR bit positions (Sec. 6.7)
// -----------------------------------------------------------------------------
`define DMA_SR_COMPLETE 0       // [0]     W1C
`define DMA_SR_ERROR    1       // [1]     W1C
// [15:2]  reserved, read 0
// [31:16] REMAINING, read-only live xfer_cnt

// -----------------------------------------------------------------------------
// CR.DIR encoding (Sec. 6.6 / Sec. 9)
// -----------------------------------------------------------------------------
`define DMA_DIR_P2M   2'b00     // peripheral -> memory
`define DMA_DIR_M2P   2'b01     // memory -> peripheral
`define DMA_DIR_M2M   2'b10     // memory -> memory (no dma_req handshake)
`define DMA_DIR_RSVD  2'b11

// -----------------------------------------------------------------------------
// CR.SIZE encoding (Sec. 6.6). 2'b11 is reserved; the RTL treats it as WORD -
// see dma_ahb_master.v, "reserved SIZE" note.
// -----------------------------------------------------------------------------
`define DMA_SZ_BYTE   2'b00
`define DMA_SZ_HALF   2'b01
`define DMA_SZ_WORD   2'b10

// -----------------------------------------------------------------------------
// Channel FSM state encoding (Sec. 7.1). Encoding is fixed by the spec table -
// do not renumber, the verification plan covers states by value.
// -----------------------------------------------------------------------------
`define DMA_ST_IDLE        3'b000
`define DMA_ST_CONFIGURED  3'b001
`define DMA_ST_WAITING     3'b010
`define DMA_ST_TRANSFER    3'b011
`define DMA_ST_COMPLETE    3'b100

// -----------------------------------------------------------------------------
// AHB-Lite constants (ARM IHI 0033A), Sec. 5.3
// -----------------------------------------------------------------------------
`define AHB_TRANS_IDLE    2'b00
`define AHB_TRANS_NONSEQ  2'b10
`define AHB_BURST_SINGLE  3'b000
`define AHB_SIZE_BYTE     3'b000
`define AHB_SIZE_HALF     3'b001
`define AHB_SIZE_WORD     3'b010
`define AHB_RESP_OKAY     1'b0
`define AHB_RESP_ERROR    1'b1

`endif // GARUDA_DMA_DEFS_VH
