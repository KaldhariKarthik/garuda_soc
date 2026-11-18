//=============================================================================
// GARUDA SoC -- Block I: Processor Core
// csr_rw.v -- EX-stage CSR read-modify-write seam (CSR_RW block)
//
// Spec: AERO-GARUDA-DS-001 Rev 1.1, Sections 8.3 / 8.4 / 13.3.
//
// This block is deliberately thin: architectural CSR state lives in the
// non-pipelined CONTROL/CSR block, NOT here (Section 8.4). CSR_RW's job is
// only to form the EX-side half of the exchange:
//
//   CSR_RW -> CONTROL : csr_addr, csr_wdata, csr_op   (+ csr_en qualifier)
//   CONTROL -> CSR_RW : csr_rdata                     (combinational return)
//
// csr_rdata re-enters the EX result mux in ex_stage.v as the HIGHEST-priority
// input, gated by csr_en -- this is the ratified erratum 6.3-E1 / Option A
// path (Section 8.3). Keep it a named module even though it is mostly wiring:
// the CONTROL handshake needs one owned seam, and CSR-side write-legality /
// illegal-CSR trapping is CONTROL's job, not EX's.
//
// Write-source selection (Section 8.4):
//   register variants  (CSRRW/S/C)   : csr_wdata = forwarded rs1
//   immediate variants (CSRRW/S/CI)  : csr_wdata = zero-extended instr[19:15]
//
// The uimm field aliases the rs1 index bits; ID must gate off the rs1 hazard
// check for immediate variants (no register is actually read). That gating
// belongs to the Hazard unit and is noted here as the integration hook.
//=============================================================================

module csr_rw
    import garuda_pkg::*;
(
    input wire [WORD_W-1:0] rs1_fwd,  // forwarded rs1 (register variants)
    input wire csr_imm,  // 1 = immediate variant (funct3[2])
    input wire [REG_IDX_W-1:0] zimm,  // instr[19:15]: the immediate's uimm
    output wire [WORD_W-1:0] csr_wdata
);
    timeunit 1ns;
    timeprecision 1ps;

    // F4 (2026-11-17): the CSR address, op and enable no longer pass through
    // here; csr_file takes them from ID/EX directly (they were feedthroughs).
    // zero-extended uimm, or the register operand
    assign csr_wdata = csr_imm ? WORD_W'(zimm) : rs1_fwd;

endmodule
