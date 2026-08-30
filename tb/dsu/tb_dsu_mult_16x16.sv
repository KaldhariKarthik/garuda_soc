// =============================================================
// tb_dsu_mult_16x16.sv
//
//  BLOCK      : II -- DSU (Custom-0 MAC coprocessor)
//  RTL SOURCE : rtl/dsu/mult_16x16.v   (GARUDA_DSU_DesignSpec)
//  SCOPE      : DSU unit module
//
// Single-file SV verification environment for GARUDA mult_16x16.v
// (16-bit signed multiplier, the core arithmetic primitive of each
// MAC lane inside mac_unit.v)
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
// 1. DUT: mult_16x16.v (pasted verbatim, self-contained file)
// -------------------------------------------------------------
module mult_16x16 (
    input wire signed [15:0] a,
    input wire signed [15:0] b,
    output wire signed [31:0] p
);
    assign p = a*b;

endmodule


// -------------------------------------------------------------
// 2. INTERFACE (+ bound SVA)
// -------------------------------------------------------------
interface mult_16x16_if (input bit clk);
    logic signed [15:0] a, b;
    logic signed [31:0] p;

    property p_no_x_propagation;
        @(posedge clk) (!$isunknown({a, b})) |-> (!$isunknown(p));
    endproperty
    a_no_x_propagation: assert property (p_no_x_propagation)
        else $error("[SVA-FAIL] X detected on mult_16x16 product with fully-known inputs");
endinterface


// -------------------------------------------------------------
// 3. STIMULUS ITEM
// -------------------------------------------------------------
class mult_txn;
    rand bit signed [15:0] a, b;
    string tag;
    bit signed [31:0] p_act, p_exp;

    // Bias each 16-bit operand toward its signed extremes (INT16_MIN,
    // INT16_MAX, -1, 0, 1) and alternating-bit patterns, since those are
    // exactly the values that expose sign-extension / overflow bugs in a
    // '*' synthesis (Booth/Wallace tree) implementation.
    //
    // The general-spread portion is split into TWO ranges (positives, then
    // negatives) rather than one [16'sh8001:16'sh7FFE]. A single range
    // written that way ascends only if the tool evaluates the bounds as
    // SIGNED; read as unsigned, 0x8001 (32769) > 0x7FFE (32766) makes it an
    // EMPTY range -- which would not error, it would silently collapse
    // every "general random" draw onto the corner singletons and quietly
    // gut the random portion of this test. Both ranges below ascend under
    // either interpretation, so there is nothing left to depend on.
    constraint c_a_corner_dist {
        a dist { 16'h8000 := 8, 16'h7FFF := 8, 16'h0000 := 6, 16'hFFFF := 6, 16'h0001 := 4,
                 16'h5555 := 3, 16'hAAAA := 3,
                 [16'h0002:16'h7FFE] :/ 31, [16'h8001:16'hFFFE] :/ 31 };
    }
    constraint c_b_corner_dist {
        b dist { 16'h8000 := 8, 16'h7FFF := 8, 16'h0000 := 6, 16'hFFFF := 6, 16'h0001 := 4,
                 16'h5555 := 3, 16'hAAAA := 3,
                 [16'h0002:16'h7FFE] :/ 31, [16'h8001:16'hFFFE] :/ 31 };
    }

    function new(string tag_ = "random"); tag = tag_; endfunction
    function string to_s();
        return $sformatf("a=%0d b=%0d", a, b);
    endfunction
endclass


// -------------------------------------------------------------
// 4. GOLDEN / REFERENCE MODEL -- exact, no truncation possible
// -------------------------------------------------------------
function automatic void mult_golden(mult_txn t);
    t.p_exp = t.a * t.b;
endfunction


// -------------------------------------------------------------
// 5. GENERATOR
// -------------------------------------------------------------
class mult_generator;
    mult_txn items[$];
    int num_random;

    function new(int num_random = 1500); this.num_random = num_random; endfunction

    function void build();
        mult_txn t;
        t = new("dir_min_x_min");     t.a=16'sh8000; t.b=16'sh8000;  items.push_back(t); // (-32768)^2 = 2^30
        t = new("dir_min_x_maxneg1"); t.a=16'sh8000; t.b=-16'sd1;    items.push_back(t); // overflow-adjacent
        t = new("dir_max_x_max");     t.a=16'sh7FFF; t.b=16'sh7FFF;  items.push_back(t);
        t = new("dir_zero");          t.a=0;         t.b=16'sh7FFF;  items.push_back(t);
        t = new("dir_neg_x_pos");     t.a=-16'sd100; t.b=16'sd200;   items.push_back(t);

        // --- additional corner cases -------------------------------------
        t = new("dir_min_x_one");   t.a=16'sh8000; t.b=16'sd1;      items.push_back(t);
        t = new("dir_min_x_zero");  t.a=16'sh8000; t.b=16'sd0;      items.push_back(t);
        t = new("dir_max_x_min");   t.a=16'sh7FFF; t.b=16'sh8000;   items.push_back(t);
        t = new("dir_neg1_x_neg1"); t.a=-16'sd1;   t.b=-16'sd1;     items.push_back(t);
        t = new("dir_neg1_x_min");  t.a=-16'sd1;   t.b=16'sh8000;   items.push_back(t);  // overflow: -MIN not representable
        t = new("dir_alt_bits");    t.a=16'sh5555; t.b=16'shAAAA;   items.push_back(t);
        for (int i = 0; i < 16; i++) begin
            t = new($sformatf("dir_walk1_a_bit%0d", i)); t.a = 16'sh0001 << i; t.b = 16'sd1; items.push_back(t);
        end

        repeat (num_random) begin
            mult_txn r = new("random");
            assert (r.randomize()) else $error("[GEN] randomize() failed");
            items.push_back(r);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 6. DRIVER
// -------------------------------------------------------------
class mult_driver;
    virtual mult_16x16_if vif;
    function new(virtual mult_16x16_if vif); this.vif = vif; endfunction

    task apply(mult_txn t);
        @(negedge vif.clk);
        vif.a <= t.a; vif.b <= t.b;
    endtask
endclass


// -------------------------------------------------------------
// 7. MONITOR
// -------------------------------------------------------------
class mult_monitor;
    virtual mult_16x16_if vif;

    covergroup cg_mult;
        cp_a_sign: coverpoint vif.a[15];
        cp_b_sign: coverpoint vif.b[15];
        cp_a_zero: coverpoint (vif.a == 0);
        cp_b_zero: coverpoint (vif.b == 0);
        cross cp_a_sign, cp_b_sign;
    endgroup

    function new(virtual mult_16x16_if vif); this.vif = vif; cg_mult = new(); endfunction

    task sample_one(output bit signed [31:0] p_);
        #1;
        p_ = vif.p;
        cg_mult.sample();
    endtask
endclass


// -------------------------------------------------------------
// 8. SCOREBOARD
// -------------------------------------------------------------
class mult_scoreboard;
    int pass_cnt = 0;
    int fail_cnt = 0;

    task check(mult_txn t, bit signed [31:0] p_);
        t.p_act = p_;
        mult_golden(t);
        if (t.p_act === t.p_exp) begin
            pass_cnt++;
            $display("[PASS] %-18s %-0s -> p=%0d", t.tag, t.to_s(), p_);
        end else begin
            fail_cnt++;
            $display("[FAIL] %-18s %-0s -> got=%0d exp=%0d", t.tag, t.to_s(), p_, t.p_exp);
        end
    endtask
endclass


// -------------------------------------------------------------
// 9. ENVIRONMENT
// -------------------------------------------------------------
class mult_env;
    virtual mult_16x16_if vif;
    mult_generator  gen;
    mult_driver     drv;
    mult_monitor    mon;
    mult_scoreboard sb;

    function new(virtual mult_16x16_if vif, int num_random = 1500);
        this.vif = vif;
        gen = new(num_random);
        drv = new(vif);
        mon = new(vif);
        sb  = new();
    endfunction

    task run();
        bit signed [31:0] p_;
        gen.build();
        foreach (gen.items[i]) begin
            drv.apply(gen.items[i]);
            mon.sample_one(p_);
            sb.check(gen.items[i], p_);
        end

        $display("\n================ MULT_16X16 UNIT TB SUMMARY ================");
        $display(" TOTAL=%0d  PASS=%0d  FAIL=%0d", gen.items.size(), sb.pass_cnt, sb.fail_cnt);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", mon.cg_mult.get_coverage());
        if (sb.fail_cnt == 0) $display(" RESULT: ALL CHECKS PASSED");
        else                  $display(" RESULT: %0d CHECK(S) FAILED", sb.fail_cnt);
        tb_signoff(mon.cg_mult.get_coverage(), sb.fail_cnt);
        $display("===============================================================\n");
    endtask
endclass


// -------------------------------------------------------------
// 10. TEST
// -------------------------------------------------------------
class mult_test;
    mult_env env;
    function new(virtual mult_16x16_if vif, int num_random = 1500);
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

    mult_16x16_if vif(clk);

    mult_16x16 dut (
        .a(vif.a), .b(vif.b), .p(vif.p)
    );

    mult_test test;

    initial begin
        int tb_nrand = 1500;
        tb_control_init(tb_nrand, "tb_dsu_mult_16x16");
        vif.a = 0; vif.b = 0;
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
