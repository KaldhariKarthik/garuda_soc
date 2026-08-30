// =============================================================
// tb_dsu_saturation_unit.sv
//
//  BLOCK      : II -- DSU (Custom-0 MAC coprocessor)
//  RTL SOURCE : rtl/dsu/saturation_unit.v   (GARUDA_DSU_DesignSpec)
//  SCOPE      : DSU unit module
//
// Single-file SV verification environment for GARUDA saturation_unit.v
// (MACSAT: clamps the 48-bit accumulator to the signed int32 range,
// sign-extended back to 48 bits)
//
// Purely combinational -- independent randomized items. Note:
// sat_writeback is computed UNCONDITIONALLY (no sat_op gate on the
// value itself) -- only sat_writeback_en/sat_overflow are gated by
// sat_op. This TB checks that distinction explicitly (case
// dir_satop_low_no_writeback below).
// =============================================================

`timescale 1ns / 1ps

// -------------------------------------------------------------
// 0b. TEST CONTROL -- reproducibility, runtime knobs, log hygiene
//
// A 1500+ case constrained-random run has three practical problems
// that a 100%-coverage result does NOT reveal:
//   1. The seed is printed every run so it can be recorded for the
//      report; each run draws a fresh random seed by design.
//   2. Changing the iteration count should not need a recompile --
//      +NRAND=<n> overrides it (e.g. a long soak before sign-off).
//   3. Every case prints a [PASS]/[FAIL] line as it runs, so the
//      SUMMARY total can be cross-checked against the live log.
// -------------------------------------------------------------
real tb_cov_goal = 100.0;   // sign-off goal; relax with +COV_GOAL=<percent>

task automatic tb_control_init(inout int nrand, input string tb_name);
    int seed_arg;
    seed_arg = $urandom;
    void'($urandom(seed_arg));
    $display("[%0s] seed = %0d", tb_name, seed_arg);
    $display("[%0s] random_cases=%0d", tb_name, nrand);
endtask

// tb_signoff -- a run is only signed off if BOTH criteria hold. A green
// "ALL CHECKS PASSED" at 60% coverage means the stimulus never reached the
// logic, not that the logic is right, so coverage is part of the verdict
// rather than a number printed beside it. Goal defaults to 100% and can be
// relaxed for a smoke run with +COV_GOAL=<percent>.

task automatic tb_signoff(real cov, int fails);
    if (fails != 0)
        $display(" SIGN-OFF: FAIL          -- %0d check(s) failed (coverage %0.2f%%)", fails, cov);
    else if (cov < tb_cov_goal)
        $display(" SIGN-OFF: NOT SIGNED OFF -- checks passed, but coverage %0.2f%% < goal %0.2f%%",
                  cov, tb_cov_goal);
    else
        $display(" SIGN-OFF: PASS          -- 0 failures and coverage %0.2f%% >= goal %0.2f%%",
                  cov, tb_cov_goal);
endtask



// -------------------------------------------------------------
// 1. DUT: saturation_unit.v (pasted verbatim, self-contained file)
// -------------------------------------------------------------
module saturation_unit (
    input wire [47:0] cluster_out,
    input wire        sat_op,

    output wire [47:0] sat_writeback,
    output wire        sat_writeback_en,
    output wire        sat_overflow
);

    wire [16:0] upper    = cluster_out[47:31];
    wire        in_range = (upper == 17'h00000) | (upper == 17'h1FFFF);
    wire        is_neg   = cluster_out[47];

    wire [47:0] sat_pos = 48'sh0000_7FFFFFFF;
    wire [47:0] sat_neg = 48'shFFFF_80000000;

    reg [47:0] sat_result;
    always @(*) begin
        if      (in_range) sat_result = {{16{cluster_out[31]}}, cluster_out[31:0]};
        else if (is_neg)   sat_result = sat_neg;
        else               sat_result = sat_pos;
    end

    assign sat_writeback    = sat_result;
    assign sat_writeback_en = sat_op;
    assign sat_overflow     = sat_op & ~in_range;

endmodule


// -------------------------------------------------------------
// 2. INTERFACE (+ bound SVA)
// -------------------------------------------------------------
interface saturation_unit_if (input bit clk);
    logic [47:0] cluster_out;
    logic        sat_op;
    logic [47:0] sat_writeback;
    logic        sat_writeback_en, sat_overflow;

    property p_no_x_propagation;
        @(posedge clk) (!$isunknown({cluster_out, sat_op})) |-> (!$isunknown({sat_writeback, sat_writeback_en, sat_overflow}));
    endproperty
    a_no_x_propagation: assert property (p_no_x_propagation)
        else $error("[SVA-FAIL] X detected on saturation_unit outputs with fully-known inputs");

    // sat_writeback_en / sat_overflow must both be low when sat_op is low,
    // regardless of how out-of-range cluster_out is.
    property p_sat_op_gates_en_and_overflow;
        @(posedge clk) (!sat_op) |-> (!sat_writeback_en && !sat_overflow);
    endproperty
    a_sat_op_gates_en_and_overflow: assert property (p_sat_op_gates_en_and_overflow)
        else $error("[SVA-FAIL] sat_writeback_en or sat_overflow asserted with sat_op=0");
endinterface


// -------------------------------------------------------------
// 3. STIMULUS ITEM
// -------------------------------------------------------------
class sat_txn;
    rand bit [47:0] cluster_out;
    rand bit        sat_op;
    string tag;
    bit [47:0] sat_writeback_act, sat_writeback_exp;
    bit        sat_writeback_en_act, sat_writeback_en_exp;
    bit        sat_overflow_act, sat_overflow_exp;

    constraint c_upper_dist {
        cluster_out[47:31] dist { 17'h00000 := 30, 17'h1FFFF := 30, [17'h00001:17'h1FFFE] :/ 40 };
    }

    function new(string tag_ = "random"); tag = tag_; endfunction
    function string to_s();
        return $sformatf("cluster_out=%012h sat_op=%0b", cluster_out, sat_op);
    endfunction
endclass


// -------------------------------------------------------------
// 4. GOLDEN / REFERENCE MODEL
// -------------------------------------------------------------
function automatic void sat_golden(sat_txn t);
    bit [16:0] upper    = t.cluster_out[47:31];
    bit        in_range = (upper == 17'h00000) | (upper == 17'h1FFFF);
    bit        is_neg   = t.cluster_out[47];
    bit [47:0] sat_pos  = 48'sh0000_7FFFFFFF;
    bit [47:0] sat_neg  = 48'shFFFF_80000000;
    bit [47:0] result;

    if      (in_range) result = {{16{t.cluster_out[31]}}, t.cluster_out[31:0]};
    else if (is_neg)   result = sat_neg;
    else                result = sat_pos;

    t.sat_writeback_exp    = result;
    t.sat_writeback_en_exp = t.sat_op;
    t.sat_overflow_exp     = t.sat_op & ~in_range;
endfunction


// -------------------------------------------------------------
// 5. GENERATOR
// -------------------------------------------------------------
class sat_generator;
    sat_txn items[$];
    int num_random;

    function new(int num_random = 1500); this.num_random = num_random; endfunction

    function void build();
        sat_txn t;
        t = new("dir_in_range_pos");         t.cluster_out=48'h0000_0000_1234; t.sat_op=1; items.push_back(t);
        t = new("dir_in_range_neg");         t.cluster_out=48'hFFFF_FFFF_F000; t.sat_op=1; items.push_back(t);
        t = new("dir_overflow_pos");         t.cluster_out=48'h0001_0000_0000; t.sat_op=1; items.push_back(t);
        t = new("dir_overflow_neg");         t.cluster_out=48'hFFFE_0000_0000; t.sat_op=1; items.push_back(t);
        t = new("dir_boundary_maxpos");      t.cluster_out=48'h0000_7FFF_FFFF; t.sat_op=1; items.push_back(t); // exactly INT32_MAX
        t = new("dir_boundary_maxneg");      t.cluster_out=48'hFFFF_8000_0000; t.sat_op=1; items.push_back(t); // exactly INT32_MIN
        t = new("dir_satop_low_no_writeback"); t.cluster_out=48'h0001_0000_0000; t.sat_op=0; items.push_back(t); // en/overflow must be 0 despite out-of-range value

        // --- additional corner cases: exact +-1 of the in-range/out-of-range boundary ---
        t = new("dir_boundary_maxpos_plus1"); t.cluster_out=48'h0000_8000_0000; t.sat_op=1; items.push_back(t); // one past INT32_MAX -> clamp
        t = new("dir_boundary_maxneg_minus1"); t.cluster_out=48'hFFFF_7FFF_FFFF; t.sat_op=1; items.push_back(t); // one below INT32_MIN -> clamp
        t = new("dir_zero_in_range");         t.cluster_out=48'h0; t.sat_op=1; items.push_back(t);
        t = new("dir_all_ones_in_range");     t.cluster_out='1; t.sat_op=1; items.push_back(t); // -1, in range
        t = new("dir_upper_all_ones_but_neg_boundary"); t.cluster_out=48'hFFFF_FFFF_FFFF; t.sat_op=1; items.push_back(t);
        t = new("dir_max_positive_overflow"); t.cluster_out=48'h7FFF_FFFF_FFFF; t.sat_op=1; items.push_back(t); // max possible positive 48-bit value

        repeat (num_random) begin
            sat_txn r = new("random");
            assert (r.randomize()) else $error("[GEN] randomize() failed");
            items.push_back(r);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 6. DRIVER
// -------------------------------------------------------------
class sat_driver;
    virtual saturation_unit_if vif;
    function new(virtual saturation_unit_if vif); this.vif = vif; endfunction

    task apply(sat_txn t);
        @(negedge vif.clk);
        vif.cluster_out <= t.cluster_out; vif.sat_op <= t.sat_op;
    endtask
endclass


// -------------------------------------------------------------
// 7. MONITOR
// -------------------------------------------------------------
class sat_monitor;
    virtual saturation_unit_if vif;

    covergroup cg_sat;
        cp_sat_op: coverpoint vif.sat_op;
        cp_range: coverpoint (vif.cluster_out[47:31] == 17'h00000 ? 0 :
                               vif.cluster_out[47:31] == 17'h1FFFF ? 1 : 2) {
            bins in_range_pos = {0};
            bins in_range_neg = {1};
            bins out_of_range = {2};
        }
        cp_is_neg: coverpoint vif.cluster_out[47];
        cross cp_sat_op, cp_range;
    endgroup

    function new(virtual saturation_unit_if vif); this.vif = vif; cg_sat = new(); endfunction

    task sample_one(output bit [47:0] wb_, output bit en_, output bit ovf_);
        #1;
        wb_ = vif.sat_writeback; en_ = vif.sat_writeback_en; ovf_ = vif.sat_overflow;
        cg_sat.sample();
    endtask
endclass


// -------------------------------------------------------------
// 8. SCOREBOARD
// -------------------------------------------------------------
class sat_scoreboard;
    int pass_cnt = 0;
    int fail_cnt = 0;

    task check(sat_txn t, bit [47:0] wb_, bit en_, bit ovf_);
        bit ok;
        t.sat_writeback_act = wb_; t.sat_writeback_en_act = en_; t.sat_overflow_act = ovf_;
        sat_golden(t);
        ok = (t.sat_writeback_act===t.sat_writeback_exp) & (t.sat_writeback_en_act===t.sat_writeback_en_exp)
           & (t.sat_overflow_act===t.sat_overflow_exp);
        if (ok) begin
            pass_cnt++;
            $display("[PASS] %-26s %-0s -> wb=%012h en=%0b ovf=%0b", t.tag, t.to_s(), wb_, en_, ovf_);
        end else begin
            fail_cnt++;
            $display("[FAIL] %-26s %-0s -> got(wb=%012h en=%0b ovf=%0b) exp(wb=%012h en=%0b ovf=%0b)",
                      t.tag, t.to_s(), wb_, en_, ovf_, t.sat_writeback_exp, t.sat_writeback_en_exp, t.sat_overflow_exp);
        end
    endtask
endclass


// -------------------------------------------------------------
// 9. ENVIRONMENT
// -------------------------------------------------------------
class sat_env;
    virtual saturation_unit_if vif;
    sat_generator  gen;
    sat_driver     drv;
    sat_monitor    mon;
    sat_scoreboard sb;

    function new(virtual saturation_unit_if vif, int num_random = 1500);
        this.vif = vif;
        gen = new(num_random);
        drv = new(vif);
        mon = new(vif);
        sb  = new();
    endfunction

    task run();
        bit [47:0] wb_; bit en_, ovf_;
        gen.build();
        foreach (gen.items[i]) begin
            drv.apply(gen.items[i]);
            mon.sample_one(wb_, en_, ovf_);
            sb.check(gen.items[i], wb_, en_, ovf_);
        end

        $display("\n================ SATURATION_UNIT UNIT TB SUMMARY ================");
        $display(" TOTAL=%0d  PASS=%0d  FAIL=%0d", gen.items.size(), sb.pass_cnt, sb.fail_cnt);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", mon.cg_sat.get_coverage());
        if (sb.fail_cnt == 0) $display(" RESULT: ALL CHECKS PASSED");
        else                  $display(" RESULT: %0d CHECK(S) FAILED", sb.fail_cnt);
        tb_signoff(mon.cg_sat.get_coverage(), sb.fail_cnt);
        $display("=====================================================================\n");
    endtask
endclass


// -------------------------------------------------------------
// 10. TEST
// -------------------------------------------------------------
class sat_test;
    sat_env env;
    function new(virtual saturation_unit_if vif, int num_random = 1500);
        env = new(vif, num_random);
    endfunction
    task run(); env.run(); endtask
endclass


// -------------------------------------------------------------
// 11. TB TOP
// -------------------------------------------------------------

module tb_top;
    bit clk = 0;
    always #5 clk = ~clk;

    saturation_unit_if vif(clk);

    saturation_unit dut (
        .cluster_out(vif.cluster_out),
        .sat_op(vif.sat_op),
        .sat_writeback(vif.sat_writeback),
        .sat_writeback_en(vif.sat_writeback_en),
        .sat_overflow(vif.sat_overflow)
    );

    sat_test test;

    initial begin
        int tb_nrand = 1500;
        tb_control_init(tb_nrand, "tb_dsu_saturation_unit");
        vif.cluster_out = 0; vif.sat_op = 0;
        repeat (3) @(posedge clk);

        test = new(vif, tb_nrand);
        test.run();
        $finish;
    end

endmodule
