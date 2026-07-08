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

`include "core_ex_defs.vh"

module branch_unit (
    // id_ex payload
    input  wire [31:0] pc,              // pc of the instruction in EX
    input  wire [31:0] imm,             // sign-extended B-imm (branch) / I-imm (JALR)
    input  wire [2:0]  funct3,
    // forwarded operands (post MUX_A/MUX_B register path)
    input  wire [31:0] rs1_fwd,
    input  wire [31:0] rs2_fwd,
    // ctrl
    input  wire        branch,          // conditional branch in EX
    input  wire        jalr,            // JALR in EX
    input  wire        predicted_taken, // ID's static prediction for this branch
    // resolution
    output wire        branch_taken,    // resolved direction (valid when branch)
    output wire        mispredict,      // prediction != resolution
    output wire        redirect,        // EX-origin redirect request
    output wire [31:0] redirect_target
);

    //------------------------------------------------------------------
    // Comparator
    //------------------------------------------------------------------
    wire eq  = (rs1_fwd == rs2_fwd);
    wire lt  = ($signed(rs1_fwd) < $signed(rs2_fwd));
    wire ltu = (rs1_fwd < rs2_fwd);

    reg taken_r;
    always @(*) begin
        case (funct3)
            `BR_BEQ:  taken_r = eq;
            `BR_BNE:  taken_r = ~eq;
            `BR_BLT:  taken_r = lt;
            `BR_BGE:  taken_r = ~lt;
            `BR_BLTU: taken_r = ltu;
            `BR_BGEU: taken_r = ~ltu;
            default:  taken_r = 1'b0;   // 010/011 reserved -> ID traps, never here
        endcase
    end

    assign branch_taken = branch & taken_r;

    //------------------------------------------------------------------
    // Mispredict detection (Section 12.3)
    //------------------------------------------------------------------
    assign mispredict = branch & (taken_r ^ predicted_taken);

    //------------------------------------------------------------------
    // Targets
    //------------------------------------------------------------------
    wire [31:0] branch_target = pc + imm;                       // pc + sext(Bimm)
    wire [31:0] fallthrough   = pc + 32'd4;
    wire [31:0] jalr_target   = (rs1_fwd + imm) & 32'hFFFF_FFFE; // (rs1+Iimm)&~1

    // JALR always redirects from EX (Section 12.2). A mispredicted branch
    // redirects to the corrected path. jalr and branch are mutually
    // exclusive by decode.
    assign redirect        = jalr | mispredict;
    assign redirect_target = jalr    ? jalr_target
                           : taken_r ? branch_target
                                     : fallthrough;

endmodule
