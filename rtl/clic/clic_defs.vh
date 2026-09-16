// =============================================================================
// GARUDA SoC - Block 16: CLIC (Core-Local Interrupt Controller)
// clic_defs.vh - shared CLIC constants (single source of truth)
//
// Document: GARUDA-CLIC-SPEC-001 Rev 2.0
//
// Register-block and internal signal names follow the RISC-V CLIC draft
// (clicintip/ie/attr/ctl). The CORE-FACING names are frozen by the core
// boundary (core Sec. 4.1) and are matched exactly - those are not proposals.
// =============================================================================
`ifndef GARUDA_CLIC_DEFS_VH
`define GARUDA_CLIC_DEFS_VH

// -----------------------------------------------------------------------------
// Geometry (Sec. 2, Sec. 6.2)
//
// CLIC_N is the number of implemented sources. GARUDA populates the first
// twelve from the DMA - [5:0] = dma_irq (channel complete), [11:6] = dma_err
// (channel bus error) - and the rest from peripherals and timers. The DMA
// occupies the first twelve to keep its complete/error pairs contiguous.
// -----------------------------------------------------------------------------
`define CLIC_N_DEFAULT   32

// Level is 3 bits (0-7). Level 0 means "never interrupts" and is NOT a
// priority - it is a mask that no enable can override (Sec. 6.5, Sec. 7.1).
`define CLIC_LVL_W        3

// The core interface carries a 12-bit id and an 8-bit level (core Sec. 4.1).
// Only CLIC_N ids are ever used and only 3 level bits are implemented; the
// level is zero-extended onto the 8-bit port.
`define CLIC_CORE_ID_W   12
`define CLIC_CORE_LVL_W   8

// -----------------------------------------------------------------------------
// APB register groups, PADDR[11:10] (Sec. 6.1)
//
//   0x000 + i   clicintip[i]    R/W1C   pending
//   0x400 + i   clicintie[i]    R/W     enable
//   0x800 + i   clicintattr[i]  R/W     trigger type + hardware vectoring
//   0xC00 + i   clicintctl[i]   R/W     level
//
// The threshold is deliberately NOT in this map. mintthresh is a CORE CSR
// presented on mintthresh_i (core Sec. 4.1, Sec. 14.3); duplicating it as a
// CLIC register would create two places to set one policy.
// -----------------------------------------------------------------------------
`define CLIC_GRP_IP      2'b00
`define CLIC_GRP_IE      2'b01
`define CLIC_GRP_ATTR    2'b10
`define CLIC_GRP_CTL     2'b11

// -----------------------------------------------------------------------------
// clicintattr bit positions (Sec. 6.4)
// -----------------------------------------------------------------------------
`define CLIC_ATTR_TRIG    0   // 0 = level-sensitive (default), 1 = rising edge
`define CLIC_ATTR_SHV     1   // 1 = selective hardware vectoring via mtvt

`define CLIC_TRIG_LEVEL  1'b0
`define CLIC_TRIG_EDGE   1'b1

// -----------------------------------------------------------------------------
// clicintctl level field (Sec. 6.5)
//
// The 3 implemented level bits sit in the HIGH bits of the byte so that the
// CLIC-draft convention "more implemented bits = finer priority" holds: an
// implementation that later adds bits extends downwards without moving the
// ones that already exist.
// -----------------------------------------------------------------------------
`define CLIC_CTL_LVL_HI   7
`define CLIC_CTL_LVL_LO   5

`endif // GARUDA_CLIC_DEFS_VH
