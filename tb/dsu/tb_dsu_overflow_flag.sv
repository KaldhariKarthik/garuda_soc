// =============================================================
// tb_dsu_overflow_flag.sv
//
//  BLOCK      : II -- DSU (Custom-0 MAC coprocessor)
//  RTL SOURCE : rtl/dsu/overflow_flag.v   (GARUDA_DSU_DesignSpec)
//  SCOPE      : DSU unit module
//
// Single-file SV verification environment for GARUDA overflow_flag.v
// (sticky overflow status register, set by any MAC/saturation
// overflow event, cleared only by a csr_clear_overflow pulse)
//
// SEQUENTIAL (has real registered state) -- like dsu_stall, this
// needs a stateful reference model stepped in lockstep with the DUT
// across a single continuous cycle stream, not independent items.
// Priority is checked explicitly: the RTL's if/else-if order checks
// csr_clear_overflow BEFORE any_ovf, so a simultaneous clear-pulse
// and overflow-event in the SAME cycle must clear, not set.
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
// 1. DUT: overflow_flag.v (pasted verbatim, self-contained file)
// -------------------------------------------------------------
module overflow_flag (
    input wire       clk,
    input wire       rst_n,
    input wire [2:0] mac_overflow,
    input wire       sat_overflow,
    input wire       csr_clear_overflow,

    output reg dsu_overflow
);

    wire any_ovf = (|mac_overflow) | sat_overflow;

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)                   dsu_overflow <= 1'b0;
        else if (csr_clear_overflow) dsu_overflow <= 1'b0;
        else if (any_ovf)            dsu_overflow <= 1'b1;
    end

endmodule


// -------------------------------------------------------------
// 2. INTERFACE (+ bound SVA)
// -------------------------------------------------------------
interface overflow_flag_if (input bit clk);
    logic       rst_n;
    logic [2:0] mac_overflow;
    logic       sat_overflow;
    logic       csr_clear_overflow;
    logic       dsu_overflow;

    property p_no_x_propagation;
        @(posedge clk) disable iff (!rst_n)
        (!$isunknown({mac_overflow, sat_overflow, csr_clear_overflow})) |-> (!$isunknown(dsu_overflow));
    endproperty
    a_no_x_propagation: assert property (p_no_x_propagation)
        else $error("[SVA-FAIL] X detected on dsu_overflow with fully-known inputs");

    // Reset must clear the flag.
    property p_reset_clears;
        @(posedge clk) $rose(rst_n) |-> !dsu_overflow;
    endproperty
    a_reset_clears: assert property (p_reset_clears)
        else $error("[SVA-FAIL] dsu_overflow asserted on the cycle immediately following reset release");

    // A clear pulse must always clear the flag the NEXT cycle,
    // regardless of what any_ovf was doing that same cycle
    // (priority: clear beats set).
    property p_clear_wins_next_cycle;
        @(posedge clk) disable iff (!rst_n)
        $past(csr_clear_overflow) |-> !dsu_overflow;
    endproperty
    a_clear_wins_next_cycle: assert property (p_clear_wins_next_cycle)
        else $error("[SVA-FAIL] dsu_overflow asserted the cycle after a clear pulse (priority violated)");
endinterface


// -------------------------------------------------------------
// 3. PER-CYCLE STIMULUS ITEM
// -------------------------------------------------------------
class ovf_cycle;
    rand bit [2:0] mac_overflow;
    rand bit       sat_overflow;
    rand bit       csr_clear_overflow;
    rand bit       rst_n;
    string tag;

    constraint c_dist {
        mac_overflow dist { 3'b000 := 70, [3'b001:3'b111] :/ 30 };
        sat_overflow dist { 0 := 80, 1 := 20 };
        csr_clear_overflow dist { 0 := 85, 1 := 15 };
        rst_n dist { 1 := 97, 0 := 3 };
    }

    function new(string tag_ = "random"); tag = tag_; endfunction
    function string to_s();
        return $sformatf("mac_ovf=%03b sat_ovf=%0b clr=%0b rst_n=%0b", mac_overflow, sat_overflow, csr_clear_overflow, rst_n);
    endfunction
endclass


// -------------------------------------------------------------
// 4. REFERENCE MODEL -- persistent sticky-bit state stepped once
//    per cycle in lockstep with the DUT (same priority order as the
//    RTL's if/else-if chain: reset > clear > set > hold).
// -------------------------------------------------------------
class ovf_ref_model;
    bit state;
    function new(); state = 1'b0; endfunction

    function bit step(bit [2:0] mac_ovf, bit sat_ovf, bit clr, bit rst_n);
        bit any_ovf = (|mac_ovf) | sat_ovf;
        bit visible_now;
        // DSU_Golden.py convention: dsu_overflow is REGISTERED, so the value
        // visible during this cycle is the one latched at the PREVIOUS edge.
        // Their model does exactly this:
        //     overflow_now = self.overflow_sticky   # value visible THIS cycle
        //     ... compute next_ovf ... ; self.overflow_sticky = next_ovf
        // Reset is asynchronous, so it is applied before the snapshot.
        if (!rst_n) state = 1'b0;
        visible_now = state;
        if      (!rst_n)  state = 1'b0;
        else if (clr)     state = 1'b0;   // FLAG-E: clear beats a same-cycle set
        else if (any_ovf) state = 1'b1;
        // else: hold
        return visible_now;
    endfunction
endclass


// -------------------------------------------------------------
// 5. GENERATOR -- one continuous cycle stream (directed then CRV),
//    since correctness here is defined across the stream, not per cycle.
// -------------------------------------------------------------
class ovf_generator;
    ovf_cycle items[$];
    int num_random;

    function new(int num_random = 1500); this.num_random = num_random; endfunction

    function ovf_cycle mk(string tag, bit [2:0] mac_ovf, bit sat_ovf, bit clr, bit rst_n = 1);
        ovf_cycle c = new(tag);
        c.mac_overflow = mac_ovf; c.sat_overflow = sat_ovf; c.csr_clear_overflow = clr; c.rst_n = rst_n;
        return c;
    endfunction

    function void build();
        // --- sticky behavior: set once, stays set across quiet cycles ---
        items.push_back(mk("dir_set_mac0",  3'b001, 0, 0));
        items.push_back(mk("dir_hold_1",    3'b000, 0, 0));
        items.push_back(mk("dir_hold_2",    3'b000, 0, 0));
        items.push_back(mk("dir_hold_3",    3'b000, 0, 0));

        // --- clear pulse actually clears ---------------------------------
        items.push_back(mk("dir_clear",       3'b000, 0, 1));
        items.push_back(mk("dir_after_clear", 3'b000, 0, 0));

        // --- sat_overflow alone also sets the flag ------------------------
        items.push_back(mk("dir_set_sat",       3'b000, 1, 0));
        items.push_back(mk("dir_hold_after_sat", 3'b000, 0, 0));

        // --- PRIORITY: clear and overflow asserted the SAME cycle ---------
        items.push_back(mk("dir_clear_wins_vs_mac", 3'b100, 0, 1));
        items.push_back(mk("dir_settle_after_priority", 3'b000, 0, 0));
        items.push_back(mk("dir_clear_wins_vs_sat", 3'b000, 1, 1));
        items.push_back(mk("dir_settle_after_priority2", 3'b000, 0, 0));

        // --- multiple mac_overflow bits at once ---------------------------
        items.push_back(mk("dir_multi_bit",   3'b101, 1, 0));
        items.push_back(mk("dir_clear_final", 3'b000, 0, 1));

        // --- reset mid-stream after setting the flag ----------------------
        items.push_back(mk("dir_set_before_reset", 3'b010, 0, 0));
        items.push_back(mk("dir_reset_pulse",      3'b000, 0, 0, 0));
        items.push_back(mk("dir_after_reset",      3'b000, 0, 0, 1));

        // --- additional corner cases: each mac_overflow bit individually --
        for (int i = 0; i < 3; i++) begin
            items.push_back(mk($sformatf("dir_clear_before_bit%0d", i), 3'b000, 0, 1));
            items.push_back(mk($sformatf("dir_set_only_bit%0d", i), (3'b001 << i), 0, 0));
            items.push_back(mk($sformatf("dir_hold_after_bit%0d", i), 3'b000, 0, 0));
        end
        // clear immediately followed by another clear (idempotent)
        items.push_back(mk("dir_double_clear_1", 3'b000, 0, 1));
        items.push_back(mk("dir_double_clear_2", 3'b000, 0, 1));
        // set, then clear+set same cycle repeated (stress the priority mux)
        items.push_back(mk("dir_set_for_stress", 3'b111, 1, 0));
        items.push_back(mk("dir_clearset_stress_1", 3'b111, 1, 1));
        items.push_back(mk("dir_clearset_stress_2", 3'b111, 1, 1));
        items.push_back(mk("dir_clearset_stress_3", 3'b000, 0, 1));

        repeat (num_random) begin
            ovf_cycle r = new("random");
            assert (r.randomize()) else $error("[GEN] randomize() failed");
            items.push_back(r);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 6. DRIVER
// -------------------------------------------------------------
class ovf_driver;
    virtual overflow_flag_if vif;
    function new(virtual overflow_flag_if vif); this.vif = vif; endfunction

    task apply(ovf_cycle c);
        @(negedge vif.clk);
        vif.mac_overflow       <= c.mac_overflow;
        vif.sat_overflow       <= c.sat_overflow;
        vif.csr_clear_overflow <= c.csr_clear_overflow;
        vif.rst_n              <= c.rst_n;
    endtask
endclass


// -------------------------------------------------------------
// 7. MONITOR
// -------------------------------------------------------------
class ovf_monitor;
    virtual overflow_flag_if vif;

    covergroup cg_ovf;
        cp_flag: coverpoint vif.dsu_overflow;
        cp_clear: coverpoint vif.csr_clear_overflow;
        cp_rst_n: coverpoint vif.rst_n;
        cross cp_flag, cp_clear;
    endgroup

    function new(virtual overflow_flag_if vif); this.vif = vif; cg_ovf = new(); endfunction

    // TIMING NOTE (this was a real TB bug, fixed here):
    // dsu_overflow is a REGISTERED output -- it only takes this cycle's
    // value at the posedge that latches this cycle's inputs. The driver
    // applies inputs at the NEGEDGE, so the latching posedge has not
    // happened yet when apply() returns. Sampling immediately (the old
    // "#1;" alone) therefore read the PREVIOUS cycle's flag while the
    // reference model had already advanced one step -- a guaranteed
    // one-cycle skew that would fail on every transition.
    // Crossing the posedge first aligns DUT and model.
    task sample_one(output bit flag_);
        #1;
        flag_ = vif.dsu_overflow;
        cg_ovf.sample();
    endtask
endclass


// -------------------------------------------------------------
// 8. SCOREBOARD
// -------------------------------------------------------------
class ovf_scoreboard;
    int pass_cnt = 0;
    int fail_cnt = 0;

    task check(ovf_cycle c, bit actual, ref ovf_ref_model model);
        bit expected = model.step(c.mac_overflow, c.sat_overflow, c.csr_clear_overflow, c.rst_n);
        if (actual === expected) begin
            pass_cnt++;
            $display("[PASS] %-28s %-0s -> dsu_overflow=%0b", c.tag, c.to_s(), actual);
        end else begin
            fail_cnt++;
            $display("[FAIL] %-28s %-0s -> got=%0b exp=%0b", c.tag, c.to_s(), actual, expected);
        end
    endtask
endclass


// -------------------------------------------------------------
// 9. ENVIRONMENT
// -------------------------------------------------------------
class ovf_env;
    virtual overflow_flag_if vif;
    ovf_generator  gen;
    ovf_driver     drv;
    ovf_monitor    mon;
    ovf_scoreboard sb;
    ovf_ref_model  model;

    function new(virtual overflow_flag_if vif, int num_random = 1500);
        this.vif = vif;
        gen = new(num_random);
        drv = new(vif);
        mon = new(vif);
        sb  = new();
        model = new();  // matches the DUT's initial (pre-reset-release) state
    endfunction

    task run();
        bit actual;
        gen.build();
        foreach (gen.items[i]) begin
            drv.apply(gen.items[i]);
            mon.sample_one(actual);
            sb.check(gen.items[i], actual, model);
        end

        $display("\n================ OVERFLOW_FLAG UNIT TB SUMMARY ================");
        $display(" TOTAL=%0d  PASS=%0d  FAIL=%0d", gen.items.size(), sb.pass_cnt, sb.fail_cnt);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", mon.cg_ovf.get_coverage());
        if (sb.fail_cnt == 0) $display(" RESULT: ALL CHECKS PASSED");
        else                  $display(" RESULT: %0d CHECK(S) FAILED", sb.fail_cnt);
        tb_signoff(mon.cg_ovf.get_coverage(), sb.fail_cnt);
        $display("==================================================================\n");
    endtask
endclass


// -------------------------------------------------------------
// 10. TEST
// -------------------------------------------------------------
class ovf_test;
    ovf_env env;
    function new(virtual overflow_flag_if vif, int num_random = 1500);
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

    overflow_flag_if vif(clk);

    overflow_flag dut (
        .clk(clk), .rst_n(vif.rst_n),
        .mac_overflow(vif.mac_overflow),
        .sat_overflow(vif.sat_overflow),
        .csr_clear_overflow(vif.csr_clear_overflow),
        .dsu_overflow(vif.dsu_overflow)
    );

    ovf_test test;

    initial begin
        int tb_nrand = 1500;
        tb_control_init(tb_nrand, "tb_dsu_overflow_flag");
        vif.rst_n = 1'b0;
        vif.mac_overflow = 0; vif.sat_overflow = 0; vif.csr_clear_overflow = 0;
        repeat (3) @(posedge clk);
        vif.rst_n = 1'b1;
        repeat (2) @(posedge clk);

        test = new(vif, tb_nrand);
        test.run();
        $finish;
    end

endmodule
