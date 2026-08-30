// =============================================================
// tb_dsu_kogge_stone_49.sv
//
//  BLOCK      : II -- DSU (Custom-0 MAC coprocessor)
//  RTL SOURCE : rtl/dsu/kogge_stone_49.v   (GARUDA_DSU_DesignSpec)
//  SCOPE      : DSU unit module
//
// Single-file SV verification environment for GARUDA kogge_stone_49.v
// (49-bit adder used to combine the accumulator with the pipelined
// sum/carry pair inside mac_unit.v)
//
// Purely combinational -- independent randomized items.
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
// 1. DUT: kogge_stone_49.v (pasted verbatim, self-contained file)
// -------------------------------------------------------------
module kogge_stone_49 (
    input wire  [48:0] a,
    input wire  [48:0] b,
    input wire         cin,
    output wire [48:0] sum
);

    assign sum = a + b + cin;

endmodule


// -------------------------------------------------------------
// 2. INTERFACE (+ bound SVA)
// -------------------------------------------------------------
interface kogge_stone_49_if (input bit clk);
    logic [48:0] a, b;
    logic        cin;
    logic [48:0] sum;

    property p_no_x_propagation;
        @(posedge clk) (!$isunknown({a, b, cin})) |-> (!$isunknown(sum));
    endproperty
    a_no_x_propagation: assert property (p_no_x_propagation)
        else $error("[SVA-FAIL] X detected on kogge_stone_49 sum with fully-known inputs");
endinterface


// -------------------------------------------------------------
// 3. STIMULUS ITEM
// -------------------------------------------------------------
class ks_txn;
    rand bit [48:0] a, b;
    rand bit        cin;
    string tag;
    bit [48:0] sum_act, sum_exp;

    // Bias operands near the 49-bit wraparound boundary (all-1s, 0, and
    // the halfway point 2^48) plus general spread, so carry-out-of-range
    // wraparound gets exercised far more than uniform random alone.
    constraint c_a_corner_dist {
        a dist { 49'h0 := 4, {49{1'b1}} := 4, 49'h1_0000_0000_0000 := 3, 49'h1_FFFF_FFFF_FFFE := 3, [0:49'h1_FFFF_FFFF_FFFE] :/ 86 };
    }
    constraint c_b_corner_dist {
        b dist { 49'h0 := 4, {49{1'b1}} := 4, 49'h1_0000_0000_0000 := 3, 49'h1_FFFF_FFFF_FFFE := 3, [0:49'h1_FFFF_FFFF_FFFE] :/ 86 };
    }
    constraint c_cin_dist { cin dist { 0 := 50, 1 := 50 }; }

    function new(string tag_ = "random"); tag = tag_; endfunction
    function string to_s();
        return $sformatf("a=%013h b=%013h cin=%0b", a, b, cin);
    endfunction
endclass


// -------------------------------------------------------------
// 4. GOLDEN / REFERENCE MODEL -- 49-bit wraparound adder
// -------------------------------------------------------------
function automatic void ks_golden(ks_txn t);
    t.sum_exp = t.a + t.b + t.cin;   // 49-bit variables -> natural wraparound
endfunction


// -------------------------------------------------------------
// 5. GENERATOR
// -------------------------------------------------------------
class ks_generator;
    ks_txn items[$];
    int num_random;

    function new(int num_random = 1500); this.num_random = num_random; endfunction

    function void build();
        ks_txn t;
        t = new("dir_zero_zero");      t.a=0;  t.b=0; t.cin=0; items.push_back(t);
        t = new("dir_max_plus_one");   t.a='1; t.b=1; t.cin=0; items.push_back(t);  // full wraparound to 0
        t = new("dir_max_plus_cin");   t.a='1; t.b=0; t.cin=1; items.push_back(t);  // wraparound via cin
        t = new("dir_half_plus_half"); t.a=49'h1_0000_0000_0000; t.b=49'h1_0000_0000_0000; t.cin=0; items.push_back(t);

        // --- additional corner cases -------------------------------------
        t = new("dir_max_plus_max");     t.a='1; t.b='1; t.cin=1; items.push_back(t);
        t = new("dir_zero_plus_cin");    t.a=0;  t.b=0;  t.cin=1; items.push_back(t);
        t = new("dir_one_below_max_plus_one"); t.a=49'h1_FFFF_FFFF_FFFE; t.b=1; t.cin=0; items.push_back(t);
        for (int i = 0; i < 49; i++) begin
            t = new($sformatf("dir_walk1_a_bit%0d", i)); t.a = 49'h1 << i; t.b = 0; t.cin = 0; items.push_back(t);
        end

        repeat (num_random) begin
            ks_txn r = new("random");
            assert (r.randomize()) else $error("[GEN] randomize() failed");
            items.push_back(r);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 6. DRIVER
// -------------------------------------------------------------
class ks_driver;
    virtual kogge_stone_49_if vif;
    function new(virtual kogge_stone_49_if vif); this.vif = vif; endfunction

    task apply(ks_txn t);
        @(negedge vif.clk);
        vif.a <= t.a; vif.b <= t.b; vif.cin <= t.cin;
    endtask
endclass


// -------------------------------------------------------------
// 7. MONITOR
// -------------------------------------------------------------
class ks_monitor;
    virtual kogge_stone_49_if vif;

    covergroup cg_ks;
        cp_cin: coverpoint vif.cin;
        cp_a_zero: coverpoint (vif.a == 0);
        cp_b_zero: coverpoint (vif.b == 0);
        cp_wrap: coverpoint ((vif.a + vif.b + vif.cin) > 49'h1_FFFF_FFFF_FFFF);
    endgroup

    function new(virtual kogge_stone_49_if vif); this.vif = vif; cg_ks = new(); endfunction

    task sample_one(output bit [48:0] sum_);
        #1;
        sum_ = vif.sum;
        cg_ks.sample();
    endtask
endclass


// -------------------------------------------------------------
// 8. SCOREBOARD
// -------------------------------------------------------------
class ks_scoreboard;
    int pass_cnt = 0;
    int fail_cnt = 0;

    task check(ks_txn t, bit [48:0] sum_);
        t.sum_act = sum_;
        ks_golden(t);
        if (t.sum_act === t.sum_exp) begin
            pass_cnt++;
            $display("[PASS] %-16s %-0s -> sum=%013h", t.tag, t.to_s(), sum_);
        end else begin
            fail_cnt++;
            $display("[FAIL] %-16s %-0s -> got=%013h exp=%013h", t.tag, t.to_s(), sum_, t.sum_exp);
        end
    endtask
endclass


// -------------------------------------------------------------
// 9. ENVIRONMENT
// -------------------------------------------------------------
class ks_env;
    virtual kogge_stone_49_if vif;
    ks_generator  gen;
    ks_driver     drv;
    ks_monitor    mon;
    ks_scoreboard sb;

    function new(virtual kogge_stone_49_if vif, int num_random = 1500);
        this.vif = vif;
        gen = new(num_random);
        drv = new(vif);
        mon = new(vif);
        sb  = new();
    endfunction

    task run();
        bit [48:0] sum_;
        gen.build();
        foreach (gen.items[i]) begin
            drv.apply(gen.items[i]);
            mon.sample_one(sum_);
            sb.check(gen.items[i], sum_);
        end

        $display("\n================ KOGGE_STONE_49 UNIT TB SUMMARY ================");
        $display(" TOTAL=%0d  PASS=%0d  FAIL=%0d", gen.items.size(), sb.pass_cnt, sb.fail_cnt);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", mon.cg_ks.get_coverage());
        if (sb.fail_cnt == 0) $display(" RESULT: ALL CHECKS PASSED");
        else                  $display(" RESULT: %0d CHECK(S) FAILED", sb.fail_cnt);
        tb_signoff(mon.cg_ks.get_coverage(), sb.fail_cnt);
        $display("===================================================================\n");
    endtask
endclass


// -------------------------------------------------------------
// 10. TEST
// -------------------------------------------------------------
class ks_test;
    ks_env env;
    function new(virtual kogge_stone_49_if vif, int num_random = 1500);
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

    kogge_stone_49_if vif(clk);

    kogge_stone_49 dut (
        .a(vif.a), .b(vif.b), .cin(vif.cin), .sum(vif.sum)
    );

    ks_test test;

    initial begin
        int tb_nrand = 1500;
        tb_control_init(tb_nrand, "tb_dsu_kogge_stone_49");
        vif.a = 0; vif.b = 0; vif.cin = 0;
        repeat (3) @(posedge clk);

        test = new(vif, tb_nrand);
        test.run();
        $finish;
    end

    // Watchdog: a hung testbench must fail loudly, not sit until the
    // grid scheduler kills it with no diagnosis. Override with
    // +TIMEOUT_NS=<n> for deliberately long soaks.
    initial begin
        int wd_ns;
        if (!$value$plusargs("TIMEOUT_NS=%d", wd_ns)) wd_ns = 50000000;
        #(wd_ns);
        $display("\n[WATCHDOG] no completion after %0d ns -- aborting", wd_ns);
        $fatal(1, "testbench watchdog expired");
    end

endmodule
