// =============================================================
// overflow_flag_tb.sv
// Tapeout-grade SV verification environment for GARUDA overflow_flag.v
// (sticky MAC-overflow status register, cleared by CSR write)
//
// Small state space (mac_overflow[2:0] x sat_overflow x
// csr_clear_overflow x prior dsu_overflow = 64 combinations), so this
// environment leans on a full exhaustive sweep rather than sampling,
// plus directed sequences for the sticky/multi-cycle-hold behavior
// and the same-cycle clear-vs-set race this module's priority order
// implies (see FINDING1 below -- flagged for architecture review, not
// asserted as a bug, matching the same standard used throughout this
// GARUDA verification exercise).
//
// IMPORTANT CONTEXT (not re-verified here): mac_unit.v's own overflow
// output was independently proven unreliable in both directions
// (false positive and false negative) whenever csa2's internal
// carry-save truncation condition fires. overflow_flag.v's own logic
// is correct against its own specification, but as a sticky register
// downstream of mac_overflow[2:0], it will faithfully latch that same
// unreliability into a persistent, software-visible status bit. This
// testbench verifies overflow_flag.v in isolation against its OWN
// spec (its inputs are just wires here, driven directly) -- it does
// not re-litigate the upstream mac_unit finding.
//
// Requires a simulator with full IEEE1800 support (covergroup,
// assert property). NOT Icarus Verilog.
// =============================================================

`timescale 1ns / 1ps

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
// 2. INTERFACE (+ bound SVA assertions)
// -------------------------------------------------------------
interface ovf_if (input bit clk);
    logic       rst_n;
    logic [2:0] mac_overflow;
    logic       sat_overflow;
    logic       csr_clear_overflow;
    logic       dsu_overflow;

    // A1: X-propagation, post-reset
    property p_no_x_propagation;
        @(posedge clk) disable iff (!rst_n)
        (!$isunknown({mac_overflow, sat_overflow, csr_clear_overflow})) |-> (!$isunknown(dsu_overflow));
    endproperty
    a_no_x_propagation: assert property (p_no_x_propagation)
        else $error("[SVA-FAIL] X on dsu_overflow with fully-known inputs");

    // A2: reset clears dsu_overflow immediately (async)
    property p_reset_clears;
        @(posedge clk) $rose(rst_n) |-> !dsu_overflow;
    endproperty
    a_reset_clears: assert property (p_reset_clears)
        else $error("[SVA-FAIL] dsu_overflow != 0 the cycle after reset release");

    // A3: once set, dsu_overflow stays set until either a clear or a
    //     reset -- it must never spontaneously self-clear just because
    //     mac_overflow/sat_overflow happen to go low (that's the whole
    //     point of "sticky").
    property p_sticky_holds;
        @(posedge clk) disable iff (!rst_n)
        (dsu_overflow && !csr_clear_overflow) |-> ##1 dsu_overflow;
    endproperty
    a_sticky_holds: assert property (p_sticky_holds)
        else $error("[SVA-FAIL] dsu_overflow cleared itself without csr_clear_overflow or reset");

    // A4: a clear with no concurrent overflow event must actually clear
    property p_clear_works;
        @(posedge clk) disable iff (!rst_n)
        (csr_clear_overflow && !(|mac_overflow) && !sat_overflow) |-> ##1 !dsu_overflow;
    endproperty
    a_clear_works: assert property (p_clear_works)
        else $error("[SVA-FAIL] csr_clear_overflow (with no concurrent overflow) did not clear dsu_overflow");

endinterface


// -------------------------------------------------------------
// 3. PER-CYCLE STIMULUS ITEM -- rand + constraint => real CRV
// -------------------------------------------------------------
class ovf_cycle;
    rand bit [2:0] mac_overflow;
    rand bit       sat_overflow;
    rand bit       csr_clear_overflow;
    rand bit       rst_n;

    constraint c_rst_n_dist { rst_n dist { 1'b1 :/ 95, 1'b0 :/ 5 }; }
    // weight toward "nothing happening" and toward the clear/set race
    // specifically, rather than uniform (which would rarely land both
    // csr_clear_overflow and a mac_overflow bit high on the same cycle)
    constraint c_activity_dist {
        mac_overflow dist { 3'b000 :/ 40, [3'b001:3'b111] :/ 60 };
        sat_overflow dist { 1'b0 :/ 70, 1'b1 :/ 30 };
        csr_clear_overflow dist { 1'b0 :/ 60, 1'b1 :/ 40 };
    }
endclass


// -------------------------------------------------------------
// 4. GENERATOR -- exhaustive sweep + directed sticky/race sequences + CRV
// -------------------------------------------------------------
class ovf_generator;
    ovf_cycle seq_q[$][$];
    string    seq_name[$];
    int num_random_seqs;
    int random_seq_len;

    function new(int num_random_seqs = 15, int random_seq_len = 25);
        this.num_random_seqs = num_random_seqs;
        this.random_seq_len  = random_seq_len;
    endfunction

    function ovf_cycle mk(bit [2:0] mac_ovf = 3'b000, bit sat_ovf = 1'b0,
                           bit clear = 1'b0, bit rst_n = 1'b1);
        ovf_cycle c = new();
        c.mac_overflow = mac_ovf; c.sat_overflow = sat_ovf;
        c.csr_clear_overflow = clear; c.rst_n = rst_n;
        return c;
    endfunction

    function void add_seq(string name, ovf_cycle q[$]);
        seq_name.push_back(name);
        seq_q.push_back(q);
    endfunction

    function void build();
        // 1) EXHAUSTIVE: every (mac_overflow[2:0], sat_overflow,
        //    csr_clear_overflow) combination -- 8*2*2=32 -- against
        //    two base prior-states (dsu_overflow=0 and =1), giving a
        //    complete proof of the combinational/priority logic, not
        //    a sample of it.
        begin
            for (int m = 0; m < 8; m++) begin
                for (int s = 0; s < 2; s++) begin
                    for (int cl = 0; cl < 2; cl++) begin
                        // (a) starting from dsu_overflow=0
                        begin
                            ovf_cycle q[$];
                            q.push_back(mk(3'b000, 1'b0, 1'b0)); // establish dsu_overflow=0 (post-reset-isolated)
                            q.push_back(mk(m[2:0], s[0], cl[0]));
                            add_seq($sformatf("EXH_from0_m%0d_s%0d_c%0d", m, s, cl), q);
                        end
                        // (b) starting from dsu_overflow=1
                        begin
                            ovf_cycle q[$];
                            q.push_back(mk(3'b001, 1'b0, 1'b0)); // establish dsu_overflow=1
                            q.push_back(mk(m[2:0], s[0], cl[0]));
                            add_seq($sformatf("EXH_from1_m%0d_s%0d_c%0d", m, s, cl), q);
                        end
                    end
                end
            end
        end

        // 2) Sticky hold across many idle cycles once set
        begin
            ovf_cycle q[$];
            q.push_back(mk(3'b010)); // sets dsu_overflow
            repeat (8) q.push_back(mk(3'b000, 1'b0, 1'b0)); // idle -- must stay set
            add_seq("sticky_holds_across_idle_cycles", q);
        end

        // 3) *** FINDING 1 *** same-cycle clear-vs-set race. This
        //     module's priority order is reset > clear > set > hold, so
        //     a genuine overflow event landing on the SAME cycle as a
        //     CSR clear is silently dropped (never latched) rather than
        //     being caught by the next read. Demonstrated directly, not
        //     asserted as a verdict either way -- flagged for whoever
        //     owns the CSR/status-register contract to confirm this is
        //     the intended semantics (clear-wins) versus the alternative
        //     (set-wins, so a race can never hide a real event).
        begin
            ovf_cycle q[$];
            q.push_back(mk(3'b000, 1'b0, 1'b0));            // dsu_overflow=0
            q.push_back(mk(3'b100, 1'b0, 1'b1));            // mac_overflow[2] AND clear, same cycle
            q.push_back(mk(3'b000, 1'b0, 1'b0));            // observe: did the overflow get latched or dropped?
            add_seq("FINDING1_clear_vs_set_same_cycle_race", q);
        end

        // 4) Each individual mac_overflow bit alone (isolate bit-wise OR correctness)
        begin
            for (int b = 0; b < 3; b++) begin
                ovf_cycle q[$];
                bit [2:0] one_hot = (3'b001 << b);
                q.push_back(mk(one_hot));
                add_seq($sformatf("mac_overflow_bit%0d_alone", b), q);
            end
        end

        // 5) sat_overflow alone
        begin
            ovf_cycle q[$];
            q.push_back(mk(3'b000, 1'b1));
            add_seq("sat_overflow_alone", q);
        end

        // 6) Reset while set -- async, must clear immediately
        begin
            ovf_cycle q[$];
            q.push_back(mk(3'b001));           // set
            q.push_back(mk(3'b000, 1'b0, 1'b0, 1'b0)); // rst_n=0
            q.push_back(mk(3'b000));
            add_seq("reset_while_set", q);
        end

        // 7) Clear then immediately re-set on the next cycle (no race,
        //    sequential) -- confirms clear and set aren't somehow
        //    order-confused across cycle boundaries
        begin
            ovf_cycle q[$];
            q.push_back(mk(3'b010));           // set
            q.push_back(mk(3'b000, 1'b0, 1'b1)); // clear (no concurrent overflow)
            q.push_back(mk(3'b010));           // set again
            q.push_back(mk(3'b000, 1'b0, 1'b0)); // idle, must still be set
            add_seq("clear_then_reset_sequential", q);
        end

        // 8) CONSTRAINED-RANDOM multi-cycle sequences
        for (int s = 0; s < num_random_seqs; s++) begin
            ovf_cycle q[$];
            for (int c = 0; c < random_seq_len; c++) begin
                ovf_cycle t = new();
                assert (t.randomize()) else $error("[GEN] randomize() failed");
                q.push_back(t);
            end
            add_seq($sformatf("crv_seq_%0d", s), q);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 5. REFERENCE MODEL -- stateful, cycle-accurate, independently
//    structured (explicit priority chain mirroring the RTL's own
//    if/else-if intent, but computed as a fresh boolean expression
//    rather than copy-pasted).
// -------------------------------------------------------------
class ovf_ref_model;
    bit dsu_overflow;

    function new();
        dsu_overflow = 1'b0;
    endfunction

    function bit step(bit [2:0] mac_overflow, bit sat_overflow, bit csr_clear_overflow, bit rst_n);
        bit any_ovf;
        any_ovf = (mac_overflow != 3'b000) || sat_overflow;

        if (!rst_n)
            dsu_overflow = 1'b0;
        else if (csr_clear_overflow)
            dsu_overflow = 1'b0;
        else if (any_ovf)
            dsu_overflow = 1'b1;
        // else: hold

        return dsu_overflow;
    endfunction
endclass


// -------------------------------------------------------------
// 6. DRIVER
// -------------------------------------------------------------
class ovf_driver;
    virtual ovf_if vif;
    function new(virtual ovf_if vif); this.vif = vif; endfunction

    task apply_cycle(bit [2:0] mac_overflow, bit sat_overflow, bit csr_clear_overflow, bit rst_n);
        @(negedge vif.clk);
        vif.mac_overflow <= mac_overflow;
        vif.sat_overflow <= sat_overflow;
        vif.csr_clear_overflow <= csr_clear_overflow;
        vif.rst_n <= rst_n;
    endtask
endclass


// -------------------------------------------------------------
// 7. MONITOR
// -------------------------------------------------------------
class ovf_monitor;
    virtual ovf_if vif;

    covergroup cg_ovf;
        cp_mac_overflow: coverpoint vif.mac_overflow;
        cp_sat_overflow: coverpoint vif.sat_overflow;
        cp_clear: coverpoint vif.csr_clear_overflow;
        cp_dsu_overflow: coverpoint vif.dsu_overflow;
        cp_rst_n: coverpoint vif.rst_n;
        cross cp_clear, cp_mac_overflow;
        cross cp_dsu_overflow, cp_clear {
            // dsu_overflow=1 sampled on the SAME cycle csr_clear_overflow=1
            // was driven is structurally impossible, not just rare: the
            // RTL's priority chain (reset > clear > set > hold) means
            // csr_clear_overflow ALWAYS forces dsu_overflow to 0 that same
            // cycle, with no exception for any_ovf being simultaneously
            // asserted. Since dsu_overflow is sampled AFTER the commit
            // edge (reflecting THIS cycle's own effect), this combination
            // can never be observed regardless of stimulus -- excluded
            // with justification rather than left as a silent shortfall.
            ignore_bins dsu_overflow1_during_clear =
                binsof(cp_dsu_overflow) intersect {1} && binsof(cp_clear) intersect {1};
        }
    endgroup

    function new(virtual ovf_if vif);
        this.vif = vif;
        cg_ovf = new();
    endfunction

    // dsu_overflow is a REGISTERED output (reg dsu_overflow, driven only
    // inside the clocked always block) -- must sample AFTER the commit
    // edge, same lesson learned (and fixed) during mac_unit verification.
    task sample_one(output bit dsu_overflow);
        @(posedge vif.clk);
        #1;
        dsu_overflow = vif.dsu_overflow;
        cg_ovf.sample();
    endtask
endclass


// -------------------------------------------------------------
// 8. SCOREBOARD
// -------------------------------------------------------------
class ovf_scoreboard;
    int pass_cnt = 0;
    int fail_cnt = 0;

    task check(string seq_name, int cycle_idx, bit [2:0] mac_overflow, bit sat_overflow,
               bit csr_clear_overflow, bit rst_n, bit actual_dsu_overflow, ovf_ref_model model);
        bit pred;
        pred = model.step(mac_overflow, sat_overflow, csr_clear_overflow, rst_n);

        if (actual_dsu_overflow === pred) begin
            pass_cnt++;
            $display("[PASS] seq=%-38s cyc=%0d mac_ovf=%03b sat=%0b clr=%0b rst_n=%0b -> dsu_overflow=%0b",
                      seq_name, cycle_idx, mac_overflow, sat_overflow, csr_clear_overflow, rst_n, actual_dsu_overflow);
        end else begin
            fail_cnt++;
            $display("[FAIL] seq=%-38s cyc=%0d mac_ovf=%03b sat=%0b clr=%0b rst_n=%0b -> got=%0b exp=%0b",
                      seq_name, cycle_idx, mac_overflow, sat_overflow, csr_clear_overflow, rst_n, actual_dsu_overflow, pred);
        end
    endtask
endclass


// -------------------------------------------------------------
// 9. ENVIRONMENT (sequential, per-sequence reset isolation)
// -------------------------------------------------------------
class ovf_env;
    virtual ovf_if vif;
    ovf_generator  gen;
    ovf_driver     drv;
    ovf_monitor    mon;
    ovf_scoreboard sb;

    function new(virtual ovf_if vif, int num_random_seqs = 15, int random_seq_len = 25);
        this.vif = vif;
        gen = new(num_random_seqs, random_seq_len);
        drv = new(vif);
        mon = new(vif);
        sb  = new();
    endfunction

    task run();
        ovf_ref_model model;
        int total_cycles = 0;

        gen.build();

        foreach (gen.seq_q[s]) begin
            bit rbo;
            drv.apply_cycle(3'b000, 1'b0, 1'b0, 1'b0); // isolate: real async reset pulse
            mon.sample_one(rbo);

            model = new();
            foreach (gen.seq_q[s][i]) begin
                ovf_cycle c = gen.seq_q[s][i];
                bit actual;
                drv.apply_cycle(c.mac_overflow, c.sat_overflow, c.csr_clear_overflow, c.rst_n);
                mon.sample_one(actual);
                sb.check(gen.seq_name[s], i, c.mac_overflow, c.sat_overflow, c.csr_clear_overflow,
                          c.rst_n, actual, model);
                total_cycles++;
            end
        end

        $display("\n================ OVERFLOW_FLAG UNIT TB SUMMARY ================");
        $display(" SEQUENCES=%0d  TOTAL_CYCLES=%0d  PASS=%0d  FAIL=%0d",
                  gen.seq_q.size(), total_cycles, sb.pass_cnt, sb.fail_cnt);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", mon.cg_ovf.get_coverage());
        if (sb.fail_cnt == 0)
            $display(" RESULT: ALL CHECKS PASSED (matches its own literal specification)");
        else
            $display(" RESULT: %0d CHECK(S) FAILED", sb.fail_cnt);
        $display(" NOTE: see FINDING1_clear_vs_set_same_cycle_race above -- overflow_flag matches");
        $display("       its own spec here; this is an architecture question about intended");
        $display("       clear-vs-set priority, not a defect against the written RTL.");
        $display("=================================================================\n");
    endtask
endclass


// -------------------------------------------------------------
// 10. TEST
// -------------------------------------------------------------
class ovf_test;
    ovf_env env;
    function new(virtual ovf_if vif, int num_random_seqs = 15, int random_seq_len = 25);
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

    ovf_if vif(clk);

    overflow_flag dut (
        .clk (clk), .rst_n (vif.rst_n),
        .mac_overflow (vif.mac_overflow), .sat_overflow (vif.sat_overflow),
        .csr_clear_overflow (vif.csr_clear_overflow), .dsu_overflow (vif.dsu_overflow)
    );

    ovf_test test;

    initial begin
        vif.rst_n = 1'b0;
        vif.mac_overflow = 3'b000; vif.sat_overflow = 1'b0; vif.csr_clear_overflow = 1'b0;
        repeat (3) @(posedge clk);

        test = new(vif, 15, 25);
        test.run();
        $finish;
    end
endmodule
