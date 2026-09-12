// =============================================================================
// GARUDA SoC - Block 6: AHB-Lite Interconnect
// ahb_defs.vh - shared constants for the interconnect (single source of truth)
//
// Document: GARUDA-AHB-SPEC-001 Rev 2.0
//
// Same rule as rtl/dma/dma_defs.vh: every encoding that crosses a module
// boundary is defined exactly once. The master indices in particular are a
// contract between the arbiter (which produces a grant index), the master mux
// (which consumes it) and the interconnect top (which gates the per-master
// return path with it). Three copies of "DMA is 2" is three chances to drift.
//
// Naming follows rtl/common/garuda_defs.vh: `define, not localparam, because
// these are used in port widths and across files.
// =============================================================================
`ifndef GARUDA_AHB_DEFS_VH
`define GARUDA_AHB_DEFS_VH

// -----------------------------------------------------------------------------
// Geometry (Sec. 2)
// -----------------------------------------------------------------------------
`define AHB_NMASTERS   3
`define AHB_NSLAVES    4     // ISRAM, ROM, DSRAM, Bridge  (default slave is
                             // tracked separately - it is not a decoded region)

// -----------------------------------------------------------------------------
// Master indices (Sec. 4, Sec. 7.1). Order IS the priority order: a higher
// index wins. Do not renumber without changing ahb_arbiter's priority encoder,
// which relies on scanning from the top down.
// -----------------------------------------------------------------------------
`define AHB_M_IPORT    2'd0   // M0 - CPU I-Port   (lowest priority)
`define AHB_M_DPORT    2'd1   // M1 - CPU D-Port
`define AHB_M_DMA      2'd2   // M2 - DMA          (highest priority)

// -----------------------------------------------------------------------------
// Slave indices / one-hot select bit positions (Sec. 6).
// Bit 4 is the default slave: it is part of the same one-hot vector so that
// "exactly one bit set, always" is an invariant the RTL and the testbench can
// both assert, rather than "one bit set, unless nothing matched".
// -----------------------------------------------------------------------------
`define AHB_S_ISRAM    0      // 0x0000_0000, 64 KB
`define AHB_S_ROM      1      // 0x1000_0000,  4 KB  (reset vector)
`define AHB_S_DSRAM    2      // 0x2000_0000, 64 KB
`define AHB_S_BRIDGE   3      // 0x4000_0000, APB peripherals
`define AHB_S_DEFAULT  4      // everything else
`define AHB_SEL_W      5      // width of the one-hot select vector

// -----------------------------------------------------------------------------
// Region decode on HADDR[31:28] (Sec. 6). Only [30:28] actually differ; the
// top nibble is decoded because it is simpler and leaves headroom.
// -----------------------------------------------------------------------------
`define AHB_RGN_ISRAM  4'h0
`define AHB_RGN_ROM    4'h1
`define AHB_RGN_DSRAM  4'h2
`define AHB_RGN_BRIDGE 4'h4

// -----------------------------------------------------------------------------
// AHB-Lite protocol constants (ARM IHI 0033A). Deliberately spelled the same
// way as rtl/dma/dma_defs.vh so a reader moving between the two blocks is not
// asked to learn a second vocabulary.
// -----------------------------------------------------------------------------
`define AHB_TRANS_IDLE    2'b00
`define AHB_TRANS_BUSY    2'b01
`define AHB_TRANS_NONSEQ  2'b10
`define AHB_TRANS_SEQ     2'b11

`define AHB_BURST_SINGLE  3'b000
`define AHB_BURST_INCR    3'b001

`define AHB_SIZE_BYTE     3'b000
`define AHB_SIZE_HALF     3'b001
`define AHB_SIZE_WORD     3'b010

`define AHB_RESP_OKAY     1'b0
`define AHB_RESP_ERROR    1'b1

// -----------------------------------------------------------------------------
// HPROT substituted for the DMA (Sec. 7.6). The DMA boundary has no HPROT
// port, so the interconnect drives the AMBA default for a privileged,
// non-cacheable, non-bufferable DATA access.
//   bit0 = 1 data (not opcode), bit1 = 1 privileged, bit2 = 0 non-bufferable,
//   bit3 = 0 non-cacheable
// -----------------------------------------------------------------------------
`define AHB_HPROT_DMA     4'b0011

`endif // GARUDA_AHB_DEFS_VH
