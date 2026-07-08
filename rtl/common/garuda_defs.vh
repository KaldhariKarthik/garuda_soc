// =============================================================================
// GARUDA SoC - Block I: Processor Core
// garuda_defs.vh - Shared core definitions (single source of truth)
// Document: AERO-GARUDA-DS-001 Rev 1.1
//
// Consolidates the ALU-op and immediate-select encodings that were
// previously inlined - identically - in decode_control.v and imm_gen.v.
//
// These encodings are a PRODUCER/CONSUMER contract: ID (decode_control,
// imm_gen) produces alu_op/imm_sel, EX (alu) consumes alu_op. They MUST
// have exactly one definition. If core_ex_defs.vh currently redefines
// ALU_* independently, change it to `include this header instead of
// carrying its own copy - otherwise the two drift silently and iverilog/
// xrun will emit macro-redefinition warnings when ID and EX compile
// together.
// =============================================================================
`ifndef GARUDA_DEFS_VH
`define GARUDA_DEFS_VH

// ALU operation encoding (EX-stage ALU, Sec. 8.1)
`define ALU_ADD   4'h0
`define ALU_SUB   4'h1
`define ALU_AND   4'h2
`define ALU_OR    4'h3
`define ALU_XOR   4'h4
`define ALU_SLL   4'h5
`define ALU_SRL   4'h6
`define ALU_SRA   4'h7
`define ALU_SLT   4'h8
`define ALU_SLTU  4'h9
`define ALU_PASSB 4'hA   // LUI: result = operand B (immediate)

// Immediate-form select (Sec. 7.3)
`define IMM_I    3'h0
`define IMM_S    3'h1
`define IMM_B    3'h2
`define IMM_U    3'h3
`define IMM_J    3'h4
`define IMM_CSR  3'h5   // 5-bit zero-extended rs1, CSRRWI/SI/CI (Sec. 13.3)
`define IMM_NONE 3'h6

`endif // GARUDA_DEFS_VH
