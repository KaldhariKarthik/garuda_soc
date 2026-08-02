// =============================================================
// tapeout_hazard_forward_unit.sv
// Tapeout-grade SV verification environment for GARUDA hazard_forward_unit.v
// (ID-stage load-use hazard detector, Sec. 11.1-11.2)
//
// hazard_forward_unit is PURELY COMBINATIONAL - there is no clk/rst port
// on the DUT at all, and no internal state to carry across sequences.
// The sequence-based generator / synchronous apply-sample-check loop
// structure below still applies (it costs nothing and keeps every file in
// this set structurally identical), but the "reset-isolate-each-sequence"
// step that a stateful DUT like dsu_stall.v needs is a documented no-op
// here - called out explicitly rather than silently included as
// boilerplate that would imply state that doesn't exist.
//
// Requires a simulator with full IEEE1800 support (covergroup, assert
// property). NOT Icarus Verilog.
// =============================================================

`timescale 1ns / 1ps

// -------------------------------------------------------------
// 0. DEFINES
// -------------------------------------------------------------
// hazard_forward_unit.v has no `include dependency and no macro usage -
// nothing to inline. Recorded explicitly so the absence reads as
// verified, not forgotten.

// -------------------------------------------------------------
// 1. DUT: hazard_forward_unit.v (pasted verbatim, self-contained file)
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
module hazard_forward_unit (
    input  wire [4:0] id_rs1_idx_i,
    input  wire [4:0] id_rs2_idx_i,

    input  wire        ex_mem_read_i,   // instruction currently in EX is a load
    input  wire [4:0] ex_rd_i,

    output wire         load_use_stall_o
);

    assign load_use_stall_o = ex_mem_read_i && (ex_rd_i != 5'd0) &&
                               ((ex_rd_i == id_rs1_idx_i) || (ex_rd_i == id_rs2_idx_i));

endmodule
`endif // GARUDA_REAL_RTL -- inlined DUT copy ends; verification env follows



// -------------------------------------------------------------
// 2. INTERFACE (+ bound SVA assertions)
// -------------------------------------------------------------
interface hazard_if (input bit clk);
    logic [4:0] rs1_idx;
    logic [4:0] rs2_idx;
    logic        ex_mem_read;
    logic [4:0] ex_rd;
    logic        load_use_stall;

    // A1: this is the module's entire reason for existing - a load whose
    //     destination collides with either ID-stage source register MUST
    //     stall, or the consumer reads stale data one cycle early.
    property p_hazard_rs1_forces_stall;
        @(posedge clk) (ex_mem_read && (ex_rd != 5'd0) && (ex_rd == rs1_idx)) |-> load_use_stall;
    endproperty
    a_hazard_rs1: assert property (p_hazard_rs1_forces_stall)
        else $error("[SVA-FAIL] rs1 collided with an in-flight load's rd (ex_rd=%0d) but load_use_stall_o stayed low", ex_rd);

    property p_hazard_rs2_forces_stall;
        @(posedge clk) (ex_mem_read && (ex_rd != 5'd0) && (ex_rd == rs2_idx)) |-> load_use_stall;
    endproperty
    a_hazard_rs2: assert property (p_hazard_rs2_forces_stall)
        else $error("[SVA-FAIL] rs2 collided with an in-flight load's rd (ex_rd=%0d) but load_use_stall_o stayed low", ex_rd);

    // A2: x0 is never a real dependency (RISC-V architectural zero
    //     register) - a "load and discard" idiom with rd=x0 must never
    //     stall the pipeline behind it.
    property p_x0_never_a_hazard_source;
        @(posedge clk) (ex_mem_read && (ex_rd == 5'd0)) |-> !load_use_stall;
    endproperty
    a_x0_excluded: assert property (p_x0_never_a_hazard_source)
        else $error("[SVA-FAIL] ex_rd==0 incorrectly triggered a load-use stall - x0 must be exempt");

    // A3: with no load in EX at all, nothing this unit sees can be a
    //     load-use hazard by definition.
    property p_no_load_no_stall;
        @(posedge clk) !ex_mem_read |-> !load_use_stall;
    endproperty
    a_no_load_no_stall: assert property (p_no_load_no_stall)
        else $error("[SVA-FAIL] load_use_stall_o asserted with ex_mem_read_i low - spurious bubble");

    // A4: closes the truth table - anything not covered by A1/A2 must not
    //     stall, or the unit over-triggers and silently costs throughput.
    property p_no_match_no_stall;
        @(posedge clk)
        (ex_mem_read && (ex_rd != 5'd0) && (ex_rd != rs1_idx) && (ex_rd != rs2_idx)) |-> !load_use_stall;
    endproperty
    a_no_match_no_stall: assert property (p_no_match_no_stall)
        else $error("[SVA-FAIL] load_use_stall_o asserted with no rs1/rs2 match against ex_rd");

    // A5: X-propagation - load_use_stall_o feeds the pipeline's own
    //     stall/hold mux directly; an X here silently propagates into
    //     "maybe-stall" behavior across the whole front end.
    property p_no_x_propagation;
        @(posedge clk) (!$isunknown({rs1_idx, rs2_idx, ex_mem_read, ex_rd})) |-> (!$isunknown(load_use_stall));
    endproperty
    a_no_x_propagation: assert property (p_no_x_propagation)
        else $error("[SVA-FAIL] X detected on load_use_stall_o with fully-known inputs");

endinterface


// -------------------------------------------------------------
// 3. PER-CYCLE STIMULUS ITEM -- rand + constraint => real CRV
// -------------------------------------------------------------
typedef enum {
    HK_NO_LOAD, HK_NO_MATCH, HK_RS1_ONLY, HK_RS2_ONLY, HK_BOTH, HK_X0_EXCLUDED, HK_RANDOM
} hazard_op_e;

class hazard_cycle;
    rand hazard_op_e op;
    rand bit [4:0]  rs1_idx;
    rand bit [4:0]  rs2_idx;
    rand bit         mem_read;
    rand bit [4:0]  ex_rd;

    constraint c_op_dist {
        op dist {
            HK_NO_LOAD :/ 10, HK_NO_MATCH :/ 10, HK_RS1_ONLY :/ 20, HK_RS2_ONLY :/ 15,
            HK_BOTH :/ 15, HK_X0_EXCLUDED :/ 10, HK_RANDOM :/ 20
        };
    }
    constraint c_ranges { rs1_idx inside {[0:31]}; rs2_idx inside {[0:31]}; ex_rd inside {[0:31]}; }

    constraint c_op_shape {
        (op == HK_NO_LOAD)     -> (mem_read == 1'b0);
        (op == HK_NO_MATCH)    -> (mem_read == 1'b1 && ex_rd != 0 && ex_rd != rs1_idx && ex_rd != rs2_idx);
        (op == HK_RS1_ONLY)    -> (mem_read == 1'b1 && ex_rd != 0 && ex_rd == rs1_idx && ex_rd != rs2_idx);
        (op == HK_RS2_ONLY)    -> (mem_read == 1'b1 && ex_rd != 0 && ex_rd == rs2_idx && ex_rd != rs1_idx);
        (op == HK_BOTH)        -> (mem_read == 1'b1 && ex_rd != 0 && ex_rd == rs1_idx && ex_rd == rs2_idx);
        (op == HK_X0_EXCLUDED) -> (mem_read == 1'b1 && ex_rd == 0);
        // HK_RANDOM: unconstrained beyond ranges - solver explores freely.
    }

    // Converts this item's fields into the exact DUT input vector -
    // trivial here since the raw signals ARE the architectural fields
    // (no instruction-encoding step, unlike e.g. dsu_stall's funct5/
    // funct3), but kept as an explicit function for structural parity
    // with every other file in this set.
    function void fields(output bit [4:0] o_rs1, output bit [4:0] o_rs2, output bit o_mem_read, output bit [4:0] o_ex_rd);
        o_rs1 = rs1_idx; o_rs2 = rs2_idx; o_mem_read = mem_read; o_ex_rd = ex_rd;
    endfunction
endclass


// -------------------------------------------------------------
// 4. GENERATOR -- directed sequences + exhaustive sweep + CRV.
//    hazard_forward_unit has no internal state, so "sequence" here is
//    purely an organizational grouping (each entry is a self-contained
//    single cycle) - unlike dsu_stall, no sequence depends on what came
//    before it.
// -------------------------------------------------------------
class hazard_generator;
    hazard_cycle seq_q[$][$];
    string       seq_name[$];
    int num_random_seqs;
    int random_seq_len;

    function new(int num_random_seqs = 10, int random_seq_len = 200);
        this.num_random_seqs = num_random_seqs;
        this.random_seq_len  = random_seq_len;
    endfunction

    function hazard_cycle mk(hazard_op_e op, bit [4:0] rs1 = 0, bit [4:0] rs2 = 0, bit mem_read = 0, bit [4:0] ex_rd = 0);
        hazard_cycle c = new();
        c.op = op; c.rs1_idx = rs1; c.rs2_idx = rs2; c.mem_read = mem_read; c.ex_rd = ex_rd;
        return c;
    endfunction

    function void add_seq(string name, hazard_cycle q[$]);
        seq_name.push_back(name);
        seq_q.push_back(q);
    endfunction

    function void build();
        // 1) Idle vector - nothing in EX to hazard against
        begin
            hazard_cycle q[$];
            q.push_back(mk(HK_NO_LOAD, 5'd0, 5'd0, 1'b0, 5'd0));
            add_seq("idle_no_load", q);
        end

        // 2) Single-match hazard matrix
        begin
            hazard_cycle q[$];
            q.push_back(mk(HK_RS1_ONLY, 5'd10, 5'd20, 1'b1, 5'd10));
            add_seq("hazard_rs1_only", q);
        end
        begin
            hazard_cycle q[$];
            q.push_back(mk(HK_RS2_ONLY, 5'd20, 5'd10, 1'b1, 5'd10));
            add_seq("hazard_rs2_only", q);
        end
        begin
            hazard_cycle q[$];
            q.push_back(mk(HK_BOTH, 5'd10, 5'd10, 1'b1, 5'd10));
            add_seq("hazard_both", q);
        end
        begin
            hazard_cycle q[$];
            q.push_back(mk(HK_NO_MATCH, 5'd20, 5'd21, 1'b1, 5'd10));
            add_seq("no_match", q);
        end

        // 3) x0 exclusion (architectural corner) - both with and without
        //    non-zero source registers
        begin
            hazard_cycle q[$];
            q.push_back(mk(HK_X0_EXCLUDED, 5'd0, 5'd0, 1'b1, 5'd0));
            add_seq("x0_excluded_zero_srcs", q);
        end
        begin
            hazard_cycle q[$];
            q.push_back(mk(HK_X0_EXCLUDED, 5'd5, 5'd7, 1'b1, 5'd0));
            add_seq("x0_excluded_nonzero_srcs", q);
        end

        // 4) No-load boundary - would hazard if mem_read were 1
        begin
            hazard_cycle q[$];
            q.push_back(mk(HK_NO_LOAD, 5'd15, 5'd15, 1'b0, 5'd15));
            add_seq("no_load_boundary", q);
        end

        // 5) Back-to-back repeated identical hazard (stress) - guards
        //    against any accidental latch inference, which would only
        //    show up as "stuck" behavior across repeated identical
        //    cycles, not a single-vector functional test.
        begin
            hazard_cycle q[$];
            repeat (10) q.push_back(mk(HK_RS1_ONLY, 5'd3, 5'd4, 1'b1, 5'd3));
            add_seq("stress_repeated_hazard", q);
        end

        // 6) Alternating hazard/no-hazard toggle (stress) - guards
        //    against any inferred state that would lag the purely
        //    combinational specification.
        begin
            hazard_cycle q[$];
            for (int i = 0; i < 8; i++) begin
                if (i % 2 == 0) q.push_back(mk(HK_RS1_ONLY, 5'd8, 5'd9, 1'b1, 5'd8));
                else            q.push_back(mk(HK_NO_MATCH, 5'd8, 5'd9, 1'b1, 5'd11));
            end
            add_seq("stress_alternating_toggle", q);
        end

        // 7) EXHAUSTIVE: every architectural register (0-31) as
        //    rs1==rs2==ex_rd simultaneously - deterministic full-address
        //    boundary coverage rather than hoping CRV happens to hit all 32.
        for (int r = 0; r < 32; r++) begin
            hazard_cycle q[$];
            hazard_op_e k = (r == 0) ? HK_X0_EXCLUDED : HK_BOTH;
            q.push_back(mk(k, r[4:0], r[4:0], 1'b1, r[4:0]));
            add_seq($sformatf("exh_reg_sweep_%0d", r), q);
        end

        // 8) CONSTRAINED-RANDOM sequences
        for (int s = 0; s < num_random_seqs; s++) begin
            hazard_cycle q[$];
            for (int c = 0; c < random_seq_len; c++) begin
                hazard_cycle t = new();
                assert (t.randomize()) else $error("[GEN] randomize() failed");
                q.push_back(t);
            end
            add_seq($sformatf("crv_seq_%0d", s), q);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 5. REFERENCE MODEL -- stateless (the DUT has no registers), but
//    deliberately NOT a transcription of the RTL's single AND/OR
//    expression. This model CLASSIFIES the situation into an independent
//    enum first (mirroring how the spec prose describes it: "none / rs1 /
//    rs2 / both") and only then derives the stall bit - two independently
//    derived descriptions of the same rule agreeing is a stronger
//    correctness signal than one checked against itself.
// -------------------------------------------------------------
typedef enum { HC_NONE, HC_RS1, HC_RS2, HC_BOTH } hazard_class_e;

class hazard_ref_model;
    static function hazard_class_e classify(bit [4:0] rs1, bit [4:0] rs2, bit [4:0] rd);
        bit hit1 = (rd == rs1);
        bit hit2 = (rd == rs2);
        if (hit1 && hit2) return HC_BOTH;
        if (hit1)         return HC_RS1;
        if (hit2)         return HC_RS2;
        return HC_NONE;
    endfunction

    // Returns predicted load_use_stall_o. Stateless, so there is no
    // register-ordering subtlety here (unlike dsu_stall's step()) - kept
    // as a "step" for structural parity with every other file in this set.
    function automatic bit step(bit [4:0] rs1, bit [4:0] rs2, bit mem_read, bit [4:0] ex_rd);
        hazard_class_e cls;
        if (!mem_read || (ex_rd == 5'd0)) return 1'b0;
        cls = classify(rs1, rs2, ex_rd);
        return (cls != HC_NONE);
    endfunction
endclass


// -------------------------------------------------------------
// 6. DRIVER
// -------------------------------------------------------------
class hazard_driver;
    virtual hazard_if vif;
    function new(virtual hazard_if vif); this.vif = vif; endfunction

    task apply_cycle(hazard_cycle c);
        bit [4:0] r1, r2, rd; bit mrd;
        c.fields(r1, r2, mrd, rd);
        @(negedge vif.clk);
        vif.rs1_idx     <= r1;
        vif.rs2_idx     <= r2;
        vif.ex_mem_read <= mrd;
        vif.ex_rd       <= rd;
    endtask
endclass


// -------------------------------------------------------------
// 7. MONITOR
// -------------------------------------------------------------
class hazard_monitor;
    virtual hazard_if vif;

    covergroup cg_hazard;
        cp_stall: coverpoint vif.load_use_stall;
        cp_mem_read: coverpoint vif.ex_mem_read;
        cp_ex_rd_zero: coverpoint (vif.ex_rd == 0);
        cp_rs1_full: coverpoint vif.rs1_idx { bins each_reg[] = {[0:31]}; }
        cp_rs2_full: coverpoint vif.rs2_idx { bins each_reg[] = {[0:31]}; }
        cp_ex_rd_full: coverpoint vif.ex_rd { bins each_reg[] = {[0:31]}; }
        cross cp_stall, cp_mem_read {
            // load_use_stall_o's own definition is
            // "ex_mem_read_i && (ex_rd_i != 0) && (...)" -- ex_mem_read_i
            // is the first AND term, so stall=1 while mem_read=0 is a
            // logical contradiction, not an untested corner: no stimulus
            // can ever produce it. Excluded explicitly rather than
            // silently capping this cross (and hence the whole
            // covergroup's default equally-weighted average) below
            // 100%, mirroring dsu_stall_tb.sv's own
            // busy_during_reset_unreachable pattern.
            ignore_bins stall_without_mem_read_unreachable =
                binsof(cp_stall) intersect {1} && binsof(cp_mem_read) intersect {0};
        }
    endgroup

    function new(virtual hazard_if vif);
        this.vif = vif;
        cg_hazard = new();
    endfunction

    task sample_one(output bit stall);
        #1; // allow combinational logic to settle after apply_cycle()'s NBA update
        stall = vif.load_use_stall;
        cg_hazard.sample();
    endtask
endclass


// -------------------------------------------------------------
// 8. SCOREBOARD
// -------------------------------------------------------------
class hazard_scoreboard;
    int pass_cnt = 0;
    int fail_cnt = 0;

    task check(string seq_name, int cycle_idx, hazard_cycle c, bit [4:0] r1, bit [4:0] r2, bit mrd, bit [4:0] rd,
               bit actual_stall, ref hazard_ref_model model);
        bit expected_stall;
        expected_stall = model.step(r1, r2, mrd, rd);

        if (actual_stall === expected_stall) begin
            pass_cnt++;
            $display("[PASS] seq=%-28s cyc=%0d op=%-14s rs1=%0d rs2=%0d mem_read=%0b ex_rd=%0d -> stall=%0b",
                      seq_name, cycle_idx, c.op.name(), r1, r2, mrd, rd, actual_stall);
        end else begin
            fail_cnt++;
            $display("[FAIL] seq=%-28s cyc=%0d op=%-14s rs1=%0d rs2=%0d mem_read=%0b ex_rd=%0d -> got=%0b exp=%0b",
                      seq_name, cycle_idx, c.op.name(), r1, r2, mrd, rd, actual_stall, expected_stall);
        end
    endtask
endclass


// -------------------------------------------------------------
// 9. ENVIRONMENT
// -------------------------------------------------------------
class hazard_env;
    virtual hazard_if vif;
    hazard_generator  gen;
    hazard_driver     drv;
    hazard_monitor    mon;
    hazard_scoreboard sb;

    function new(virtual hazard_if vif, int num_random_seqs = 10, int random_seq_len = 200);
        this.vif = vif;
        gen = new(num_random_seqs, random_seq_len);
        drv = new(vif);
        mon = new(vif);
        sb  = new();
    endfunction

    task run();
        hazard_ref_model model;
        int total_cycles = 0;

        gen.build();

        // NOTE: unlike dsu_stall.v, this DUT has no registers and no
        // clk/rst port at all - there is no state to leak across
        // sequences, so no isolating reset pulse is needed here. A fresh
        // reference-model object per sequence would be pure ceremony
        // (the model is stateless too); one shared instance for the
        // whole run is both correct and honest about the DUT's nature.
        model = new();

        foreach (gen.seq_q[s]) begin
            foreach (gen.seq_q[s][i]) begin
                hazard_cycle c = gen.seq_q[s][i];
                bit [4:0] r1, r2, rd; bit mrd; bit actual_stall;
                c.fields(r1, r2, mrd, rd);
                drv.apply_cycle(c);
                mon.sample_one(actual_stall);
                sb.check(gen.seq_name[s], i, c, r1, r2, mrd, rd, actual_stall, model);
                total_cycles++;
            end
        end

        $display("\n============ HAZARD_FORWARD_UNIT UNIT TB SUMMARY ============");
        $display(" SEQUENCES=%0d  TOTAL_CYCLES=%0d  PASS=%0d  FAIL=%0d", gen.seq_q.size(), total_cycles, sb.pass_cnt, sb.fail_cnt);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", mon.cg_hazard.get_coverage());
        if (sb.fail_cnt == 0)
            $display(" RESULT: ALL CHECKS PASSED");
        else
            $display(" RESULT: %0d CHECK(S) FAILED", sb.fail_cnt);
        $display("===============================================================\n");
    endtask
endclass


// -------------------------------------------------------------
// 10. TEST
// -------------------------------------------------------------
class hazard_test;
    hazard_env env;
    function new(virtual hazard_if vif, int num_random_seqs = 10, int random_seq_len = 200);
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

    hazard_if vif(clk);

    hazard_forward_unit dut (
        .id_rs1_idx_i     (vif.rs1_idx),
        .id_rs2_idx_i     (vif.rs2_idx),
        .ex_mem_read_i    (vif.ex_mem_read),
        .ex_rd_i          (vif.ex_rd),
        .load_use_stall_o (vif.load_use_stall)
    );

    hazard_test test;

    initial begin
        vif.rs1_idx = 5'd0; vif.rs2_idx = 5'd0; vif.ex_mem_read = 1'b0; vif.ex_rd = 5'd0;
        repeat (3) @(posedge clk);

        test = new(vif, 10, 200);
        test.run();
        $finish;
    end
endmodule
