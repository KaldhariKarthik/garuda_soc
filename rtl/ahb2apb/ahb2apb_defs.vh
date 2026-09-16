// =============================================================================
// GARUDA SoC - Block 8: AHB-to-APB Bridge
// ahb2apb_defs.vh - shared bridge constants (single source of truth)
//
// Document: GARUDA-BRG-SPEC-001 Rev 2.0
//
// The FSM encodings below are a producer/consumer contract between the two
// domain sequencers and the top that wires them, and the window map is a
// contract between this block and every APB peripheral. One definition each.
// =============================================================================
`ifndef GARUDA_AHB2APB_DEFS_VH
`define GARUDA_AHB2APB_DEFS_VH

// -----------------------------------------------------------------------------
// hclk-side sequencer states (Sec. 7.2)
//
// H_RESP_OKAY is split from the two error states so that EVERY AHB response
// output is an explicit function of state and is directly RTL-codable. Merging
// "completion" into one state with a conditional HRESP is how a single-cycle
// error creeps in, and a single-cycle error corrupts the DMA's following beat.
// -----------------------------------------------------------------------------
`define BRG_H_IDLE       3'd0
`define BRG_H_CAPTURE    3'd1
`define BRG_H_WAIT_ACK   3'd2
`define BRG_H_RESP_OKAY  3'd3
`define BRG_H_ERROR_1    3'd4
`define BRG_H_ERROR_2    3'd5

// -----------------------------------------------------------------------------
// pclk-side APB sequencer states (Sec. 7.4)
// -----------------------------------------------------------------------------
`define BRG_P_IDLE       2'd0
`define BRG_P_SETUP      2'd1
`define BRG_P_ACCESS     2'd2

// -----------------------------------------------------------------------------
// AHB constants. Spelled the same way as rtl/ahb/ahb_defs.vh deliberately;
// not `included from there because this block must compile standalone in its
// own block-level testbench.
// -----------------------------------------------------------------------------
`define BRG_TRANS_IDLE   2'b00
`define BRG_TRANS_BUSY   2'b01
`define BRG_TRANS_NONSEQ 2'b10
`define BRG_TRANS_SEQ    2'b11

`define BRG_SIZE_BYTE    3'b000
`define BRG_SIZE_HALF    3'b001
`define BRG_SIZE_WORD    3'b010

`define BRG_RESP_OKAY    1'b0
`define BRG_RESP_ERROR   1'b1

// -----------------------------------------------------------------------------
// Peripheral window map - PADDR[15:12], sixteen 4 KB windows (Sec. 6)
//
// ONLY THE DMA WINDOW IS FROZEN. GARUDA-DMA-SPEC-001 Sec. 1.1 fixes the DMA
// configuration port at 0x4000_5000, and the bridge spec fixes the region base
// at 0x4000_0000; everything else in this map is PROPOSED and is adopted by
// each peripheral's own specification when that specification is written.
//
// The assignments below follow the one other data point in the project: the
// DMA spec quotes 0x4000_1004 as the SPI RX FIFO address, which puts SPI Master
// in window 1. The rest are laid out around it in TRM peripheral order. The
// TRM memory map (Sec. III.IV) allocates the 0x4000_0000 region as a whole and
// assigns no individual windows, so there is nothing here to contradict.
//
// A window that is not in BRG_WINDOW_MASK decodes to no PSEL and produces a
// two-cycle ERROR (Sec. 8.5). That is the correct behaviour for an address
// with no peripheral behind it, and it is why the mask is a parameter: a build
// that instantiates fewer peripherals should fault on the absent ones rather
// than silently selecting nothing and hanging.
// -----------------------------------------------------------------------------
`define BRG_WIN_SPI_M    4'h1     // proposed
`define BRG_WIN_SPI_S    4'h2     // proposed
`define BRG_WIN_I2C      4'h3     // proposed
`define BRG_WIN_UART     4'h4     // proposed
`define BRG_WIN_DMA      4'h5     // FROZEN - DMA Sec. 1.1
`define BRG_WIN_PWM      4'h6     // proposed
`define BRG_WIN_GPIO     4'h7     // proposed
`define BRG_WIN_TIMERS   4'h8     // proposed
`define BRG_WIN_CLIC     4'h9     // proposed - CLIC Sec. 4 requires one window

// Default mask for the SoC as it exists today: the DMA (frozen) and the CLIC
// (the only other block with RTL that needs a config port). Every other window
// faults, which is what should happen while those peripherals do not exist.
`define BRG_WINDOW_MASK_DEFAULT  16'b0000_0010_0010_0000   // bits 9 and 5

`endif // GARUDA_AHB2APB_DEFS_VH
