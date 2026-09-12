// =============================================================================
// soc_dma_smoke.S - SoC integration smoke test: CPU programs the DMA, both
//                   then fight for the same AHB-Lite layer.
//
// Runs on garuda_soc_top (core + DSU + DMA + interconnect). Executes from Boot
// ROM at the reset vector; all data lives in Data SRAM; the DMA registers are
// reached over the AHB-to-APB bridge.
//
// WHAT IT PROVES THAT A BLOCK-LEVEL TEST CANNOT
// --------------------------------------------
// Every store below is a D-Port transfer that has to be decoded, arbitrated
// against the I-Port's instruction fetches, and - for the DMA register writes -
// carried across the 200/100 MHz bridge. While the DMA is running, all three
// masters are live on three different slaves at once:
//
//     I-Port  fetching the poll loop from Boot ROM   (region 0x1)
//     D-Port  reading DMA.SR over the bridge          (region 0x4)
//     DMA     moving 64 words inside Data SRAM        (region 0x2)
//
// That is the traffic pattern nothing in this project had ever produced. The
// poll loop is deliberately a tight loop with a load in it rather than a WFI:
// it keeps both CPU ports asking for the bus on every cycle for the whole
// duration of the transfer, which is exactly the condition that starves a DMA
// on an arbiter that pins the grant to whoever is still requesting.
//
// EXIT PROTOCOL (riscv-tests convention, as used by tb_boot.v)
//     write 1         to tohost -> PASS
//     write (n<<1)|1  to tohost -> FAIL, test number n
//
// Written in plain GNU as syntax so it builds either with the real toolchain
// (sw/Makefile) or with tools/gen/mini_rv32_asm.py where riscv-gcc is absent.
// Only li/j/mv/nop pseudo-ops and RV32I base instructions are used.
// =============================================================================

    .section .text
    .globl _start

// ---- memory map (core spec Sec. 17 / AHB spec Sec. 6) ----
//   0x1000_0000  Boot ROM   (this code)
//   0x2000_0000  Data SRAM  src buffer
//   0x2000_1000  Data SRAM  dst buffer
//   0x2000_F000  Data SRAM  tohost
//   0x4000_5000  DMA channel 0 registers, via the bridge
//
//   DMA CR for this test: EN=1 DIR=M2M(10) SIZE=WORD(10) SINC=1 DINC=1
//                         CIRC=0 IE=0 EIE=0 PRI=7
//     bit12:10 PRI=111 -> 0x1C00
//     bit6     DINC    -> 0x0040
//     bit5     SINC    -> 0x0020
//     bit4:3   SIZE=10 -> 0x0010
//     bit2:1   DIR=10  -> 0x0004
//     bit0     EN      -> 0x0001
//                        = 0x1C75

_start:
// -----------------------------------------------------------------------------
// Phase 0 - prove the REAL DSU is in this build, not tb/stub/dsu_top_stub.v.
//
// The SoC filelist pulls rtl/core/filelist_core_dsu.f, so Block 2 is inside the
// core and reached only through Custom-0. If the stub were linked instead,
// dsu_rd_data is tied to zero and MACRD_LO returns 0 - so this sequence is the
// difference between "the DSU elaborates" and "the DSU is actually executing".
//
// Custom-0 R-type layout (rtl/dsu/dsu_decoder.v):
//     [31:27] funct5   [26:25] acc_sel   [24:20] rs2   [19:15] rs1
//     [14:12] funct3=000   [11:7] rd   [6:0] opcode=0001011
//
// MAC_SEL accumulates rs1[15:0] * rs2[15:0] into the selected accumulator
// (rtl/dsu/operand_router.v: a0/b0 are the low halves; a1/b1 are zero unless
// MACDOT). Two MACs of 7*6 must leave 84 in accumulator 0.
//
// These are .word because tools/gen/mini_rv32_asm.py is a stopgap with no
// Custom-0 support and gas would need a .insn directive anyway.
// -----------------------------------------------------------------------------
    li   x25, 7
    li   x26, 6
    .word 0x2800000b             // MACCLEAR  acc0        (funct5=5)
    .word 0x01ac800b             // MAC_SEL   acc0 += x25*x26   (funct5=0)
    .word 0x01ac800b             // MAC_SEL   acc0 += x25*x26
    .word 0x38000c0b             // MACRD_LO  x24 = acc0[31:0]  (funct5=7)
    li   x27, 84
    bne  x24, x27, dsu_bad

    li   x1, 0x20000000          // source base
    li   x2, 0x20001000          // destination base
    li   x9, 64                  // beat count

// -----------------------------------------------------------------------------
// Fill the source buffer with a value that encodes its own index, and clear the
// destination. A destination word that ends up holding another index is a
// beat-ordering bug; one holding a foreign tag is a routing bug.
// -----------------------------------------------------------------------------
    li   x3, 0
    li   x4, 0x5A5A0000
fill:
    slli x6, x3, 2
    add  x5, x4, x3
    add  x7, x1, x6
    sw   x5, 0(x7)
    add  x7, x2, x6
    sw   x0, 0(x7)
    addi x3, x3, 1
    blt  x3, x9, fill

// -----------------------------------------------------------------------------
// Program DMA channel 0. CR is written LAST - GARUDA-DMA-SPEC-001 Sec. 6.6
// makes that write, with EN=1, the start trigger.
// -----------------------------------------------------------------------------
    li   x10, 0x40005000         // channel 0 register block
    sw   x1,  0(x10)             // SAR
    sw   x2,  4(x10)             // DAR
    sw   x9,  8(x10)             // TCR = 64 beats
    li   x12, 0x1C75
    sw   x12, 12(x10)            // CR  (EN last)

// -----------------------------------------------------------------------------
// Poll SR.COMPLETE. Every iteration is a bridge read, so the D-Port is on the
// bus continuously while the DMA runs.
// -----------------------------------------------------------------------------
    li   x17, 0                  // poll counter, a liveness guard
    li   x18, 100000
poll:
    lw   x13, 16(x10)            // SR
    andi x14, x13, 1             // SR.COMPLETE
    bne  x14, x0, done_dma
    addi x17, x17, 1
    blt  x17, x18, poll
    li   x20, 5                  // (2<<1)|1 : timed out waiting for the DMA
    j    finish

done_dma:
// SR.ERROR must be clear: the transfer stayed inside Data SRAM the whole time,
// so any bus error means the fabric routed a beat somewhere it should not have.
    andi x15, x13, 2
    bne  x15, x0, err_flag

// CR.EN must have been cleared by hardware on single-shot completion.
    lw   x16, 12(x10)
    andi x16, x16, 1
    bne  x16, x0, en_stuck

// -----------------------------------------------------------------------------
// Compare the buffers word by word.
// -----------------------------------------------------------------------------
    li   x3, 0
check:
    slli x6, x3, 2
    add  x7, x1, x6
    lw   x21, 0(x7)
    add  x7, x2, x6
    lw   x22, 0(x7)
    bne  x21, x22, mismatch
    addi x3, x3, 1
    blt  x3, x9, check

    li   x20, 1                  // PASS
    j    finish

mismatch:
    li   x20, 7                  // (3<<1)|1
    j    finish
err_flag:
    li   x20, 9                  // (4<<1)|1
    j    finish
en_stuck:
    li   x20, 11                 // (5<<1)|1
    j    finish
dsu_bad:
    li   x20, 13                 // (6<<1)|1 : real DSU not executing Custom-0

finish:
    li   x23, 0x2000F000
    sw   x20, 0(x23)
hang:
    j    hang
