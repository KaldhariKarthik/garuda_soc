`timescale 1ns/1ps
//=============================================================================
// tb_garuda_pc_gen.v -- unit TB for rtl/core/garuda_pc_gen.v
//
// Spec:  AERO-GARUDA-DS-001 Rev 1.1, Sec. 6.2 (PC and fetch-address
//        generation), Sec. 2.1 / 17 (reset vector), Sec. 6.5 (redirect).
// Plan:  C28 ("Reset: PC = 0x1000_0000"), and the PC half of C14/C15
//        (fetch-ahead and redirect).
// Coverage note: docs/COVERAGE.md lists garuda_pc_gen at 75.94% with
//        "redirect-source priority combinations" as the named gap. The
//        priority checks below (redirect vs commit, redirect vs fetch_issue,
//        redirect vs both) target exactly that row.
//
// Checked:
//   * Reset: BOTH pc_o and fetch_pc_o load 0x1000_0000 (Boot ROM). A reset
//     that initialised only fetch_pc would still boot correctly and fail
//     here, which is the point.
//   * fetch_pc advances by 4 per accepted address phase (fetch_issue_i) and
//     ONLY then -- it must not track commit_i.
//   * pc advances to commit_pc_i + 4, taking its value from the POPPED
//     entry's tag rather than from its own previous value. Driven with a
//     non-contiguous commit_pc to prove it is the tag that is used: a
//     "pc <= pc + 4" implementation passes a contiguous stream and fails
//     here.
//   * fetch_pc runs AHEAD of pc: four issues with no commit leave a 16-byte
//     gap, matching the depth-4 buffer (Sec. 6.2 "runs ahead of pc by up to
//     the buffer depth").
//   * Redirect reloads BOTH pointers in the same cycle (Sec. 6.2/6.5) and
//     outranks commit_i and fetch_issue_i asserted on the same edge -- the
//     redirect target must not be corrupted by a +4 from either source.
//   * Idle: with no input asserted, neither pointer moves.
//=============================================================================

module tb_garuda_pc_gen;

  reg         clk = 0, rst_n;
  reg         redirect;
  reg  [31:0] redirect_pc;
  reg         fetch_issue;
  reg         commit;
  reg  [31:0] commit_pc;
  wire [31:0] pc, fetch_pc;

  integer errors = 0;
  integer i;

  localparam RESET_VECTOR = 32'h1000_0000;

  always #5 clk = ~clk;

  garuda_pc_gen dut (
    .clk_i(clk), .rst_n_i(rst_n),
    .redirect_i(redirect), .redirect_pc_i(redirect_pc),
    .fetch_issue_i(fetch_issue),
    .commit_i(commit), .commit_pc_i(commit_pc),
    .pc_o(pc), .fetch_pc_o(fetch_pc));

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

  // One clock edge with the given stimulus, then settle.
  task step;
    input        rdir;
    input [31:0] rpc;
    input        fiss;
    input        cmt;
    input [31:0] cpc;
    begin
      @(negedge clk);
      redirect = rdir; redirect_pc = rpc;
      fetch_issue = fiss; commit = cmt; commit_pc = cpc;
      @(posedge clk);
      #1;
    end
  endtask

  task idle;
    begin step(1'b0, 32'd0, 1'b0, 1'b0, 32'd0); end
  endtask

  initial begin
    rst_n = 0; redirect = 0; redirect_pc = 0;
    fetch_issue = 0; commit = 0; commit_pc = 0;

    // ---- reset vector (Sec. 2.1 / 17, test C28) ------------------------
    #3;
      c32("reset_pc",       pc,       RESET_VECTOR);
      c32("reset_fetch_pc", fetch_pc, RESET_VECTOR);
    @(negedge clk); rst_n = 1;

    // ---- idle: nothing moves --------------------------------------------
    idle;
      c32("idle_pc",       pc,       RESET_VECTOR);
      c32("idle_fetch_pc", fetch_pc, RESET_VECTOR);

    // ---- fetch_issue advances fetch_pc only ----------------------------
    step(1'b0, 32'd0, 1'b1, 1'b0, 32'd0);
      c32("issue1_fetch_pc", fetch_pc, RESET_VECTOR + 32'd4);
      c32("issue1_pc_still", pc,       RESET_VECTOR);
    step(1'b0, 32'd0, 1'b1, 1'b0, 32'd0);
    step(1'b0, 32'd0, 1'b1, 1'b0, 32'd0);
    step(1'b0, 32'd0, 1'b1, 1'b0, 32'd0);
      // four accepted fetches with no pop: fetch_pc leads pc by the
      // buffer depth (Sec. 6.2)
      c32("issue4_fetch_pc", fetch_pc, RESET_VECTOR + 32'd16);
      c32("issue4_pc_still", pc,       RESET_VECTOR);

    // ---- commit advances pc to commit_pc + 4 ---------------------------
    step(1'b0, 32'd0, 1'b0, 1'b1, RESET_VECTOR);
      c32("commit1_pc",        pc,       RESET_VECTOR + 32'd4);
      c32("commit1_fetch_hold", fetch_pc, RESET_VECTOR + 32'd16);
    // pc follows the POPPED ENTRY'S TAG, not its own previous value.
    // A "pc <= pc + 4" implementation would give ...0008 here.
    step(1'b0, 32'd0, 1'b0, 1'b1, 32'h2000_0040);
      c32("commit_uses_tag", pc, 32'h2000_0044);

    // ---- both pointers advance independently in the same cycle ---------
    step(1'b0, 32'd0, 1'b1, 1'b1, 32'h2000_0044);
      c32("both_pc",       pc,       32'h2000_0048);
      c32("both_fetch_pc", fetch_pc, RESET_VECTOR + 32'd20);

    // ---- redirect reloads BOTH pointers in one cycle (Sec. 6.2/6.5) ----
    step(1'b1, 32'h3000_0100, 1'b0, 1'b0, 32'd0);
      c32("redir_pc",       pc,       32'h3000_0100);
      c32("redir_fetch_pc", fetch_pc, 32'h3000_0100);

    // ---- redirect priority (COVERAGE.md Category C gap) ----------------
    // vs commit
    step(1'b1, 32'h4000_0200, 1'b0, 1'b1, 32'h1111_1110);
      c32("redir_over_commit_pc",    pc,       32'h4000_0200);
      c32("redir_over_commit_fetch", fetch_pc, 32'h4000_0200);
    // vs fetch_issue
    step(1'b1, 32'h4000_0300, 1'b1, 1'b0, 32'd0);
      c32("redir_over_issue_pc",    pc,       32'h4000_0300);
      c32("redir_over_issue_fetch", fetch_pc, 32'h4000_0300);
    // vs both at once -- neither +4 may leak into the target
    step(1'b1, 32'h4000_0400, 1'b1, 1'b1, 32'h1111_1110);
      c32("redir_over_both_pc",    pc,       32'h4000_0400);
      c32("redir_over_both_fetch", fetch_pc, 32'h4000_0400);
    // back-to-back redirects: the second target wins, no stale value
    step(1'b1, 32'h5000_0000, 1'b0, 1'b0, 32'd0);
    step(1'b1, 32'h6000_0000, 1'b0, 1'b0, 32'd0);
      c32("back2back_redir_pc",    pc,       32'h6000_0000);
      c32("back2back_redir_fetch", fetch_pc, 32'h6000_0000);
    // redirect to the reset vector and to address 0 (no special-casing)
    step(1'b1, 32'h0000_0000, 1'b0, 1'b0, 32'd0);
      c32("redir_to_zero_pc", pc, 32'h0000_0000);

    // ---- normal operation resumes after a redirect ---------------------
    step(1'b0, 32'd0, 1'b1, 1'b0, 32'd0);
      c32("post_redir_issue", fetch_pc, 32'h0000_0004);

    // ---- sustained fetch stream: fetch_pc is a clean +4 sequence -------
    step(1'b1, RESET_VECTOR, 1'b0, 1'b0, 32'd0);
    for (i = 1; i <= 8; i = i + 1) begin
      step(1'b0, 32'd0, 1'b1, 1'b0, 32'd0);
      if (fetch_pc !== RESET_VECTOR + (i * 4)) begin
        $display("FAIL stream fetch_pc step %0d: got %h exp %h",
                 i, fetch_pc, RESET_VECTOR + (i * 4));
        errors = errors + 1;
      end
    end

    // ---- reset asserted mid-stream returns to the reset vector ---------
    rst_n = 0; #1;
      c32("re_reset_pc",       pc,       RESET_VECTOR);
      c32("re_reset_fetch_pc", fetch_pc, RESET_VECTOR);
    @(negedge clk); rst_n = 1;

    if (errors == 0) $display("PC_GEN UNIT: ALL CHECKS PASSED");
    else             $display("PC_GEN UNIT: %0d FAILURE(S)", errors);
    $finish;
  end
endmodule
