//=============================================================================
// GARUDA SoC -- Block I: Processor Core
// branch_unit.v -- EX-stage branch resolution, JALR target, redirect
//
// Spec: AERO-GARUDA-DS-001 Rev 1.1, Sections 12.2 / 12.3.
//
// Responsibilities:
//   * Resolve conditional-branch direction in EX from forwarded operands
//     (dedicated comparator -- deliberately NOT the ALU, so the ALU adder
//     remains free and the comparator cone is short).
//   * Compare resolved direction against the ID-stage static prediction and
//     raise a mispredict redirect (2 bubbles, Section 12.3).
//   * Compute the JALR target (rs1_fwd + sext(Iimm)) & ~1 and always redirect
//     from EX for JALR (2 bubbles, Section 12.2).
//   * Provide the correction targets:
//       predicted not-taken, actually taken  -> pc + sext(Bimm)
//       predicted taken,     actually not    -> pc + 4
//
// INFERENCE NOTE (documented per Section 3.2 discipline):
//   1. Section 5.2's id_ex field list does not name a prediction bit; Section
//      12.3 requires one. `predicted_taken` is defined here as part of the
//      id_ex ctrl bundle. Spec candidate: add to Section 5.2 table.
//   2. The EX-side branch target pc + sext(Bimm) is RECOMPUTED here from the
//      id_ex pc and imm fields rather than piped down from the ID adder.
//      Both operands are already in id_ex, so this costs one 32-bit adder
//      and saves a 32-bit pipeline field. The ID adder (Section 12.2) still
//      exists for the predicted-taken redirect; the two must agree by
//      construction (same operands).
//
// The redirect output here covers EX-origin redirects only (mispredict,
// JALR). ID-origin redirects (predicted-taken branch, JAL) and CONTROL-origin
// redirects (trap, MRET) are muxed at core top per the redirect-mux priority.
//=============================================================================

module branch_unit
    import garuda_pkg::*;
    import core_ex_pkg::*;
(
    // id_ex payload
    input wire [WORD_W-1:0] pc,  // pc of the instruction in EX
    // sign-extended B-imm (is_branch) / I-imm (JALR)
    input wire [WORD_W-1:0] imm,
    input wire [FUNCT3_W-1:0] funct3_fld,
    // forwarded operands (post MUX_A/MUX_B register path)
    input wire [WORD_W-1:0] rs1_fwd,
    input wire [WORD_W-1:0] rs2_fwd,
    // ctrl
    input wire is_branch,  // conditional is_branch in EX
    input wire jal,  // JAL in EX (target = pc + Jimm)
    input wire jalr,  // JALR in EX
    input wire predicted_taken,  // ID's static prediction for this is_branch
    // resolution
    output wire redirect,  // EX-origin redirect request
    output wire [WORD_W-1:0] redirect_target,
    // ERRATUM T-1: instruction-address-misaligned (cause 0) detection.
    // Checked HERE rather than off `redirect`, because JAL and predicted-taken
    // branches redirect from ID (see the note above) and never assert
    // `redirect` at all - so an EX check hung off the redirect signal misses
    // exactly the JAL case that rv32mi/ma_fetch exercises.
    output wire target_misaligned
);
    timeunit 1ns;
    timeprecision 1ps;

    //------------------------------------------------------------------
    // Comparator
    //------------------------------------------------------------------
    wire eq  = (rs1_fwd == rs2_fwd);
    wire lt  = ($signed(rs1_fwd) < $signed(rs2_fwd));
    wire ltu = (rs1_fwd < rs2_fwd);

    // The compare named by funct3. 010 and 011 are reserved (a branch with them
    // traps in ID) and give "not taken"; the target mux below reads this for
    // every instruction in EX, so the default is a real arm, not a dead one.
    function automatic logic taken_of(input logic [FUNCT3_W-1:0] cmp_sel,
                                      input logic e, input logic l,
                                      input logic lu);
        begin
            case (cmp_sel)
                BR_BEQ: taken_of = e;
                BR_BNE: taken_of = ~e;
                BR_BLT: taken_of = l;
                BR_BGE: taken_of = ~l;
                BR_BLTU: taken_of = lu;
                BR_BGEU: taken_of = ~lu;
                default: taken_of = 1'b0;  // 010, 011
            endcase
        end
    endfunction

    wire taken_r = taken_of(funct3_fld, eq, lt, ltu);
    // the resolved direction (valid when is_branch); read by the unit's SVA
    // and bench, no port: nothing outside the unit uses it
    wire branch_taken = is_branch & taken_r;

    //------------------------------------------------------------------
    // Mispredict detection (Section 12.3)
    //------------------------------------------------------------------
    // prediction != resolution (internal since F4: it feeds redirect; the
    // unit's SVA, bench and the core coverage read it by name)
    wire mispredict = is_branch & (taken_r ^ predicted_taken);

    //------------------------------------------------------------------
    // Targets
    //------------------------------------------------------------------
    wire [WORD_W-1:0] branch_target = pc + imm;  // pc + sext(Bimm)
    wire [WORD_W-1:0] fallthrough   = pc + 32'd4;
    // (rs1+Iimm)&~1
    wire [WORD_W-1:0] jalr_target   = (rs1_fwd + imm) & 32'hFFFF_FFFE;

    // JALR always redirects from EX (Section 12.2). A mispredicted is_branch
    // redirects to the corrected path. jalr and is_branch are mutually
    // exclusive by decode.
    // Every taken control transfer, regardless of which stage redirects for it.
    // GARUDA has no C extension, so any target with bits[1:0] != 0 is illegal.
    assign target_misaligned = jalr ? (jalr_target[1:0] != 2'b00) :
                               (jal || branch_taken)
                                   ? (branch_target[1:0] != 2'b00) :
                                                      1'b0;

    // ERRATUM T-18: a JAL takes branch_target unconditionally. Its imm[14:12] /
    // rs1 / rs2 bit fields are not a funct3_fld and operands, so taken_r is
    // noise for it; before the fix a misaligned JAL whose fields read "not
    // taken" reported mtval = pc+4. JAL never asserts `redirect` (it redirects
    // from ID), so the only consumers of this for a JAL are the cause-0 mtval
    // and RVFI.
    assign redirect        = jalr | mispredict;
    assign redirect_target = jalr             ? jalr_target
                           : (jal || taken_r) ? branch_target
                                              : fallthrough;

endmodule
