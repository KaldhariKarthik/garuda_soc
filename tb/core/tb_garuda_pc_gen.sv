// =============================================================================
// tb_garuda_pc_gen.sv -- SystemVerilog unit TB for rtl/core/garuda_pc_gen.sv
//
// Spec: AERO-GARUDA-DS-001 Rev 1.1, Sec. 6.2 (fetch-address generation),
//       Sec. 2.1 / 17 (reset vector 0x1000_0000, Boot ROM), Sec. 6.5 (redirect).
// Plan: C28 ("Reset: PC = 0x1000_0000"), plus the fetch half of C14/C15.
//
// The block keeps one pointer, fetch_pc, which drives the I-port. A redirect
// reloads it and BEATS an accepted fetch presented on the same edge; the four
// combinations of the two inputs, plus back-to-back redirects, are the
// sequences below and the cp_priority bins.
//
// 2026-11-16 (zero-waiver F4): the block's "architectural pc" register, which
// nothing in the chip read, was removed with its commit inputs, and so were the
// checks of it here (the pc of the instruction entering ID is the prefetch
// buffer's tag, checked in tb_garuda_prefetch_buffer.sv).
//
// No inlined DUT snapshot -- see the note in tb_alu.sv.
// =============================================================================

`timescale 1ns/1ps

interface pc_gen_if (input bit clk, input bit rst_n);
    logic        redirect;
    logic [31:0] redirect_pc;
    logic        fetch_issue;
    logic [31:0] fetch_pc;

    localparam bit [31:0] RESET_VECTOR = 32'h1000_0000;

    // A1: a redirect reloads fetch_pc with the target and outranks an accepted
    //     fetch presented on the same edge (Sec. 6.2 / 6.5).
    property p_redirect_wins;
        @(posedge clk) disable iff (!rst_n)
            redirect |=> (fetch_pc == $past(redirect_pc));
    endproperty
    a_redirect_wins: assert property (p_redirect_wins)
        else $error("[SVA-FAIL] a redirect did not reload fetch_pc with the target");

    // A2: fetch_pc advances by exactly 4 per accepted address phase, and only then.
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

    // A3: fetch_pc stays 4-byte aligned from aligned sources -- GARUDA has no C
    //     extension (reset vector, +4, or a redirect target the branch unit has
    //     already alignment-checked).
    property p_alignment;
        @(posedge clk) disable iff (!rst_n)
            (redirect_pc[1:0] == 2'b00) |=> (fetch_pc[1:0] == 2'b00);
    endproperty
    a_aligned: assert property (p_alignment)
        else $error("[SVA-FAIL] fetch_pc went misaligned from an aligned source");
endinterface


module tb_top;
    bit clk = 0;
    // TB-32 (the TB-22 class): starts at 1 so the `rst_n = 0` at time 0 below is
    // a real falling edge. As a bare `bit` it was already 0, that assignment was
    // no event, and the reset-vector checks at 3 ns passed only on a simulator
    // that invents an edge on the DUT's 4-state reset at time 0.
    bit rst_n = 1;
    always #5 clk = ~clk;

    localparam bit [31:0] RESET_VECTOR = 32'h1000_0000;

    pc_gen_if vif(clk, rst_n);

    garuda_pc_gen dut (
        .gclk          (clk),
        .core_rst_n    (rst_n),
        .redirect_i    (vif.redirect),
        .redirect_pc_i (vif.redirect_pc),
        .fetch_issue_i (vif.fetch_issue),
        .fetch_pc_o    (vif.fetch_pc)
    );

    garuda_tb_pkg::scoreboard sb;

    // ---------------------------------------------------------
    // Coverage -- every redirect / fetch combination on one edge
    // ---------------------------------------------------------
    covergroup cg_pc @(posedge clk);
        cp_priority: coverpoint {vif.redirect, vif.fetch_issue} {
            bins idle              = {2'b00};
            bins issue_only        = {2'b01};
            bins redirect_alone    = {2'b10};
            bins redirect_vs_issue = {2'b11};
        }
    endgroup
    cg_pc cg;

    // ---------------------------------------------------------
    // Stimulus
    // ---------------------------------------------------------
    task automatic step(bit rdir, bit [31:0] rpc, bit fiss);
        @(negedge clk);
        vif.redirect    <= rdir;
        vif.redirect_pc <= rpc;
        vif.fetch_issue <= fiss;
        @(posedge clk);
        #1;
    endtask

    task automatic idle();
        step(1'b0, 32'd0, 1'b0);
    endtask

    initial begin
        sb = new("PC_GEN");
        cg = new();

        vif.redirect = 0; vif.redirect_pc = 0; vif.fetch_issue = 0;

        // ---- reset vector (Sec. 2.1 / 17, test C28) --------------------
        // TB-32: a falling edge at 1 ns, so the asynchronous reset is what sets
        // the vector checked at 3 ns (before the first clock edge).
        #1; rst_n = 0;
        #2;
        sb.chk("reset", "fetch_pc = boot ROM", vif.fetch_pc, RESET_VECTOR);
        @(negedge clk); rst_n = 1;

        // ---- idle: nothing moves ---------------------------------------
        idle();
        sb.chk("idle", "fetch_pc held", vif.fetch_pc, RESET_VECTOR);

        // ---- fetch_issue advances fetch_pc -----------------------------
        step(0, 32'd0, 1);
        sb.chk("issue", "fetch_pc +4", vif.fetch_pc, RESET_VECTOR + 32'd4);
        repeat (3) step(0, 32'd0, 1);
        sb.chk("issue", "fetch_pc after four", vif.fetch_pc, RESET_VECTOR + 32'd16);

        // ---- redirect reloads fetch_pc (Sec. 6.2 / 6.5) -----------------
        step(1, 32'h3000_0100, 0);
        sb.chk("redirect", "fetch_pc", vif.fetch_pc, 32'h3000_0100);

        // ---- redirect priority over an accepted fetch on the same edge --
        step(1, 32'h4000_0300, 1);
        sb.chk("prio_vs_issue", "fetch_pc", vif.fetch_pc, 32'h4000_0300);

        // back-to-back redirects: the second target wins, no stale value
        step(1, 32'h5000_0000, 0);
        step(1, 32'h6000_0000, 0);
        sb.chk("back_to_back", "fetch_pc", vif.fetch_pc, 32'h6000_0000);

        // 1-TOPS G4 row 4.1: a halfword-aligned redirect target. pc_gen loads
        // it as given (the misaligned-target trap is raised in EX, CORE T-1);
        // then back to an aligned target, so bit 1 toggles both ways.
        step(1, 32'h6000_0402, 0);
        sb.chk("redirect_halfword", "fetch_pc", vif.fetch_pc, 32'h6000_0402);
        step(1, 32'h6000_0400, 0);
        sb.chk("redirect_realign", "fetch_pc", vif.fetch_pc, 32'h6000_0400);

        // address 0 is not special-cased
        step(1, 32'h0000_0000, 0);
        sb.chk("redirect_to_zero", "fetch_pc", vif.fetch_pc, 32'h0000_0000);
        step(0, 32'd0, 1);
        sb.chk("post_redirect", "fetch resumes from the target",
               vif.fetch_pc, 32'h0000_0004);

        // ---- sustained stream: fetch_pc is a clean +4 sequence ---------
        step(1, RESET_VECTOR, 0);
        for (int i = 1; i <= 8; i++) begin
            step(0, 32'd0, 1);
            sb.chk("stream", $sformatf("fetch_pc after %0d issues", i),
                   vif.fetch_pc, RESET_VECTOR + (i * 4));
        end

        // ---- reset asserted mid-stream ---------------------------------
        // inputs are dropped with the reset: the stream above leaves
        // fetch_issue high, and the soak model below starts from the reset
        // vector, so one stray issue after release put it 4 behind for good
        rst_n = 0; vif.redirect = 0; vif.fetch_issue = 0; #1;
        sb.chk("re_reset", "fetch_pc", vif.fetch_pc, RESET_VECTOR);
        // TB-39: hold the reset across a clock edge. A sub-cycle pulse relies on
        // `disable iff` cancelling the a_fetch_step attempt started at the last
        // edge asynchronously (IEEE 1800 16.12); Verilator 5.052 samples it at
        // the clock only, so that attempt survived and failed at the next edge.
        @(negedge clk); @(negedge clk); rst_n = 1;

        // ---- randomised soak: a model of the update rule checks every step --
        begin
            bit [31:0] model_fetch = RESET_VECTOR;
            repeat (600) begin
                automatic bit rdir = ($urandom_range(0, 99) < 15);
                automatic bit fiss = ($urandom_range(0, 99) < 60);
                automatic bit [31:0] rpc = $urandom() & 32'hFFFF_FFFC;
                step(rdir, rpc, fiss);
                if (rdir) begin
                    model_fetch = rpc;
                end else if (fiss) begin
                    model_fetch = model_fetch + 32'd4;
                end
                sb.chk("soak", "fetch_pc", vif.fetch_pc, model_fetch);
            end
        end

        sb.summary(cg.get_coverage());
        $finish;
    end
endmodule
