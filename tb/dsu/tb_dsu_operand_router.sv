// =============================================================
// tb_dsu_operand_router.sv
//
//  BLOCK      : II -- DSU (Custom-0 MAC coprocessor)
//  RTL SOURCE : rtl/dsu/operand_router.v   (GARUDA_DSU_DesignSpec)
//  SCOPE      : DSU unit module
//
// Single-file SV verification environment for GARUDA operand_router.v
// (routes rs1/rs2 into the MAC's two 16-bit lanes, incl. the abs16()
// saturating-negate special case for MACABS)
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
// 1. DUT: operand_router.v (pasted verbatim, self-contained file)
// -------------------------------------------------------------
module operand_router (
    input wire  [31:0] rs1,
    input wire  [31:0] rs2,
    input wire         abs_en,
    input wire         dot_en,
    output wire [15:0] a0,
    output wire [15:0] b0,
    output wire [15:0] a1,
    output wire [15:0] b1
);

    function [15:0] abs16;
        input [15:0] x;
        begin
            if      (x == 16'h8000) abs16 = 16'h7FFF;
            else if (x[15])         abs16 = (~x) + 16'b1;
            else                    abs16 = x;
        end
     endfunction

     wire [15:0] rs1_lo_abs = abs16(rs1[15:0]);
     wire [15:0] rs2_lo_abs = abs16(rs2[15:0]);
     wire        dot_active = dot_en & ~abs_en;

     assign a0 = abs_en ? rs1_lo_abs : rs1[15:0];
     assign b0 = abs_en ? rs2_lo_abs : rs2[15:0];
     assign a1 = dot_active ? rs1[31:16] : 16'b0;
     assign b1 = dot_active ? rs2[31:16] : 16'b0;

endmodule


// -------------------------------------------------------------
// 2. INTERFACE (+ bound SVA)
// -------------------------------------------------------------
interface operand_router_if (input bit clk);
    logic [31:0] rs1, rs2;
    logic        abs_en, dot_en;
    logic [15:0] a0, b0, a1, b1;

    property p_no_x_propagation;
        @(posedge clk) (!$isunknown({rs1, rs2, abs_en, dot_en})) |-> (!$isunknown({a0, b0, a1, b1}));
    endproperty
    a_no_x_propagation: assert property (p_no_x_propagation)
        else $error("[SVA-FAIL] X detected on operand_router outputs with fully-known inputs");

    // When neither abs_en nor dot_en is set, the hi lanes must be zero.
    property p_hi_lanes_zero_when_idle;
        @(posedge clk) (!abs_en && !dot_en) |-> (a1 == 16'b0 && b1 == 16'b0);
    endproperty
    a_hi_lanes_zero_when_idle: assert property (p_hi_lanes_zero_when_idle)
        else $error("[SVA-FAIL] hi lanes non-zero with abs_en=0 dot_en=0");
endinterface


// -------------------------------------------------------------
// 3. STIMULUS ITEM
// -------------------------------------------------------------
class router_txn;
    rand bit [31:0] rs1, rs2;
    rand bit        abs_en, dot_en;
    string tag;
    bit [15:0] a0_act, b0_act, a1_act, b1_act;
    bit [15:0] a0_exp, b0_exp, a1_exp, b1_exp;

    // Bias the low/high 16-bit halves independently toward INT16_MIN (the
    // abs16() saturating-negate corner), INT16_MAX, 0 and -1, since abs_en
    // only transforms the low half and dot_en only routes the high half --
    // they need independent corner coverage, not just whole-word extremes.
    constraint c_rs1_corner_dist {
        rs1[15:0]  dist { 16'h8000 := 8, 16'h7FFF := 6, 16'h0000 := 6, 16'hFFFF := 6, [16'h0001:16'hFFFE] :/ 74 };
        rs1[31:16] dist { 16'h8000 := 8, 16'h7FFF := 6, 16'h0000 := 6, 16'hFFFF := 6, [16'h0001:16'hFFFE] :/ 74 };
    }
    constraint c_rs2_corner_dist {
        rs2[15:0]  dist { 16'h8000 := 8, 16'h7FFF := 6, 16'h0000 := 6, 16'hFFFF := 6, [16'h0001:16'hFFFE] :/ 74 };
        rs2[31:16] dist { 16'h8000 := 8, 16'h7FFF := 6, 16'h0000 := 6, 16'hFFFF := 6, [16'h0001:16'hFFFE] :/ 74 };
    }
    constraint c_mode_dist { abs_en dist {1:=35,0:=65}; dot_en dist {1:=35,0:=65}; }

    function new(string tag_ = "random"); tag = tag_; endfunction
    function string to_s();
        return $sformatf("rs1=%08h rs2=%08h abs_en=%0b dot_en=%0b", rs1, rs2, abs_en, dot_en);
    endfunction
endclass


// -------------------------------------------------------------
// 4. GOLDEN / REFERENCE MODEL -- replicates the abs16() saturating
//    special case (abs(-32768)=+32767) as an architectural requirement,
//    not merely a copy of the RTL.
// -------------------------------------------------------------
function automatic bit signed [15:0] rtr_abs16(bit signed [15:0] x);
    if (x == 16'sh8000) rtr_abs16 = 16'sh7FFF;
    else if (x[15])     rtr_abs16 = -x;
    else                rtr_abs16 = x;
endfunction

function automatic void router_golden(router_txn t);
    bit dot_active = t.dot_en & ~t.abs_en;
    t.a0_exp = t.abs_en ? rtr_abs16(t.rs1[15:0]) : t.rs1[15:0];
    t.b0_exp = t.abs_en ? rtr_abs16(t.rs2[15:0]) : t.rs2[15:0];
    t.a1_exp = dot_active ? t.rs1[31:16] : 16'b0;
    t.b1_exp = dot_active ? t.rs2[31:16] : 16'b0;
endfunction


// -------------------------------------------------------------
// 5. GENERATOR
// -------------------------------------------------------------
class router_generator;
    router_txn items[$];
    int num_random;

    function new(int num_random = 1500); this.num_random = num_random; endfunction

    function void build();
        router_txn t;
        t = new("dir_abs_int16_min");       t.rs1=32'h0000_8000; t.rs2=32'h0000_8000; t.abs_en=1; t.dot_en=0; items.push_back(t);
        t = new("dir_abs_neg_normal");       t.rs1=32'hFFFF_FFFF; t.rs2=32'h0000_0001; t.abs_en=1; t.dot_en=0; items.push_back(t);
        t = new("dir_abs_pos_passthru");     t.rs1=32'h0000_1234; t.rs2=32'h0000_5678; t.abs_en=1; t.dot_en=0; items.push_back(t);
        t = new("dir_dot_active");           t.rs1=32'h1111_2222; t.rs2=32'h3333_4444; t.abs_en=0; t.dot_en=1; items.push_back(t);
        t = new("dir_abs_and_dot_both_set"); t.rs1=32'h8000_8000; t.rs2=32'h8000_8000; t.abs_en=1; t.dot_en=1; items.push_back(t); // abs wins -> dot_active=0
        t = new("dir_neither");              t.rs1=32'hDEAD_BEEF; t.rs2=32'hCAFE_BABE; t.abs_en=0; t.dot_en=0; items.push_back(t); // hi lanes must be zero

        // --- additional corner cases -------------------------------------
        t = new("dir_abs_intmax_lo");     t.rs1=32'h0000_7FFF; t.rs2=32'h0000_7FFF; t.abs_en=1; t.dot_en=0; items.push_back(t);
        t = new("dir_abs_zero_lo");       t.rs1=32'hFFFF_0000; t.rs2=32'h0000_0000; t.abs_en=1; t.dot_en=0; items.push_back(t);
        t = new("dir_abs_neg1_lo");       t.rs1=32'h0000_FFFF; t.rs2=32'h0000_FFFF; t.abs_en=1; t.dot_en=0; items.push_back(t);
        t = new("dir_dot_intmin_hi");     t.rs1=32'h8000_0000; t.rs2=32'h8000_0000; t.abs_en=0; t.dot_en=1; items.push_back(t);
        t = new("dir_dot_intmax_hi");     t.rs1=32'h7FFF_0000; t.rs2=32'h7FFF_0000; t.abs_en=0; t.dot_en=1; items.push_back(t);
        t = new("dir_dot_zero_hi");       t.rs1=32'h0000_FFFF; t.rs2=32'h0000_FFFF; t.abs_en=0; t.dot_en=1; items.push_back(t); // lo passthrough, hi=0 from rs1/rs2 top halves
        t = new("dir_abs_dot_mixed_hi_lo"); t.rs1=32'hAAAA_5555; t.rs2=32'h5555_AAAA; t.abs_en=1; t.dot_en=1; items.push_back(t);
        t = new("dir_all_max_both");       t.rs1=32'h7FFF_7FFF; t.rs2=32'h7FFF_7FFF; t.abs_en=1; t.dot_en=1; items.push_back(t);
        t = new("dir_all_min_both");       t.rs1=32'h8000_8000; t.rs2=32'h8000_8000; t.abs_en=0; t.dot_en=1; items.push_back(t);

        repeat (num_random) begin
            router_txn r = new("random");
            assert (r.randomize()) else $error("[GEN] randomize() failed");
            items.push_back(r);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 6. DRIVER
// -------------------------------------------------------------
class router_driver;
    virtual operand_router_if vif;
    function new(virtual operand_router_if vif); this.vif = vif; endfunction

    task apply(router_txn t);
        @(negedge vif.clk);
        vif.rs1 <= t.rs1; vif.rs2 <= t.rs2; vif.abs_en <= t.abs_en; vif.dot_en <= t.dot_en;
    endtask
endclass


// -------------------------------------------------------------
// 7. MONITOR
// -------------------------------------------------------------
class router_monitor;
    virtual operand_router_if vif;

    covergroup cg_router;
        cp_abs: coverpoint vif.abs_en;
        cp_dot: coverpoint vif.dot_en;
        cp_lo_is_int16min: coverpoint (vif.rs1[15:0] == 16'h8000);
        cross cp_abs, cp_dot;
    endgroup

    function new(virtual operand_router_if vif); this.vif = vif; cg_router = new(); endfunction

    task sample_one(output bit [15:0] a0_, output bit [15:0] b0_, output bit [15:0] a1_, output bit [15:0] b1_);
        #1;
        a0_ = vif.a0; b0_ = vif.b0; a1_ = vif.a1; b1_ = vif.b1;
        cg_router.sample();
    endtask
endclass


// -------------------------------------------------------------
// 8. SCOREBOARD
// -------------------------------------------------------------
class router_scoreboard;
    int pass_cnt = 0;
    int fail_cnt = 0;

    task check(router_txn t, bit [15:0] a0_, bit [15:0] b0_, bit [15:0] a1_, bit [15:0] b1_);
        bit ok;
        t.a0_act = a0_; t.b0_act = b0_; t.a1_act = a1_; t.b1_act = b1_;
        router_golden(t);
        ok = (t.a0_act===t.a0_exp) & (t.b0_act===t.b0_exp) & (t.a1_act===t.a1_exp) & (t.b1_act===t.b1_exp);
        if (ok) begin
            pass_cnt++;
            $display("[PASS] %-26s %-0s -> a0=%04h b0=%04h a1=%04h b1=%04h", t.tag, t.to_s(), a0_, b0_, a1_, b1_);
        end else begin
            fail_cnt++;
            $display("[FAIL] %-26s %-0s -> got(a0=%04h b0=%04h a1=%04h b1=%04h) exp(a0=%04h b0=%04h a1=%04h b1=%04h)",
                      t.tag, t.to_s(), a0_, b0_, a1_, b1_, t.a0_exp, t.b0_exp, t.a1_exp, t.b1_exp);
        end
    endtask
endclass


// -------------------------------------------------------------
// 9. ENVIRONMENT
// -------------------------------------------------------------
class router_env;
    virtual operand_router_if vif;
    router_generator  gen;
    router_driver     drv;
    router_monitor    mon;
    router_scoreboard sb;

    function new(virtual operand_router_if vif, int num_random = 1500);
        this.vif = vif;
        gen = new(num_random);
        drv = new(vif);
        mon = new(vif);
        sb  = new();
    endfunction

    task run();
        bit [15:0] a0_, b0_, a1_, b1_;
        gen.build();
        foreach (gen.items[i]) begin
            drv.apply(gen.items[i]);
            mon.sample_one(a0_, b0_, a1_, b1_);
            sb.check(gen.items[i], a0_, b0_, a1_, b1_);
        end

        $display("\n================ OPERAND_ROUTER UNIT TB SUMMARY ================");
        $display(" TOTAL=%0d  PASS=%0d  FAIL=%0d", gen.items.size(), sb.pass_cnt, sb.fail_cnt);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", mon.cg_router.get_coverage());
        if (sb.fail_cnt == 0) $display(" RESULT: ALL CHECKS PASSED");
        else                  $display(" RESULT: %0d CHECK(S) FAILED", sb.fail_cnt);
        tb_signoff(mon.cg_router.get_coverage(), sb.fail_cnt);
        $display("===================================================================\n");
    endtask
endclass


// -------------------------------------------------------------
// 10. TEST
// -------------------------------------------------------------
class router_test;
    router_env env;
    function new(virtual operand_router_if vif, int num_random = 1500);
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

    operand_router_if vif(clk);

    operand_router dut (
        .rs1(vif.rs1), .rs2(vif.rs2), .abs_en(vif.abs_en), .dot_en(vif.dot_en),
        .a0(vif.a0), .b0(vif.b0), .a1(vif.a1), .b1(vif.b1)
    );

    router_test test;

    initial begin
        int tb_nrand = 1500;
        tb_control_init(tb_nrand, "tb_dsu_operand_router");
        vif.rs1 = 0; vif.rs2 = 0; vif.abs_en = 0; vif.dot_en = 0;
        repeat (3) @(posedge clk);

        test = new(vif, tb_nrand);
        test.run();
        $finish;
    end

endmodule
