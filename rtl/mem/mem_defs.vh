// =============================================================================
// GARUDA SoC - Blocks 3/4/5: Memory Subsystem
// mem_defs.vh - Shared memory-subsystem definitions (single source of truth)
//
// Document: GARUDA-MEM-SPEC-001 Rev 2.0
//
// Same rule as rtl/ahb/ahb_defs.vh and rtl/dma/dma_defs.vh: every constant that
// crosses a module boundary is defined exactly once. The geometry constants in
// particular are a contract between the block tops (which size their arrays)
// and the shared slave wrapper (which range-checks against that size). Two
// copies of "the ISRAM is 64 KB" is two chances to drift, and the drift is
// silent - a wrapper checking 64 KB in front of a 32 KB array aliases rather
// than erroring.
//
// These deliberately do NOT redefine the region bases. HADDR[31:28] decode is
// owned by rtl/ahb/ahb_defs.vh (AHB Sec. 6) and the memories never re-decode
// the region - they are handed an HSEL and check only depth (MEM Sec. 6.4).
// The bases appear here as commentary for the reader, not as macros to be
// consumed, precisely so there is no second definition to diverge.
//
//   S0  Instruction SRAM  0x0000_0000  64 KB   Block 3
//   S1  Boot ROM          0x1000_0000   4 KB   Block 5  (reset vector)
//   S2  Data SRAM         0x2000_0000  64 KB   Block 4  (4 x 16 KB banks)
// =============================================================================
`ifndef GARUDA_MEM_DEFS_VH
`define GARUDA_MEM_DEFS_VH

// -----------------------------------------------------------------------------
// Implemented depth, expressed as the number of BYTE-address bits each memory
// actually implements (Sec. 2, Sec. 6.4).
//
// This is the form the depth range check needs: a memory implements address
// bits [N-1:0] and every bit from [27:N] must be zero for the access to be in
// depth. Expressing the size as a bit count rather than a byte count keeps the
// check a constant mask instead of a comparator against a non-power-of-two.
// -----------------------------------------------------------------------------
`define MEM_ISRAM_ABITS   16     // 64 KB -> HADDR[15:0]
`define MEM_DSRAM_ABITS   16     // 64 KB -> HADDR[15:0]
`define MEM_BROM_ABITS    12     //  4 KB -> HADDR[11:0]

// -----------------------------------------------------------------------------
// Word depths (Sec. 2). Byte size / 4.
// -----------------------------------------------------------------------------
`define MEM_ISRAM_WORDS   16384  // 64 KB / 4
`define MEM_BROM_WORDS     1024  //  4 KB / 4
`define MEM_DSRAM_WORDS   16384  // 64 KB / 4, spread across 4 banks

// -----------------------------------------------------------------------------
// Data SRAM banking (Sec. 6.2, Sec. 7.2)
//
// HADDR[15:14] selects the bank; HADDR[13:2] indexes the word inside it.
//
// READ THIS BEFORE CHANGING THE BANK COUNT: banking here buys access ENERGY and
// array delay, not concurrency. The interconnect grants one master at a time
// (AHB Sec. 7.3), so the Data SRAM sees one transaction per cycle and cannot
// service two. There is no bank arbiter in this subsystem and there must not be
// one - see dsram_top.v's header and MEM Sec. 7.1/7.3/13.3.
// -----------------------------------------------------------------------------
`define MEM_DSRAM_NBANKS      4
`define MEM_DSRAM_BANK_WORDS  4096   // 16 KB per bank
`define MEM_DSRAM_BANK_SEL_HI 15
`define MEM_DSRAM_BANK_SEL_LO 14

// -----------------------------------------------------------------------------
// AHB transfer sizes consumed by the byte-lane logic (Sec. 8.3). Spelled the
// same way as rtl/ahb/ahb_defs.vh so a reader moving between the two blocks is
// not asked to learn a second vocabulary. Not `included from there because the
// memories must compile standalone in their own block-level testbench.
// -----------------------------------------------------------------------------
`define MEM_SIZE_BYTE     3'b000
`define MEM_SIZE_HALF     3'b001
`define MEM_SIZE_WORD     3'b010

`define MEM_TRANS_IDLE    2'b00
`define MEM_TRANS_BUSY    2'b01
`define MEM_TRANS_NONSEQ  2'b10
`define MEM_TRANS_SEQ     2'b11

`define MEM_RESP_OKAY     1'b0
`define MEM_RESP_ERROR    1'b1     // never driven by this subsystem (Sec. 8.6)

`endif // GARUDA_MEM_DEFS_VH
