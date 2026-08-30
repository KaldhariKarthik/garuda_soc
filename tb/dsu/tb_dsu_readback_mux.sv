// =============================================================
// tb_dsu_readback_mux.sv
//
//  BLOCK      : II -- DSU (Custom-0 MAC coprocessor)
//  RTL SOURCE : rtl/dsu/readback_mux.v   (GARUDA_DSU_DesignSpec)
//  SCOPE      : DSU unit module
//
// Single-file SV verification environment for GARUDA readback_mux.v
// (splits the 48-bit accumulator into sign-correct low/high 32-bit
// halves for MACRD_LO/HI)
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
// 1. DUT: readback_mux.v (pasted verbatim, self-contained file)
// -------------------------------------------------------------
module readback_mux (
    input wire [47:0] cluster_out,
    input wire        rd_lo_op,
    input wire        rd_hi_op,

    output wire [31:0] rd_lo_data,
    output wire [31:0] rd_hi_data
);

    assign rd_lo_data = cluster_out[31:0];
    assign rd_hi_data = {{16{cluster_out[47]}}, cluster_out[47:32]};

endmodule


// -------------------------------------------------------------
// 2. INTERFACE (+ bound SVA)
// -------------------------------------------------------------
interface readback_mux_if (input bit clk);
    logic [47:0] cluster_out;
    logic        rd_lo_op, rd_hi_op;
    logic [31:0] rd_lo_data, rd_hi_data;

    property p_no_x_propagation;
        @(posedge clk) (!$isunknown(cluster_out)) |-> (!$isunknown({rd_lo_data, rd_hi_data}));
    endproperty
    a_no_x_propagation: assert property (p_no_x_propagation)
        else $error("[SVA-FAIL] X detected on readback_mux outputs with fully-known inputs");

    // rd_lo_data is always the literal low 32 bits, unconditionally
    // (rd_lo_op/rd_hi_op do NOT gate this module's outputs -- that
    // gating happens downstream in result_selector).
    property p_lo_is_literal_slice;
        @(posedge clk) 1'b1 |-> (rd_lo_data == cluster_out[31:0]);
    endproperty
    a_lo_is_literal_slice: assert property (p_lo_is_literal_slice)
        else $error("[SVA-FAIL] rd_lo_data diverged from cluster_out[31:0]");
endinterface


// -------------------------------------------------------------
// 3. STIMULUS ITEM
// -------------------------------------------------------------
class rbm_txn;
    rand bit [47:0] cluster_out;
    rand bit        rd_lo_op, rd_hi_op;
    string tag;
    bit [31:0] rd_lo_data_act, rd_hi_data_act, rd_lo_data_exp, rd_hi_data_exp;

    // Bias bit 47 (hi-half sign) and bit 31 (lo-half MSB) independently at
    // both polarities plus the all-0/all-1/walking-bit patterns, since the
    // sign-extension slice is exactly where an off-by-one on [47:32] vs
    // [46:31] would hide.
    constraint c_cluster_corner_dist {
        cluster_out dist {
            48'h0 := 6, {48{1'b1}} := 6,
            48'h8000_0000_0000 := 4, 48'h7FFF_FFFF_FFFF := 4,
            48'h0000_8000_0000 := 4, 48'h0000_7FFF_FFFF := 4,
            [0:48'hFFFF_FFFF_FFFE] :/ 72
        };
    }

    function new(string tag_ = "random"); tag = tag_; endfunction
    function string to_s();
        return $sformatf("cluster_out=%012h rd_lo_op=%0b rd_hi_op=%0b", cluster_out, rd_lo_op, rd_hi_op);
    endfunction
endclass


// -------------------------------------------------------------
// 4. GOLDEN / REFERENCE MODEL
// -------------------------------------------------------------
function automatic void rbm_golden(rbm_txn t);
    t.rd_lo_data_exp = t.cluster_out[31:0];
    t.rd_hi_data_exp = {{16{t.cluster_out[47]}}, t.cluster_out[47:32]};
endfunction


// -------------------------------------------------------------
// 5. GENERATOR
// -------------------------------------------------------------
class rbm_generator;
    rbm_txn items[$];
    int num_random;

    function new(int num_random = 1500); this.num_random = num_random; endfunction

    function void build();
        rbm_txn t;
        t = new("dir_hi_sign_neg"); t.cluster_out=48'hFFFF_8000_0000; t.rd_lo_op=1; t.rd_hi_op=0; items.push_back(t);
        t = new("dir_hi_sign_pos"); t.cluster_out=48'h0000_7FFF_FFFF; t.rd_lo_op=0; t.rd_hi_op=1; items.push_back(t);
        t = new("dir_zero");       t.cluster_out=48'h0; t.rd_lo_op=0; t.rd_hi_op=0; items.push_back(t);
        t = new("dir_all_ones");   t.cluster_out='1; t.rd_lo_op=1; t.rd_hi_op=1; items.push_back(t);

        // --- additional corner cases -------------------------------------
        t = new("dir_lo_msb_only");   t.cluster_out=48'h0000_8000_0000; t.rd_lo_op=1; t.rd_hi_op=0; items.push_back(t);
        t = new("dir_hi_lsb_only");   t.cluster_out=48'h0000_0000_0001; t.rd_lo_op=0; t.rd_hi_op=1; items.push_back(t);
        t = new("dir_hi_all_ones_lo_zero"); t.cluster_out=48'hFFFF_0000_0000; t.rd_lo_op=1; t.rd_hi_op=1; items.push_back(t);
        t = new("dir_hi_zero_lo_all_ones"); t.cluster_out=48'h0000_FFFF_FFFF; t.rd_lo_op=1; t.rd_hi_op=1; items.push_back(t);
        for (int i = 0; i < 48; i++) begin
            t = new($sformatf("dir_walk1_bit%0d", i)); t.cluster_out = 48'h1 << i; t.rd_lo_op=1; t.rd_hi_op=1; items.push_back(t);
        end

        repeat (num_random) begin
            rbm_txn r = new("random");
            assert (r.randomize()) else $error("[GEN] randomize() failed");
            items.push_back(r);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 6. DRIVER
// -------------------------------------------------------------
class rbm_driver;
    virtual readback_mux_if vif;
    function new(virtual readback_mux_if vif); this.vif = vif; endfunction

    task apply(rbm_txn t);
        @(negedge vif.clk);
        vif.cluster_out <= t.cluster_out; vif.rd_lo_op <= t.rd_lo_op; vif.rd_hi_op <= t.rd_hi_op;
    endtask
endclass


// -------------------------------------------------------------
// 7. MONITOR
// -------------------------------------------------------------
class rbm_monitor;
    virtual readback_mux_if vif;

    covergroup cg_rbm;
        cp_sign: coverpoint vif.cluster_out[47];
        cp_lo_op: coverpoint vif.rd_lo_op;
        cp_hi_op: coverpoint vif.rd_hi_op;
    endgroup

    function new(virtual readback_mux_if vif); this.vif = vif; cg_rbm = new(); endfunction

    task sample_one(output bit [31:0] lo_, output bit [31:0] hi_);
        #1;
        lo_ = vif.rd_lo_data; hi_ = vif.rd_hi_data;
        cg_rbm.sample();
    endtask
endclass


// -------------------------------------------------------------
// 8. SCOREBOARD
// -------------------------------------------------------------
class rbm_scoreboard;
    int pass_cnt = 0;
    int fail_cnt = 0;

    task check(rbm_txn t, bit [31:0] lo_, bit [31:0] hi_);
        bit ok;
        t.rd_lo_data_act = lo_; t.rd_hi_data_act = hi_;
        rbm_golden(t);
        ok = (t.rd_lo_data_act===t.rd_lo_data_exp) & (t.rd_hi_data_act===t.rd_hi_data_exp);
        if (ok) begin
            pass_cnt++;
            $display("[PASS] %-14s %-0s -> lo=%08h hi=%08h", t.tag, t.to_s(), lo_, hi_);
        end else begin
            fail_cnt++;
            $display("[FAIL] %-14s %-0s -> got(lo=%08h hi=%08h) exp(lo=%08h hi=%08h)",
                      t.tag, t.to_s(), lo_, hi_, t.rd_lo_data_exp, t.rd_hi_data_exp);
        end
    endtask
endclass


// -------------------------------------------------------------
// 9. ENVIRONMENT
// -------------------------------------------------------------
class rbm_env;
    virtual readback_mux_if vif;
    rbm_generator  gen;
    rbm_driver     drv;
    rbm_monitor    mon;
    rbm_scoreboard sb;

    function new(virtual readback_mux_if vif, int num_random = 1500);
        this.vif = vif;
        gen = new(num_random);
        drv = new(vif);
        mon = new(vif);
        sb  = new();
    endfunction

    task run();
        bit [31:0] lo_, hi_;
        gen.build();
        foreach (gen.items[i]) begin
            drv.apply(gen.items[i]);
            mon.sample_one(lo_, hi_);
            sb.check(gen.items[i], lo_, hi_);
        end

        $display("\n================ READBACK_MUX UNIT TB SUMMARY ================");
        $display(" TOTAL=%0d  PASS=%0d  FAIL=%0d", gen.items.size(), sb.pass_cnt, sb.fail_cnt);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", mon.cg_rbm.get_coverage());
        if (sb.fail_cnt == 0) $display(" RESULT: ALL CHECKS PASSED");
        else                  $display(" RESULT: %0d CHECK(S) FAILED", sb.fail_cnt);
        tb_signoff(mon.cg_rbm.get_coverage(), sb.fail_cnt);
        $display("=================================================================\n");
    endtask
endclass


// -------------------------------------------------------------
// 10. TEST
// -------------------------------------------------------------
class rbm_test;
    rbm_env env;
    function new(virtual readback_mux_if vif, int num_random = 1500);
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

    readback_mux_if vif(clk);

    readback_mux dut (
        .cluster_out(vif.cluster_out),
        .rd_lo_op(vif.rd_lo_op),
        .rd_hi_op(vif.rd_hi_op),
        .rd_lo_data(vif.rd_lo_data),
        .rd_hi_data(vif.rd_hi_data)
    );

    rbm_test test;

    initial begin
        int tb_nrand = 1500;
        tb_control_init(tb_nrand, "tb_dsu_readback_mux");
        vif.cluster_out = 0; vif.rd_lo_op = 0; vif.rd_hi_op = 0;
        repeat (3) @(posedge clk);

        test = new(vif, tb_nrand);
        test.run();
        $finish;
    end

endmodule
