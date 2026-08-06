// =============================================================
// tapeout_branch_predict.sv
// Tapeout-grade SV verification environment for GARUDA branch_predict.v
// (ID-stage static branch prediction / JAL redirect, Sec. 12.1-12.2)
//
// branch_predict is PURELY COMBINATIONAL - no clk/rst port, no internal
// state to carry across sequences. The sequence-based generator /
// synchronous apply-sample-check loop below still applies for structural
// consistency with the rest of this test set; the reset-isolation step a
// stateful DUT needs is a documented no-op here.
//
// Requires a simulator with full IEEE1800 support (covergroup, assert
// property). NOT Icarus Verilog.
// =============================================================

`timescale 1ns / 1ps

// -------------------------------------------------------------
// 0. DEFINES
// -------------------------------------------------------------
// branch_predict.v has no `include dependency and no macro usage -
// nothing to inline.

// -------------------------------------------------------------
// 1. DUT: branch_predict.v (pasted verbatim, self-contained file)
// -------------------------------------------------------------
`ifndef GARUDA_REAL_RTL
// -----------------------------------------------------------------------------
// INLINED DUT COPY -- guarded (added 2026-08-02).
//
// This file carries its own copy of the DUT so it can be compiled standalone
// under VCS. That copy is a SNAPSHOT and had already drifted from rtl/core/*.v
// (it predates the SLLI/SRLI/SRAI funct7 check and the FENCE decode), so a
// green run against it proves nothing about the RTL that actually ships.
//
// Defining GARUDA_REAL_RTL skips this copy so the testbench binds to the real
// rtl/core sources -- that is what tb/core/filelist_*.f does. Compiling this
// file standalone with no define behaves exactly as before.
// -----------------------------------------------------------------------------
module branch_predict (
    input  wire [31:0] pc_i,
    input  wire [31:0] imm_b_i,
    input  wire [31:0] imm_j_i,
    input  wire         branch_i,   // ctrl.branch from Decode/Control
    input  wire         jal_i,      // ctrl.jal from Decode/Control

    output wire         predict_taken_o,
    output wire         id_redirect_valid_o,
    output wire [31:0] id_redirect_target_o
);

    wire [31:0] branch_target;
    wire [31:0] jal_target;

    assign branch_target = pc_i + imm_b_i;
    assign jal_target    = pc_i + imm_j_i;

    assign predict_taken_o = branch_i & imm_b_i[31];

    assign id_redirect_valid_o  = jal_i | predict_taken_o;
    assign id_redirect_target_o = jal_i ? jal_target : branch_target;

endmodule
`endif // GARUDA_REAL_RTL -- inlined DUT copy ends; verification env follows



// -------------------------------------------------------------
// 2. INTERFACE (+ bound SVA assertions)
// -------------------------------------------------------------
interface branch_if (input bit clk);
    logic [31:0] pc;
    logic [31:0] imm_b;
    logic [31:0] imm_j;
    logic         branch;
    logic         jal;
    logic         predict_taken;
    logic         redirect_valid;
    logic [31:0] redirect_target;

    // A1: JAL is architecturally unconditional (Sec. 12.2) - if it ever
    //     failed to redirect, every jump in the program would silently
    //     fall through to sequential execution.
    property p_jal_always_redirects;
        @(posedge clk) jal |-> redirect_valid;
    endproperty
    a_jal_redirects: assert property (p_jal_always_redirects)
        else $error("[SVA-FAIL] jal_i asserted but id_redirect_valid_o stayed low");

    // A2: JAL's target must win the mux even if a taken branch fires the
    //     same cycle - the safe/defined priority per the RTL's own mux.
    property p_jal_target_priority;
        @(posedge clk) jal |-> (redirect_target == (pc + imm_j));
    endproperty
    a_jal_target_priority: assert property (p_jal_target_priority)
        else $error("[SVA-FAIL] id_redirect_target_o did not follow pc+imm_j while jal_i was asserted");

    // A3: a backward branch (negative displacement) is statically
    //     predicted taken (Sec. 12.1) so a tight loop doesn't pay a
    //     bubble every iteration.
    property p_backward_branch_taken;
        @(posedge clk)
        (branch && imm_b[31] && !jal) |-> (predict_taken && redirect_valid && (redirect_target == (pc + imm_b)));
    endproperty
    a_backward_taken: assert property (p_backward_branch_taken)
        else $error("[SVA-FAIL] backward branch (imm_b[31]=1) failed to predict taken and redirect");

    // A4: the flip side - a forward branch must not speculatively
    //     redirect fetch, or every if-statement pays a needless flush.
    property p_forward_branch_not_taken;
        @(posedge clk) (branch && !imm_b[31]) |-> !predict_taken;
    endproperty
    a_forward_not_taken: assert property (p_forward_branch_not_taken)
        else $error("[SVA-FAIL] forward branch incorrectly predicted taken");

    // A5: illegal-state check - with neither a branch nor a jump decoded,
    //     nothing can legitimately ask fetch to redirect.
    property p_no_op_no_redirect;
        @(posedge clk) (!branch && !jal) |-> !redirect_valid;
    endproperty
    a_no_op_no_redirect: assert property (p_no_op_no_redirect)
        else $error("[SVA-FAIL] redirect asserted with neither branch_i nor jal_i");

    // A6: predict_taken_o must never be derivable from jal_i by mistake -
    //     it is only meaningful in the context of a branch.
    property p_predict_taken_requires_branch;
        @(posedge clk) predict_taken |-> branch;
    endproperty
    a_predict_requires_branch: assert property (p_predict_taken_requires_branch)
        else $error("[SVA-FAIL] predict_taken_o asserted without branch_i");

    // A7: X-propagation - a redirect target feeds the PC mux directly; an
    //     unknown bit there corrupts instruction fetch program-wide.
    property p_no_x_propagation;
        @(posedge clk)
        (!$isunknown({pc, imm_b, imm_j, branch, jal})) |->
        (!$isunknown({predict_taken, redirect_valid, redirect_target}));
    endproperty
    a_no_x_propagation: assert property (p_no_x_propagation)
        else $error("[SVA-FAIL] an output went unknown while every input was known");

endinterface


// -------------------------------------------------------------
// 3. PER-CYCLE STIMULUS ITEM -- rand + constraint => real CRV
// -------------------------------------------------------------
typedef enum {
    BK_IDLE, BK_BACKWARD_BRANCH, BK_FORWARD_BRANCH, BK_JAL, BK_JAL_AND_BRANCH, BK_WRAPAROUND, BK_RANDOM
} branch_op_e;

class branch_cycle;
    rand branch_op_e op;
    rand bit [31:0] pc_val;
    rand bit [31:0] imm_b_val;
    rand bit [31:0] imm_j_val;
    rand bit         branch_val;
    rand bit         jal_val;

    constraint c_alignment { pc_val[1:0] == 2'b00; imm_b_val[0] == 1'b0; imm_j_val[0] == 1'b0; }

    constraint c_op_dist {
        op dist {
            BK_IDLE :/ 10, BK_BACKWARD_BRANCH :/ 20, BK_FORWARD_BRANCH :/ 20,
            BK_JAL :/ 15, BK_JAL_AND_BRANCH :/ 10, BK_WRAPAROUND :/ 5, BK_RANDOM :/ 20
        };
    }

    constraint c_op_shape {
        (op == BK_IDLE)            -> (branch_val == 0 && jal_val == 0);
        (op == BK_BACKWARD_BRANCH) -> (branch_val == 1 && jal_val == 0 && imm_b_val[31] == 1);
        (op == BK_FORWARD_BRANCH)  -> (branch_val == 1 && jal_val == 0 && imm_b_val[31] == 0);
        (op == BK_JAL)             -> (branch_val == 0 && jal_val == 1);
        (op == BK_JAL_AND_BRANCH)  -> (branch_val == 1 && jal_val == 1);
        // BK_WRAPAROUND / BK_RANDOM: unconstrained beyond alignment.
    }

    // Trivial pass-through - branch_predict has no instruction-encoding
    // step, kept for structural parity with the rest of this test set.
    function void fields(output bit [31:0] o_pc, output bit [31:0] o_imm_b, output bit [31:0] o_imm_j,
                         output bit o_branch, output bit o_jal);
        o_pc = pc_val; o_imm_b = imm_b_val; o_imm_j = imm_j_val; o_branch = branch_val; o_jal = jal_val;
    endfunction
endclass


// -------------------------------------------------------------
// 4. GENERATOR -- directed sequences + CRV.
// -------------------------------------------------------------
class branch_generator;
    branch_cycle seq_q[$][$];
    string        seq_name[$];
    int num_random_seqs;
    int random_seq_len;

    function new(int num_random_seqs = 10, int random_seq_len = 200);
        this.num_random_seqs = num_random_seqs;
        this.random_seq_len  = random_seq_len;
    endfunction

    function branch_cycle mk(branch_op_e op, bit [31:0] pc_v, bit [31:0] ib, bit [31:0] ij, bit br, bit jl);
        branch_cycle c = new();
        c.op = op; c.pc_val = pc_v; c.imm_b_val = ib; c.imm_j_val = ij; c.branch_val = br; c.jal_val = jl;
        return c;
    endfunction

    function void add_seq(string name, branch_cycle q[$]);
        seq_name.push_back(name);
        seq_q.push_back(q);
    endfunction

    function void build();
        // 1) Idle vector
        begin
            branch_cycle q[$];
            q.push_back(mk(BK_IDLE, 32'h0000_0000, 32'h0, 32'h0, 1'b0, 1'b0));
            add_seq("idle_no_branch_no_jal", q);
        end

        // 2) Backward branch predict-taken (typical offset + max offset)
        begin
            branch_cycle q[$];
            q.push_back(mk(BK_BACKWARD_BRANCH, 32'h0000_0100, -32'sd8, 32'h0, 1'b1, 1'b0));
            add_seq("backward_branch_typical", q);
        end
        begin
            branch_cycle q[$];
            q.push_back(mk(BK_BACKWARD_BRANCH, 32'h0000_1000, -32'sd4096, 32'h0, 1'b1, 1'b0));
            add_seq("backward_branch_max_offset", q);
        end

        // 3) Forward branch predict-not-taken (typical offset + max offset)
        begin
            branch_cycle q[$];
            q.push_back(mk(BK_FORWARD_BRANCH, 32'h0000_0100, 32'sd16, 32'h0, 1'b1, 1'b0));
            add_seq("forward_branch_typical", q);
        end
        begin
            branch_cycle q[$];
            q.push_back(mk(BK_FORWARD_BRANCH, 32'h0000_0100, 32'sd4094, 32'h0, 1'b1, 1'b0));
            add_seq("forward_branch_max_offset", q);
        end

        // 4) JAL unconditional redirect - positive, negative, zero offset
        begin
            branch_cycle q[$];
            q.push_back(mk(BK_JAL, 32'h0000_0200, 32'h0, 32'sd1024, 1'b0, 1'b1));
            add_seq("jal_positive_offset", q);
        end
        begin
            branch_cycle q[$];
            q.push_back(mk(BK_JAL, 32'h0000_0200, 32'h0, -32'sd1024, 1'b0, 1'b1));
            add_seq("jal_negative_offset", q);
        end
        begin
            branch_cycle q[$];
            q.push_back(mk(BK_JAL, 32'h0000_0200, 32'h0, 32'sd0, 1'b0, 1'b1));
            add_seq("jal_zero_offset_self_jump", q);
        end

        // 5) JAL+branch simultaneous - target-mux priority corner
        begin
            branch_cycle q[$];
            q.push_back(mk(BK_JAL_AND_BRANCH, 32'h0000_0300, -32'sd8, 32'sd2048, 1'b1, 1'b1));
            add_seq("jal_and_backward_branch", q);
        end
        begin
            branch_cycle q[$];
            q.push_back(mk(BK_JAL_AND_BRANCH, 32'h0000_0300, 32'sd8, 32'sd2048, 1'b1, 1'b1));
            add_seq("jal_and_forward_branch", q);
        end

        // 6) Architectural corner: 32-bit address wraparound
        begin
            branch_cycle q[$];
            q.push_back(mk(BK_WRAPAROUND, 32'hFFFF_FFFC, 32'sd8, 32'h0, 1'b1, 1'b0));
            add_seq("branch_target_wraparound", q);
        end
        begin
            branch_cycle q[$];
            q.push_back(mk(BK_WRAPAROUND, 32'hFFFF_FFFC, 32'h0, 32'sd8, 1'b0, 1'b1));
            add_seq("jal_target_wraparound", q);
        end
        begin
            branch_cycle q[$];
            q.push_back(mk(BK_WRAPAROUND, 32'h0000_0000, -32'sd4, 32'h0, 1'b1, 1'b0));
            add_seq("branch_target_underflow", q);
        end

        // 7) Immediate boundary sweep (all-ones patterns)
        begin
            branch_cycle q[$];
            q.push_back(mk(BK_RANDOM, 32'h0, 32'hFFFF_FFFE, 32'h0, 1'b1, 1'b0));
            q.push_back(mk(BK_RANDOM, 32'h0, 32'h0, 32'hFFFF_FFFE, 1'b0, 1'b1));
            add_seq("immediate_all_ones_boundary", q);
        end

        // 8) Back-to-back repeated redirects (stress)
        begin
            branch_cycle q[$];
            repeat (10) q.push_back(mk(BK_JAL, 32'h0000_0400, 32'h0, 32'sd4, 1'b0, 1'b1));
            add_seq("stress_repeated_jal", q);
        end

        // 9) Alternating taken/not-taken (stress)
        begin
            branch_cycle q[$];
            for (int i = 0; i < 8; i++) begin
                if (i % 2 == 0) q.push_back(mk(BK_BACKWARD_BRANCH, 32'h0000_0500, -32'sd16, 32'h0, 1'b1, 1'b0));
                else            q.push_back(mk(BK_FORWARD_BRANCH,  32'h0000_0500,  32'sd16, 32'h0, 1'b1, 1'b0));
            end
            add_seq("stress_alternating_taken_not_taken", q);
        end

        // 10) CONSTRAINED-RANDOM sequences
        for (int s = 0; s < num_random_seqs; s++) begin
            branch_cycle q[$];
            for (int c = 0; c < random_seq_len; c++) begin
                branch_cycle t = new();
                assert (t.randomize()) else $error("[GEN] randomize() failed");
                q.push_back(t);
            end
            add_seq($sformatf("crv_seq_%0d", s), q);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 5. REFERENCE MODEL -- stateless, classify-then-compute (rather than the
//    RTL's simultaneous dual-adder-plus-ternary): names the same three
//    outcomes the spec describes in prose (a jump, a predicted-taken
//    branch, or neither) before touching any arithmetic.
// -------------------------------------------------------------
typedef enum { RK_NONE, RK_PREDICT_TAKEN_BRANCH, RK_JAL } redirect_kind_e;

class branch_ref_model;
    static function redirect_kind_e classify(bit branch_v, bit jal_v, bit imm_b_sign);
        if (jal_v) return RK_JAL;
        if (branch_v && imm_b_sign) return RK_PREDICT_TAKEN_BRANCH;
        return RK_NONE;
    endfunction

    // Returns {predict_taken, redirect_valid, redirect_target} for this
    // cycle's inputs. Stateless (no register-ordering subtlety) - kept as
    // a "step" for structural parity with the rest of this test set.
    function automatic void step(bit [31:0] pc, bit [31:0] imm_b, bit [31:0] imm_j, bit branch_v, bit jal_v,
                                  output bit predict_taken, output bit redirect_valid, output bit [31:0] target);
        redirect_kind_e k = classify(branch_v, jal_v, imm_b[31]);
        predict_taken  = branch_v & imm_b[31];
        redirect_valid = (k != RK_NONE);
        // The target adder always fires, even when nothing asks for a
        // redirect - the RTL drives SOME value on id_redirect_target_o
        // unconditionally, gated for meaning only by id_redirect_valid_o.
        target = jal_v ? (pc + imm_j) : (pc + imm_b);
    endfunction
endclass


// -------------------------------------------------------------
// 6. DRIVER
// -------------------------------------------------------------
class branch_driver;
    virtual branch_if vif;
    function new(virtual branch_if vif); this.vif = vif; endfunction

    task apply_cycle(branch_cycle c);
        bit [31:0] pc_v, ib, ij; bit br, jl;
        c.fields(pc_v, ib, ij, br, jl);
        @(negedge vif.clk);
        vif.pc     <= pc_v;
        vif.imm_b  <= ib;
        vif.imm_j  <= ij;
        vif.branch <= br;
        vif.jal    <= jl;
    endtask
endclass


// -------------------------------------------------------------
// 7. MONITOR
// -------------------------------------------------------------
class branch_result;
    bit predict_taken; bit redirect_valid; bit [31:0] redirect_target;
endclass

class branch_monitor;
    virtual branch_if vif;

    covergroup cg_branch;
        cp_branch: coverpoint vif.branch;
        cp_jal: coverpoint vif.jal;
        cp_imm_b_sign: coverpoint vif.imm_b[31] iff (vif.branch);
        cp_predict_taken: coverpoint vif.predict_taken;
        cp_redirect_valid: coverpoint vif.redirect_valid;
        cross cp_branch, cp_jal;
    endgroup

    function new(virtual branch_if vif);
        this.vif = vif;
        cg_branch = new();
    endfunction

    task sample_one(output branch_result r);
        #1; // allow combinational logic to settle after apply_cycle()'s NBA update
        r = new();
        r.predict_taken    = vif.predict_taken;
        r.redirect_valid   = vif.redirect_valid;
        r.redirect_target  = vif.redirect_target;
        cg_branch.sample();
    endtask
endclass


// -------------------------------------------------------------
// 8. SCOREBOARD
// -------------------------------------------------------------
class branch_scoreboard;
    int pass_cnt = 0;
    int fail_cnt = 0;

    task check(string seq_name, int cycle_idx, branch_cycle c, bit [31:0] pc_v, bit [31:0] ib, bit [31:0] ij,
               bit br, bit jl, branch_result actual, ref branch_ref_model model);
        bit exp_predict_taken, exp_redirect_valid; bit [31:0] exp_target;
        model.step(pc_v, ib, ij, br, jl, exp_predict_taken, exp_redirect_valid, exp_target);

        if ((actual.predict_taken === exp_predict_taken) &&
            (actual.redirect_valid === exp_redirect_valid) &&
            (actual.redirect_target === exp_target)) begin
            pass_cnt++;
            $display("[PASS] seq=%-30s cyc=%0d op=%-18s pc=0x%08h branch=%0b jal=%0b -> taken=%0b valid=%0b tgt=0x%08h",
                      seq_name, cycle_idx, c.op.name(), pc_v, br, jl, actual.predict_taken, actual.redirect_valid, actual.redirect_target);
        end else begin
            fail_cnt++;
            $display("[FAIL] seq=%-30s cyc=%0d op=%-18s pc=0x%08h imm_b=0x%08h imm_j=0x%08h branch=%0b jal=%0b",
                      seq_name, cycle_idx, c.op.name(), pc_v, ib, ij, br, jl);
            $display("       predict_taken:  exp=%0b act=%0b", exp_predict_taken, actual.predict_taken);
            $display("       redirect_valid: exp=%0b act=%0b", exp_redirect_valid, actual.redirect_valid);
            $display("       redirect_target: exp=0x%08h act=0x%08h", exp_target, actual.redirect_target);
        end
    endtask
endclass


// -------------------------------------------------------------
// 9. ENVIRONMENT
// -------------------------------------------------------------
class branch_env;
    virtual branch_if vif;
    branch_generator  gen;
    branch_driver     drv;
    branch_monitor    mon;
    branch_scoreboard sb;

    function new(virtual branch_if vif, int num_random_seqs = 10, int random_seq_len = 200);
        this.vif = vif;
        gen = new(num_random_seqs, random_seq_len);
        drv = new(vif);
        mon = new(vif);
        sb  = new();
    endfunction

    task run();
        branch_ref_model model;
        int total_cycles = 0;

        gen.build();

        // NOTE: branch_predict.v has no registers and no clk/rst port -
        // there is no state to leak across sequences, so one shared
        // (stateless) reference-model instance for the whole run is
        // correct and honest about the DUT's nature.
        model = new();

        foreach (gen.seq_q[s]) begin
            foreach (gen.seq_q[s][i]) begin
                branch_cycle c = gen.seq_q[s][i];
                bit [31:0] pc_v, ib, ij; bit br, jl;
                branch_result actual;
                c.fields(pc_v, ib, ij, br, jl);
                drv.apply_cycle(c);
                mon.sample_one(actual);
                sb.check(gen.seq_name[s], i, c, pc_v, ib, ij, br, jl, actual, model);
                total_cycles++;
            end
        end

        $display("\n============ BRANCH_PREDICT UNIT TB SUMMARY ============");
        $display(" SEQUENCES=%0d  TOTAL_CYCLES=%0d  PASS=%0d  FAIL=%0d", gen.seq_q.size(), total_cycles, sb.pass_cnt, sb.fail_cnt);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", mon.cg_branch.get_coverage());
        if (sb.fail_cnt == 0)
            $display(" RESULT: ALL CHECKS PASSED");
        else
            $display(" RESULT: %0d CHECK(S) FAILED", sb.fail_cnt);
        $display("==========================================================\n");
    endtask
endclass


// -------------------------------------------------------------
// 10. TEST
// -------------------------------------------------------------
class branch_test;
    branch_env env;
    function new(virtual branch_if vif, int num_random_seqs = 10, int random_seq_len = 200);
        env = new(vif, num_random_seqs, random_seq_len);
    endfunction
    task run(); env.run(); endtask
endclass


// -------------------------------------------------------------
// 11. TB TOP
// -------------------------------------------------------------
module tb_top;
    bit clk = 0;
    always #5 clk = ~clk;

    branch_if vif(clk);

    branch_predict dut (
        .pc_i                 (vif.pc),
        .imm_b_i              (vif.imm_b),
        .imm_j_i              (vif.imm_j),
        .branch_i             (vif.branch),
        .jal_i                (vif.jal),
        // ERRATUM C-3 added fencei_i (FENCE.I redirects to pc+4 to flush the
        // prefetch buffer). Tied low: this TB predates it and drives no
        // FENCE.I. Left floating it reads as X and poisons id_redirect_valid_o.
        .fencei_i             (1'b0),
        .predict_taken_o      (vif.predict_taken),
        .id_redirect_valid_o  (vif.redirect_valid),
        .id_redirect_target_o (vif.redirect_target)
    );

    branch_test test;

    initial begin
        vif.pc = 32'h0; vif.imm_b = 32'h0; vif.imm_j = 32'h0; vif.branch = 1'b0; vif.jal = 1'b0;
        repeat (3) @(posedge clk);

        test = new(vif, 10, 200);
        test.run();
        $finish;
    end
endmodule
