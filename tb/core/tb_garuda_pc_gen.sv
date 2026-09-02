// =============================================================================
// tb_garuda_pc_gen.sv -- SystemVerilog unit TB for rtl/core/garuda_pc_gen.v
//
// Spec: AERO-GARUDA-DS-001 Rev 1.1, Sec. 6.2 (PC and fetch-address
//       generation), Sec. 2.1 / 17 (reset vector 0x1000_0000, Boot ROM),
//       Sec. 6.5 (redirect).
// Plan: C28 ("Reset: PC = 0x1000_0000"), plus the PC half of C14/C15.
//
// Coverage note: docs/COVERAGE.md Category C lists garuda_pc_gen at 75.94%
// with "redirect-source priority combinations (trap vs EX vs ID in the same
// cycle)" as the named next action. From this block's port list those all
// arrive as one redirect_i/redirect_pc_i pair -- the SOURCE arbitration is
// the redirect mux's job at core top. What this block owns is that a
// redirect BEATS the two things that would otherwise move a pointer in the
// same cycle: commit_i and fetch_issue_i. Those three combinations, plus
// back-to-back redirects, are the sequences below and the cp_priority
// covergroup bins.
//
// The discriminating check: pc advances to commit_pc_i + 4, taking its value
// from the POPPED ENTRY'S TAG rather than from its own previous value. A
// "pc <= pc + 4" implementation is correct for a contiguous instruction
// stream and fails only when the tag is discontinuous -- so the directed
// sequence commits a deliberately non-contiguous PC.
//
// No inlined DUT snapshot -- see the note in tb_alu.sv.
// =============================================================================

`timescale 1ns/1ps

interface pc_gen_if (input bit clk, input bit rst_n);
    logic        redirect;
    logic [31:0] redirect_pc;
    logic        fetch_issue;
    logic        commit;
    logic [31:0] commit_pc;
    logic [31:0] pc;
    logic [31:0] fetch_pc;

    localparam bit [31:0] RESET_VECTOR = 32'h1000_0000;

    // A1: a redirect reloads BOTH pointers with the target, in the same
    //     cycle, and outranks everything else presented on that edge
    //     (Sec. 6.2 / 6.5). This single property covers all three priority
    //     combinations the coverage report asks for.
    property p_redirect_wins;
        @(posedge clk) disable iff (!rst_n)
            redirect |=> ((pc == $past(redirect_pc)) &&
                          (fetch_pc == $past(redirect_pc)));
    endproperty
    a_redirect_wins: assert property (p_redirect_wins)
        else $error("[SVA-FAIL] a redirect did not reload both pointers with the target");

    // A2: fetch_pc advances by exactly 4 per accepted address phase, and
    //     ONLY on an accepted address phase -- it must not track commit_i.
    property p_fetch_pc_step;
        @(posedge clk) disable iff (!rst_n)
            (!redirect && fetch_issue) |=> (fetch_pc == $past(fetch_pc) + 32'd4);
    endproperty
    a_fetch_step: assert property (p_fetch_pc_step)
        else $error("[SVA-FAIL] fetch_pc did not advance by 4 on an accepted fetch");

    property p_fetch_pc_holds;
        @(posedge clk) disable iff (!rst_n)
            (!redirect && !fetch_issue) |=> (fetch_pc == $past(fetch_pc));
    endproperty
    a_fetch_hold: assert property (p_fetch_pc_holds)
        else $error("[SVA-FAIL] fetch_pc moved without an accepted fetch");

    // A3: pc follows the POPPED ENTRY'S TAG + 4, not its own previous value.
    property p_pc_from_commit_tag;
        @(posedge clk) disable iff (!rst_n)
            (!redirect && commit) |=> (pc == $past(commit_pc) + 32'd4);
    endproperty
    a_pc_tag: assert property (p_pc_from_commit_tag)
        else $error("[SVA-FAIL] pc did not advance to commit_pc + 4");

    property p_pc_holds;
        @(posedge clk) disable iff (!rst_n)
            (!redirect && !commit) |=> (pc == $past(pc));
    endproperty
    a_pc_hold: assert property (p_pc_holds)
        else $error("[SVA-FAIL] pc moved without a commit");

    // A4: both pointers are always 4-byte aligned -- GARUDA has no C
    //     extension, and every source that writes them feeds an aligned
    //     value (reset vector, +4, or a redirect target the branch unit has
    //     already alignment-checked).
    property p_alignment;
        @(posedge clk) disable iff (!rst_n)
            (redirect_pc[1:0] == 2'b00 && commit_pc[1:0] == 2'b00)
            |=> ((pc[1:0] == 2'b00) && (fetch_pc[1:0] == 2'b00));
    endproperty
    a_aligned: assert property (p_alignment)
        else $error("[SVA-FAIL] a pointer went misaligned from aligned sources");
endinterface


module tb_top;
    bit clk = 0;
    bit rst_n;
    always #5 clk = ~clk;

    localparam bit [31:0] RESET_VECTOR = 32'h1000_0000;

    pc_gen_if vif(clk, rst_n);

    garuda_pc_gen dut (
        .clk_i         (clk),
        .rst_n_i       (rst_n),
        .redirect_i    (vif.redirect),
        .redirect_pc_i (vif.redirect_pc),
        .fetch_issue_i (vif.fetch_issue),
        .commit_i      (vif.commit),
        .commit_pc_i   (vif.commit_pc),
        .pc_o          (vif.pc),
        .fetch_pc_o    (vif.fetch_pc)
    );

    garuda_tb_pkg::scoreboard sb;

    // ---------------------------------------------------------
    // Coverage -- the redirect-priority combinations named in COVERAGE.md
    // ---------------------------------------------------------
    covergroup cg_pc @(posedge clk);
        cp_priority: coverpoint {vif.redirect, vif.commit, vif.fetch_issue} {
            bins idle              = {3'b000};
            bins issue_only        = {3'b001};
            bins commit_only       = {3'b010};
            bins commit_and_issue  = {3'b011};
            bins redirect_alone    = {3'b100};
            bins redirect_vs_issue = {3'b101};
            bins redirect_vs_commit= {3'b110};
            bins redirect_vs_both  = {3'b111};
        }
        // fetch_pc runs ahead of pc by up to the buffer depth (Sec. 6.2);
        // the lead distance is the interesting state here.
        cp_lead: coverpoint (vif.fetch_pc - vif.pc) {
            bins behind_or_equal = {32'h0000_0000};
            bins one_ahead   = {32'h0000_0004};
            bins two_ahead   = {32'h0000_0008};
            bins three_ahead = {32'h0000_000C};
            bins four_ahead  = {32'h0000_0010};   // full depth-4 lead
            bins other       = default;
        }
    endgroup
    cg_pc cg;

    // ---------------------------------------------------------
    // Stimulus
    // ---------------------------------------------------------
    task automatic step(bit rdir, bit [31:0] rpc, bit fiss, bit cmt, bit [31:0] cpc);
        @(negedge clk);
        vif.redirect    <= rdir;
        vif.redirect_pc <= rpc;
        vif.fetch_issue <= fiss;
        vif.commit      <= cmt;
        vif.commit_pc   <= cpc;
        @(posedge clk);
        #1;
    endtask

    task automatic idle();
        step(1'b0, 32'd0, 1'b0, 1'b0, 32'd0);
    endtask

    initial begin
        sb = new("PC_GEN");
        cg = new();

        rst_n = 0;
        vif.redirect = 0; vif.redirect_pc = 0;
        vif.fetch_issue = 0; vif.commit = 0; vif.commit_pc = 0;

        // ---- reset vector (Sec. 2.1 / 17, test C28) --------------------
        #3;
        sb.chk("reset", "pc = boot ROM",       vif.pc,       RESET_VECTOR);
        sb.chk("reset", "fetch_pc = boot ROM", vif.fetch_pc, RESET_VECTOR);
        @(negedge clk); rst_n = 1;

        // ---- idle: nothing moves ---------------------------------------
        idle();
        sb.chk("idle", "pc held",       vif.pc,       RESET_VECTOR);
        sb.chk("idle", "fetch_pc held", vif.fetch_pc, RESET_VECTOR);

        // ---- fetch_issue advances fetch_pc only ------------------------
        step(0, 32'd0, 1, 0, 32'd0);
        sb.chk("issue", "fetch_pc +4",   vif.fetch_pc, RESET_VECTOR + 32'd4);
        sb.chk("issue", "pc unchanged",  vif.pc,       RESET_VECTOR);
        repeat (3) step(0, 32'd0, 1, 0, 32'd0);
        // four accepted fetches with no pop: fetch_pc leads pc by the buffer
        // depth (Sec. 6.2 "runs ahead of pc by up to the buffer depth")
        sb.chk("issue", "fetch_pc leads by depth 4", vif.fetch_pc, RESET_VECTOR + 32'd16);
        sb.chk("issue", "pc still at reset vector",  vif.pc,       RESET_VECTOR);

        // ---- commit advances pc to commit_pc + 4 -----------------------
        step(0, 32'd0, 0, 1, RESET_VECTOR);
        sb.chk("commit", "pc = tag+4",       vif.pc,       RESET_VECTOR + 32'd4);
        sb.chk("commit", "fetch_pc held",    vif.fetch_pc, RESET_VECTOR + 32'd16);
        // THE discriminating vector: a non-contiguous tag. A "pc <= pc + 4"
        // implementation gives 0x1000_0008 here instead of 0x2000_0044.
        step(0, 32'd0, 0, 1, 32'h2000_0040);
        sb.chk("commit", "pc follows the popped tag, not itself",
               vif.pc, 32'h2000_0044);

        // ---- both advance independently in the same cycle --------------
        step(0, 32'd0, 1, 1, 32'h2000_0044);
        sb.chk("both", "pc",       vif.pc,       32'h2000_0048);
        sb.chk("both", "fetch_pc", vif.fetch_pc, RESET_VECTOR + 32'd20);

        // ---- redirect reloads BOTH pointers (Sec. 6.2 / 6.5) -----------
        step(1, 32'h3000_0100, 0, 0, 32'd0);
        sb.chk("redirect", "pc",       vif.pc,       32'h3000_0100);
        sb.chk("redirect", "fetch_pc", vif.fetch_pc, 32'h3000_0100);

        // ---- redirect priority (the COVERAGE.md Category C gap) --------
        step(1, 32'h4000_0200, 0, 1, 32'h1111_1110);   // vs commit
        sb.chk("prio_vs_commit", "pc",       vif.pc,       32'h4000_0200);
        sb.chk("prio_vs_commit", "fetch_pc", vif.fetch_pc, 32'h4000_0200);

        step(1, 32'h4000_0300, 1, 0, 32'd0);           // vs fetch_issue
        sb.chk("prio_vs_issue", "pc",       vif.pc,       32'h4000_0300);
        sb.chk("prio_vs_issue", "fetch_pc", vif.fetch_pc, 32'h4000_0300);

        step(1, 32'h4000_0400, 1, 1, 32'h1111_1110);   // vs both at once
        sb.chk("prio_vs_both", "pc",       vif.pc,       32'h4000_0400);
        sb.chk("prio_vs_both", "fetch_pc", vif.fetch_pc, 32'h4000_0400);

        // back-to-back redirects: the second target wins, no stale value
        step(1, 32'h5000_0000, 0, 0, 32'd0);
        step(1, 32'h6000_0000, 0, 0, 32'd0);
        sb.chk("back_to_back", "pc",       vif.pc,       32'h6000_0000);
        sb.chk("back_to_back", "fetch_pc", vif.fetch_pc, 32'h6000_0000);

        // address 0 is not special-cased
        step(1, 32'h0000_0000, 0, 0, 32'd0);
        sb.chk("redirect_to_zero", "pc", vif.pc, 32'h0000_0000);
        step(0, 32'd0, 1, 0, 32'd0);
        sb.chk("post_redirect", "fetch resumes from the target",
               vif.fetch_pc, 32'h0000_0004);

        // ---- sustained stream: fetch_pc is a clean +4 sequence ---------
        step(1, RESET_VECTOR, 0, 0, 32'd0);
        for (int i = 1; i <= 8; i++) begin
            step(0, 32'd0, 1, 0, 32'd0);
            sb.chk("stream", $sformatf("fetch_pc after %0d issues", i),
                   vif.fetch_pc, RESET_VECTOR + (i * 4));
        end

        // ---- reset asserted mid-stream ---------------------------------
        rst_n = 0; #1;
        sb.chk("re_reset", "pc",       vif.pc,       RESET_VECTOR);
        sb.chk("re_reset", "fetch_pc", vif.fetch_pc, RESET_VECTOR);
        @(negedge clk); rst_n = 1;

        // ---- randomised soak: SVA is the checker -----------------------
        // Random mixes of redirect / commit / issue, including all eight
        // priority combinations, so the properties are exercised on
        // sequences the directed cases do not enumerate.
        begin
            bit [31:0] model_pc = RESET_VECTOR;
            bit [31:0] model_fetch = RESET_VECTOR;
            bit [31:0] tag = RESET_VECTOR;
            repeat (600) begin
                bit rdir = ($urandom_range(0, 99) < 15);
                bit fiss = ($urandom_range(0, 99) < 60);
                bit cmt  = ($urandom_range(0, 99) < 50);
                bit [31:0] rpc = $urandom() & 32'hFFFF_FFFC;
                tag = $urandom() & 32'hFFFF_FFFC;
                step(rdir, rpc, fiss, cmt, tag);
                // Mirror the spec's own update rules, so the soak is
                // self-checking rather than SVA-only.
                if (rdir) begin
                    model_pc    = rpc;
                    model_fetch = rpc;
                end else begin
                    if (cmt)  model_pc    = tag + 32'd4;
                    if (fiss) model_fetch = model_fetch + 32'd4;
                end
                sb.chk("soak", "pc",       vif.pc,       model_pc);
                sb.chk("soak", "fetch_pc", vif.fetch_pc, model_fetch);
            end
        end

        sb.summary(cg.get_coverage());
        $finish;
    end
endmodule
