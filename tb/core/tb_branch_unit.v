`timescale 1ns/1ps
//=============================================================================
// tb_branch_unit.v -- unit TB for rtl/core/branch_unit.v
//
// Spec:  AERO-GARUDA-DS-001 Rev 1.1, Sec. 12.2 / 12.3, plus ERRATUM T-1
//        (instruction-address-misaligned, cause 0) as implemented in the RTL.
// Plan:  C06 (static prediction), C07 (mispredict both directions, 2-bubble
//        flush), C08 (JAL link/target), C09 (JALR target and forwarded rs1).
//        The bubble COUNTS are a pipe_ctrl/core-level property -- this TB
//        verifies the redirect request and target that drive them.
//
// Key behaviours checked:
//   * All six comparisons BEQ/BNE/BLT/BGE/BLTU/BGEU, signed vs unsigned
//     separated by the (-1, 1) pair.
//   * branch_taken is qualified by branch -- a matching funct3 on a
//     non-branch instruction must not report taken.
//   * mispredict = branch & (resolved ^ predicted): a correct prediction in
//     BOTH directions must NOT redirect (Sec. 12.3 "no action").
//   * Correction targets (Sec. 12.3):
//       predicted not-taken, actually taken -> pc + sext(Bimm)
//       predicted taken,     actually not   -> pc + 4
//   * JALR: target = (rs1_fwd + imm) & ~1. The LSB clear is checked with an
//     odd sum, which RISC-V requires to be masked rather than trapped. JALR
//     redirects unconditionally (Sec. 12.2), independent of funct3 and of
//     predicted_taken.
//   * ERRATUM T-1: target_misaligned is raised off JAL and off a TAKEN
//     branch, not off redirect -- so the JAL case (which redirects from ID
//     and never asserts redirect here) is checked explicitly. A JALR whose
//     sum has bit 1 set is misaligned even though bit 0 was masked away.
//   * A not-taken branch and a plain ALU op raise nothing.
//=============================================================================
`include "core_ex_defs.vh"

module tb_branch_unit;

  reg  [31:0] pc, imm, rs1_fwd, rs2_fwd;
  reg  [2:0]  funct3;
  reg         branch, jal, jalr, predicted_taken;
  wire        branch_taken, mispredict, redirect, target_misaligned;
  wire [31:0] redirect_target;
  integer     errors = 0;

  branch_unit dut (
    .pc(pc), .imm(imm), .funct3(funct3),
    .rs1_fwd(rs1_fwd), .rs2_fwd(rs2_fwd),
    .branch(branch), .jal(jal), .jalr(jalr),
    .predicted_taken(predicted_taken),
    .branch_taken(branch_taken), .mispredict(mispredict),
    .redirect(redirect), .redirect_target(redirect_target),
    .target_misaligned(target_misaligned));

  task clr;
    begin
      pc = 32'h1000_0100; imm = 32'd0; rs1_fwd = 32'd0; rs2_fwd = 32'd0;
      funct3 = `BR_BEQ; branch = 0; jal = 0; jalr = 0; predicted_taken = 0;
    end
  endtask

  task c;
    input [255:0] n;
    input g, e;
    begin
      if (g !== e) begin
        $display("FAIL %0s: got %b exp %b", n, g, e);
        errors = errors + 1;
      end
    end
  endtask

  task c32;
    input [255:0] n;
    input [31:0] g, e;
    begin
      if (g !== e) begin
        $display("FAIL %0s: got %h exp %h", n, g, e);
        errors = errors + 1;
      end
    end
  endtask

  // Drive one conditional branch and check the resolved direction.
  task br;
    input [2:0] f3;
    input [31:0] a, b;
    input exp_taken;
    begin
      clr; branch = 1; funct3 = f3; rs1_fwd = a; rs2_fwd = b; #1;
      c("branch_taken", branch_taken, exp_taken);
    end
  endtask

  initial begin
    // ---- comparator, all six funct3 (Sec. 12.3) ------------------------
    br(`BR_BEQ,  32'd5, 32'd5, 1'b1);
    br(`BR_BEQ,  32'd5, 32'd6, 1'b0);
    br(`BR_BNE,  32'd5, 32'd6, 1'b1);
    br(`BR_BNE,  32'd5, 32'd5, 1'b0);
    br(`BR_BLT,  32'hFFFF_FFFF, 32'd1, 1'b1);   // -1 <  1  signed
    br(`BR_BLT,  32'd1, 32'hFFFF_FFFF, 1'b0);
    br(`BR_BGE,  32'd1, 32'hFFFF_FFFF, 1'b1);   //  1 >= -1 signed
    br(`BR_BGE,  32'd5, 32'd5,         1'b1);   //  equal counts as >=
    br(`BR_BLTU, 32'd1, 32'hFFFF_FFFF, 1'b1);   //  1 <  4G unsigned
    br(`BR_BLTU, 32'hFFFF_FFFF, 32'd1, 1'b0);   //  the signed/unsigned split
    br(`BR_BGEU, 32'hFFFF_FFFF, 32'd1, 1'b1);
    br(`BR_BGEU, 32'd5, 32'd5,         1'b1);

    // branch_taken must be gated by the branch control bit
    clr; branch = 0; funct3 = `BR_BEQ; rs1_fwd = 32'd5; rs2_fwd = 32'd5; #1;
      c("taken_gated_by_branch",  branch_taken, 1'b0);
      c("no_redirect_non_branch", redirect,     1'b0);

    // ---- correct predictions cost nothing (Sec. 12.3) ------------------
    clr; branch = 1; funct3 = `BR_BEQ; rs1_fwd = 5; rs2_fwd = 5;
         predicted_taken = 1; imm = 32'hFFFF_FFF0; #1;    // backward, taken
      c("pred_taken_correct_nomis",   mispredict, 1'b0);
      c("pred_taken_correct_noredir", redirect,   1'b0);
    clr; branch = 1; funct3 = `BR_BEQ; rs1_fwd = 5; rs2_fwd = 6;
         predicted_taken = 0; imm = 32'd16; #1;           // forward, not taken
      c("pred_nt_correct_nomis",   mispredict, 1'b0);
      c("pred_nt_correct_noredir", redirect,   1'b0);

    // ---- mispredict, both directions (C07) -----------------------------
    // predicted not-taken, actually taken -> redirect to pc + Bimm
    clr; branch = 1; funct3 = `BR_BEQ; rs1_fwd = 5; rs2_fwd = 5;
         predicted_taken = 0; pc = 32'h1000_0100; imm = 32'd32; #1;
      c("mis_nt2t",       mispredict, 1'b1);
      c("mis_nt2t_redir", redirect,   1'b1);
      c32("mis_nt2t_tgt", redirect_target, 32'h1000_0120);
    // predicted taken, actually not taken -> redirect to pc + 4
    clr; branch = 1; funct3 = `BR_BEQ; rs1_fwd = 5; rs2_fwd = 6;
         predicted_taken = 1; pc = 32'h1000_0100; imm = 32'hFFFF_FFF0; #1;
      c("mis_t2nt",       mispredict, 1'b1);
      c("mis_t2nt_redir", redirect,   1'b1);
      c32("mis_t2nt_tgt", redirect_target, 32'h1000_0104);
    // backward-branch target arithmetic (negative Bimm)
    clr; branch = 1; funct3 = `BR_BNE; rs1_fwd = 1; rs2_fwd = 2;
         predicted_taken = 0; pc = 32'h1000_0100; imm = 32'hFFFF_FFE0; #1;
      c32("back_branch_tgt", redirect_target, 32'h1000_00E0);

    // ---- JALR (C09) ----------------------------------------------------
    // target = (rs1 + imm) & ~1; redirects unconditionally from EX
    clr; jalr = 1; rs1_fwd = 32'h2000_0004; imm = 32'd8; pc = 32'h1000_0100; #1;
      c("jalr_redirect", redirect, 1'b1);
      c32("jalr_target", redirect_target, 32'h2000_000C);
    // odd sum: bit 0 is MASKED, not trapped. 0x2000_0005 + 2 = 0x2000_0007,
    // masked to 0x2000_0006 -- still misaligned because bit 1 is set.
    clr; jalr = 1; rs1_fwd = 32'h2000_0005; imm = 32'd2; #1;
      c32("jalr_lsb_masked",   redirect_target,   32'h2000_0006);
      c("jalr_bit1_misaligned", target_misaligned, 1'b1);
    clr; jalr = 1; rs1_fwd = 32'h2000_0001; imm = 32'd3; #1;   // sum ...0004
      c32("jalr_odd_sum_aligned", redirect_target,   32'h2000_0004);
      c("jalr_aligned_ok",        target_misaligned, 1'b0);
    // negative offset, and independence from predicted_taken / funct3
    clr; jalr = 1; rs1_fwd = 32'h2000_0010; imm = 32'hFFFF_FFF8;
         predicted_taken = 1; funct3 = `BR_BGEU; #1;
      c("jalr_redirect_any_pred", redirect, 1'b1);
      c32("jalr_neg_target",      redirect_target, 32'h2000_0008);
      c("jalr_no_mispredict",     mispredict, 1'b0);

    // ---- ERRATUM T-1: instruction-address-misaligned (cause 0) ---------
    // JAL redirects from ID and never asserts redirect -- the misalign check
    // must still fire. This is the rv32mi/ma_fetch case.
    clr; jal = 1; pc = 32'h1000_0100; imm = 32'd2; #1;
      c("jal_misaligned",     target_misaligned, 1'b1);
      c("jal_no_ex_redirect", redirect,          1'b0);
    clr; jal = 1; pc = 32'h1000_0100; imm = 32'd8; #1;
      c("jal_aligned", target_misaligned, 1'b0);
    // taken branch to a misaligned target
    clr; branch = 1; funct3 = `BR_BEQ; rs1_fwd = 7; rs2_fwd = 7;
         pc = 32'h1000_0100; imm = 32'd6; #1;
      c("branch_taken_misaligned", target_misaligned, 1'b1);
    // NOT-taken branch to a misaligned target raises nothing
    clr; branch = 1; funct3 = `BR_BEQ; rs1_fwd = 7; rs2_fwd = 8;
         pc = 32'h1000_0100; imm = 32'd6; #1;
      c("branch_nottaken_no_misalign", target_misaligned, 1'b0);
    // plain ALU instruction: silent on every output
    clr; #1;
      c("idle_redirect",   redirect,          1'b0);
      c("idle_mispredict", mispredict,        1'b0);
      c("idle_misaligned", target_misaligned, 1'b0);
      c("idle_taken",      branch_taken,      1'b0);

    if (errors == 0) $display("BRANCH_UNIT UNIT: ALL CHECKS PASSED");
    else             $display("BRANCH_UNIT UNIT: %0d FAILURE(S)", errors);
    $finish;
  end
endmodule
