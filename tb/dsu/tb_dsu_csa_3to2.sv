// =============================================================
// tb_dsu_csa_3to2.sv
//
//  BLOCK      : II -- DSU (Custom-0 MAC coprocessor)
//  RTL SOURCE : rtl/dsu/csa_3to2.v   (GARUDA_DSU_DesignSpec)
//  SCOPE      : DSU unit module
//
// Single-file SV verification environment for GARUDA csa_3to2.v
// (3:2 carry-save compressor, WIDTH=48 as instantiated by mac_unit.v)
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
// 1. DUT: csa_3to2.v (pasted verbatim, self-contained file)
// -------------------------------------------------------------
module csa_3to2 #(parameter WIDTH = 48) (
    input wire [WIDTH-1:0] a,
    input wire [WIDTH-1:0] b,
    input wire [WIDTH-1:0] c,
    output wire [WIDTH-1:0] sum,
    output wire [WIDTH-1:0] carry
);

    assign sum = a^b^c;
    assign carry = ((a & b) | (b&c) | (a&c)) << 1;

endmodule


// -------------------------------------------------------------
// 2. INTERFACE (+ bound SVA)
// -------------------------------------------------------------
interface csa_3to2_if (input bit clk);
    logic [47:0] a, b, c;
    logic [47:0] sum, carry;

    property p_no_x_propagation;
        @(posedge clk) (!$isunknown({a, b, c})) |-> (!$isunknown({sum, carry}));
    endproperty
    a_no_x_propagation: assert property (p_no_x_propagation)
        else $error("[SVA-FAIL] X detected on csa_3to2 outputs with fully-known inputs");
endinterface


// -------------------------------------------------------------
// 3. STIMULUS ITEM
// -------------------------------------------------------------
class csa_txn;
    rand bit [47:0] a, b, c;
    string tag;
    bit [47:0] sum_act, carry_act, sum_exp, carry_exp;

    // Bias each operand toward 0 / all-1s / alternating-bit patterns / a
    // single walking-1 bit, since those are the values most likely to
    // expose an XOR/AND-tree bit-slip that uniform random rarely hits.
    constraint c_a_corner_dist {
        a dist { 48'h0 := 4, {48{1'b1}} := 4, 48'h5555_5555_5555 := 3, 48'hAAAA_AAAA_AAAA := 3, [0:48'hFFFF_FFFF_FFFE] :/ 86 };
    }
    constraint c_b_corner_dist {
        b dist { 48'h0 := 4, {48{1'b1}} := 4, 48'h5555_5555_5555 := 3, 48'hAAAA_AAAA_AAAA := 3, [0:48'hFFFF_FFFF_FFFE] :/ 86 };
    }
    constraint c_c_corner_dist {
        c dist { 48'h0 := 20, 48'h1 := 20, {48{1'b1}} := 10, [0:48'hFFFF_FFFF_FFFE] :/ 50 };
    }

    function new(string tag_ = "random"); tag = tag_; endfunction
    function string to_s();
        return $sformatf("a=%012h b=%012h c=%012h", a, b, c);
    endfunction
endclass


// -------------------------------------------------------------
// 4. GOLDEN / REFERENCE MODEL
// -------------------------------------------------------------
function automatic void csa_golden(csa_txn t);
    t.sum_exp   = t.a ^ t.b ^ t.c;
    t.carry_exp = ((t.a & t.b) | (t.b & t.c) | (t.a & t.c)) << 1;
endfunction


// -------------------------------------------------------------
// 5. GENERATOR
// -------------------------------------------------------------
class csa_generator;
    csa_txn items[$];
    int num_random;

    function new(int num_random = 1500); this.num_random = num_random; endfunction

    function void build();
        csa_txn t;
        t = new("dir_all_zero");    t.a=0;      t.b=0;      t.c=0;      items.push_back(t);
        t = new("dir_all_ones");    t.a='1;     t.b='1;     t.c='1;     items.push_back(t);
        t = new("dir_carry_chain"); t.a=48'h1;  t.b=48'h1;  t.c=48'h1;  items.push_back(t);
        t = new("dir_alt_bits");    t.a=48'h5555_5555_5555; t.b=48'hAAAA_AAAA_AAAA; t.c=48'h0000_0000_0001; items.push_back(t);

        // --- additional corner cases: walking single bit through a/b/c --
        for (int i = 0; i < 48; i++) begin
            t = new($sformatf("dir_walk1_a_bit%0d", i)); t.a = 48'h1 << i; t.b = 0; t.c = 0; items.push_back(t);
        end
        t = new("dir_msb_only_all");  t.a=48'h8000_0000_0000; t.b=48'h8000_0000_0000; t.c=48'h8000_0000_0000; items.push_back(t);
        t = new("dir_lsb_only_all");  t.a=48'h1; t.b=48'h1; t.c=48'h1; items.push_back(t);
        t = new("dir_mixed_extremes"); t.a=48'h0; t.b='1; t.c=48'h1; items.push_back(t);

        repeat (num_random) begin
            csa_txn r = new("random");
            assert (r.randomize()) else $error("[GEN] randomize() failed");
            items.push_back(r);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 6. DRIVER
// -------------------------------------------------------------
class csa_driver;
    virtual csa_3to2_if vif;
    function new(virtual csa_3to2_if vif); this.vif = vif; endfunction

    task apply(csa_txn t);
        @(negedge vif.clk);
        vif.a <= t.a; vif.b <= t.b; vif.c <= t.c;
    endtask
endclass


// -------------------------------------------------------------
// 7. MONITOR
// -------------------------------------------------------------
class csa_monitor;
    virtual csa_3to2_if vif;

    covergroup cg_csa;
        cp_a_zero: coverpoint (vif.a == 0);
        cp_b_zero: coverpoint (vif.b == 0);
        cp_c_zero: coverpoint (vif.c == 0);
        cp_all_ones: coverpoint (vif.a == '1 && vif.b == '1 && vif.c == '1);
    endgroup

    function new(virtual csa_3to2_if vif); this.vif = vif; cg_csa = new(); endfunction

    task sample_one(output bit [47:0] sum_, output bit [47:0] carry_);
        #1;
        sum_ = vif.sum; carry_ = vif.carry;
        cg_csa.sample();
    endtask
endclass


// -------------------------------------------------------------
// 8. SCOREBOARD
// -------------------------------------------------------------
class csa_scoreboard;
    int pass_cnt = 0;
    int fail_cnt = 0;

    task check(csa_txn t, bit [47:0] sum_, bit [47:0] carry_);
        t.sum_act = sum_; t.carry_act = carry_;
        csa_golden(t);
        if (t.sum_act === t.sum_exp && t.carry_act === t.carry_exp) begin
            pass_cnt++;
            $display("[PASS] %-16s %-0s -> sum=%012h carry=%012h", t.tag, t.to_s(), sum_, carry_);
        end else begin
            fail_cnt++;
            $display("[FAIL] %-16s %-0s -> got(sum=%012h carry=%012h) exp(sum=%012h carry=%012h)",
                      t.tag, t.to_s(), sum_, carry_, t.sum_exp, t.carry_exp);
        end
    endtask
endclass


// -------------------------------------------------------------
// 9. ENVIRONMENT
// -------------------------------------------------------------
class csa_env;
    virtual csa_3to2_if vif;
    csa_generator  gen;
    csa_driver     drv;
    csa_monitor    mon;
    csa_scoreboard sb;

    function new(virtual csa_3to2_if vif, int num_random = 1500);
        this.vif = vif;
        gen = new(num_random);
        drv = new(vif);
        mon = new(vif);
        sb  = new();
    endfunction

    task run();
        bit [47:0] sum_, carry_;
        gen.build();
        foreach (gen.items[i]) begin
            drv.apply(gen.items[i]);
            mon.sample_one(sum_, carry_);
            sb.check(gen.items[i], sum_, carry_);
        end

        $display("\n================ CSA_3TO2 UNIT TB SUMMARY ================");
        $display(" TOTAL=%0d  PASS=%0d  FAIL=%0d", gen.items.size(), sb.pass_cnt, sb.fail_cnt);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", mon.cg_csa.get_coverage());
        if (sb.fail_cnt == 0) $display(" RESULT: ALL CHECKS PASSED");
        else                  $display(" RESULT: %0d CHECK(S) FAILED", sb.fail_cnt);
        tb_signoff(mon.cg_csa.get_coverage(), sb.fail_cnt);
        $display("============================================================\n");
    endtask
endclass


// -------------------------------------------------------------
// 10. TEST
// -------------------------------------------------------------
class csa_test;
    csa_env env;
    function new(virtual csa_3to2_if vif, int num_random = 1500);
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

    csa_3to2_if vif(clk);

    csa_3to2 #(.WIDTH(48)) dut (
        .a(vif.a), .b(vif.b), .c(vif.c), .sum(vif.sum), .carry(vif.carry)
    );

    csa_test test;

    initial begin
        int tb_nrand = 1500;
        tb_control_init(tb_nrand, "tb_dsu_csa_3to2");
        vif.a = 0; vif.b = 0; vif.c = 0;
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
