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

module csr_rw (
    // id_ex payload
    input  wire [31:0] instr,       // EX-stage instruction word
    input  wire [31:0] rs1_fwd,     // forwarded rs1 (register variants)
    // ctrl
    input  wire        csr_en,      // SYSTEM CSRR* in EX
    input  wire        csr_imm,     // 1 = immediate variant (funct3[2])
    input  wire [1:0]  csr_op,      // CSR_RW / CSR_RS / CSR_RC (= funct3[1:0])
    // exchange with CONTROL/CSR block
    output wire [11:0] csr_addr,
    output wire [31:0] csr_wdata,
    output wire [1:0]  csr_op_out,
    output wire        csr_en_out
);

    assign csr_addr   = instr[31:20];
    assign csr_wdata  = csr_imm ? {27'b0, instr[19:15]}   // zero-extended uimm
                                : rs1_fwd;
    assign csr_op_out = csr_op;
    assign csr_en_out = csr_en;

endmodule
