//=============================================================================
// GARUDA SoC -- Block I: Processor Core
// core_ex_defs.vh -- EX-stage shared encodings
//
// Spec:      AERO-GARUDA-DS-001 Rev 1.1  (Sections 8, 9, 11, 12)
// Status:    INFERENCE NOTE -- the spec does not define binary encodings for
//            alu_op or the forwarding selects. The encodings below are a
//            design decision made here and become normative for the ID
//            control decoder and the Hazard/Forwarding unit. Flag at the
//            next spec revision (candidate new section: 7.5 "Control
//            Encodings").
//=============================================================================

`ifndef CORE_EX_DEFS_VH
`define CORE_EX_DEFS_VH

// ALU operation select is the ID<->EX contract: single source of truth in
// rtl/common/garuda_defs.vh (11 ops incl. ALU_PASSB for LUI). Do NOT
// redefine ALU_* here - that is what let LUI's encoding drift.
`include "garuda_defs.vh"

//--------------------------------------------------------------------------
// Forwarding mux selects (Section 11.1). Driven by the Hazard/Forwarding
// unit. Applies to the *register* operand only; pc/imm substitution is a
// control-bundle decision layered on top (see ex_stage.v).
//--------------------------------------------------------------------------
`define FWD_NONE   2'b00   // register-file value (no hazard)
`define FWD_EXMEM  2'b01   // EX/MEM result  (EX->EX,  distance 1)
`define FWD_MEMWB  2'b10   // MEM/WB result  (MEM->EX, distance 2)

//--------------------------------------------------------------------------
// Branch funct3 (Section 12.3 / RV32I)
//--------------------------------------------------------------------------
`define BR_BEQ    3'b000
`define BR_BNE    3'b001
`define BR_BLT    3'b100
`define BR_BGE    3'b101
`define BR_BLTU   3'b110
`define BR_BGEU   3'b111

//--------------------------------------------------------------------------
// M-extension funct3 (multiply family only -- DIV/REM trap in ID, Sec 7.2)
//--------------------------------------------------------------------------
`define MUL_MUL     3'b000
`define MUL_MULH    3'b001
`define MUL_MULHSU  3'b010
`define MUL_MULHU   3'b011

//--------------------------------------------------------------------------
// CSR op (Section 13.3). Encoding matches funct3[1:0] of SYSTEM CSRR* so
// ID can pass instr[13:12] straight through.
//--------------------------------------------------------------------------
`define CSR_RW    2'b01
`define CSR_RS    2'b10
`define CSR_RC    2'b11

`endif // CORE_EX_DEFS_VH
