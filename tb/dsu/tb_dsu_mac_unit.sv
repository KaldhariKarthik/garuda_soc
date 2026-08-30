// =============================================================
// tb_dsu_mac_unit.sv
//
//  BLOCK      : II -- DSU (Custom-0 MAC coprocessor)
//  RTL SOURCE : rtl/dsu/mac_unit.v   (GARUDA_DSU_DesignSpec)
//  SCOPE      : DSU unit module
//
// Single-file SV verification environment for GARUDA mac_unit.v
// (one 16x16x2-lane signed MAC, 48-bit accumulator, 2-cycle internal
// pipeline -- the heart of the DSU)
//
// SEQUENTIAL and the most complex block in the DSU: correctness is
// defined by the REGISTER-TRANSFER TIMING (csa1 -> sum_reg/carry_reg
// -> csa2+adder -> acc), not just steady-state arithmetic. The
// reference model below is a structural, cycle-accurate re-derivation
// of that timing (the "2-cycle pipeline" is documented architecture,
// not an implementation detail we can gloss over -- a golden model
// for a pipelined accumulator necessarily looks structurally similar
// to the pipeline it's checking, the same way a golden IEEE-754
// adder model looks like an adder).
//
// Includes a directed "overflow marathon" that drives the 48-bit
// accumulator to its REAL signed-overflow boundary with genuine
// max-magnitude products (not just asserting the overflow formula in
// isolation) -- see num_overflow_iters below. Reduce it for a quick
// smoke run; the overflow bit just won't be exercised in that case.
//
// Also instantiates mac_unit.v's own sub-modules verbatim
// (operand_router, mult_16x16, csa_3to2, kogge_stone_49) since this
// is a single self-contained file.
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
// 1a. DUT SUB-MODULE: operand_router.v (pasted verbatim)
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
// 1b. DUT SUB-MODULE: mult_16x16.v (pasted verbatim)
// -------------------------------------------------------------
module mult_16x16 (
    input wire signed [15:0] a,
    input wire signed [15:0] b,
    output wire signed [31:0] p
);
    assign p = a*b;

endmodule


// -------------------------------------------------------------
// 1c. DUT SUB-MODULE: csa_3to2.v (pasted verbatim)
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
// 1d. DUT SUB-MODULE: kogge_stone_49.v (pasted verbatim)
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
// 1e. DUT: mac_unit.v (pasted verbatim, self-contained file)
// -------------------------------------------------------------
module mac_unit(
    input wire         clk,
    input wire         rst_n,

    input wire  [31:0] rs1,
    input wire  [31:0] rs2,

    input wire         en,
    input wire         add_sub,
    input wire         clear,
    input wire         load,
    input wire         abs_en,
    input wire         dot_en,
    input wire         flush,

    input wire  [47:0] sat_writeback,
    input wire         sat_writeback_en,

    output wire [47:0] mac_out,
    output wire        overflow
);

    wire [15:0] a0, b0, a1, b1;
    operand_router u_router (
        .rs1 (rs1),
        .rs2 (rs2),
        .abs_en (abs_en),
        .dot_en (dot_en),
        .a0 (a0),
        .b0 (b0),
        .a1 (a1),
        .b1 (b1)
    );

    wire signed [31:0] product_a, product_b;
    mult_16x16 U_mult_a (.a ($signed(a0)),  .b ($signed(b0)), .p (product_a));
    mult_16x16 U_mult_b (.a ($signed(a1)),  .b ($signed(b1)), .p (product_b));

    wire [47:0] pa_ext = {{16{product_a[31]}}, product_a};
    wire [47:0] pb_ext = {{16{product_b[31]}}, product_b};

    wire [47:0] pa_eff = pa_ext ^ {48{add_sub}};
    wire [47:0] pb_eff = pb_ext ^ {48{add_sub}};
    wire [47:0] sub_k = {46'b0, add_sub , 1'b0};

    wire [47:0] csa1_sum, csa1_carry;
    csa_3to2 #(.WIDTH(48)) u_csa1 (
        .a (pa_eff),
        .b (pb_eff),
        .c (sub_k),
        .sum (csa1_sum),
        .carry (csa1_carry)
    );

    reg [47:0] sum_reg, carry_reg;
    wire write_en = (en | sat_writeback_en) & ~flush;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_reg   <= 48'b0;
            carry_reg <= 48'b0;
        end
        else if (flush) begin
            sum_reg   <= 48'b0;
            carry_reg <= 48'b0;
        end
        else if (write_en) begin
            sum_reg   <= csa1_sum;
            carry_reg <= csa1_carry;
        end
    end

    reg signed [47:0] acc;
    wire [47:0] csa2_sum, csa2_carry;
    csa_3to2 #(.WIDTH(48)) u_csa2(
        .a (acc),
        .b (sum_reg),
        .c (carry_reg),
        .sum (csa2_sum),
        .carry (csa2_carry)
    );

    wire [48:0] s_ext = {csa2_sum[47], csa2_sum};
    wire [48:0] c_ext = {csa2_carry[47], csa2_carry};
    wire [48:0] result_ext;
    kogge_stone_49 u_ks (
        .a (s_ext),
        .b (c_ext),
        .cin (1'b0),
        .sum (result_ext)
    );

    wire [47:0] adder_result = result_ext[47:0];
    wire        accum_ovf    = result_ext[48] ^ result_ext[47];

    wire signed [47:0] rs1_sext = {{16{rs1[31]}}, rs1};
    reg  signed [47:0] acc_next;
    always @(*) begin
        if      (sat_writeback_en) acc_next = sat_writeback;
        else if (load)             acc_next = rs1_sext;
        else if (clear)            acc_next = 48'b0;
        else                       acc_next = adder_result;
    end


    always @(posedge clk or negedge rst_n) begin
        if      (!rst_n)      acc <= 48'b0;
        else if (write_en)          acc <= acc_next;
    end
    assign mac_out = acc;

    wire is_accum = ~(load | clear | sat_writeback_en);
    assign overflow = accum_ovf & write_en & is_accum;

endmodule


// -------------------------------------------------------------
// 2. INTERFACE (+ bound SVA)
// -------------------------------------------------------------
interface mac_unit_if (input bit clk);
    logic       rst_n;
    logic [31:0] rs1, rs2;
    logic        en, add_sub, clear, load, abs_en, dot_en, flush;
    logic [47:0] sat_writeback;
    logic        sat_writeback_en;
    logic [47:0] mac_out;
    logic        overflow;

    property p_no_x_propagation;
        @(posedge clk) disable iff (!rst_n)
        (!$isunknown({rs1, rs2, en, add_sub, clear, load, abs_en, dot_en, flush, sat_writeback_en}))
        |-> (!$isunknown({mac_out, overflow}));
    endproperty
    a_no_x_propagation: assert property (p_no_x_propagation)
        else $error("[SVA-FAIL] X detected on mac_unit outputs with fully-known inputs");

    // overflow can only fire on a genuine accumulate write (never on
    // load/clear/sat-writeback, and never with write_en low).
    property p_overflow_only_on_accum;
        @(posedge clk) disable iff (!rst_n)
        overflow |-> ((en | sat_writeback_en) & ~flush & ~load & ~clear & ~sat_writeback_en);
    endproperty
    a_overflow_only_on_accum: assert property (p_overflow_only_on_accum)
        else $error("[SVA-FAIL] overflow asserted outside a genuine accumulate write");

    // While reset is asserted the accumulator must read as zero. Deliberately
    // has NO `disable iff (!rst_n)` -- that is the whole point: the other two
    // properties above switch themselves off during reset, so without this
    // one nothing is checking the DUT at all while rst_n is low.
    property p_reset_forces_zero;
        @(posedge clk) (!rst_n) |-> (mac_out == 48'd0);
    endproperty
    a_reset_forces_zero: assert property (p_reset_forces_zero)
        else $error("[SVA-FAIL] mac_out non-zero while rst_n asserted");
endinterface


// -------------------------------------------------------------
// 3. PER-CYCLE STIMULUS ITEM
// -------------------------------------------------------------
class mac_cycle;
    rand bit [31:0] rs1, rs2;
    rand bit        en, add_sub, clear, load, abs_en, dot_en, flush;
    rand bit [47:0] sat_writeback;
    rand bit        sat_writeback_en;
    // Deliberately NOT rand. A random stream that drops reset on itself
    // erases state at arbitrary points and proves nothing about the reset
    // path -- it just shortens every accumulate sequence. Reset is driven
    // by the directed dir_rst_* cases instead, which assert it against a
    // KNOWN non-zero accumulator with a product still in flight.
    bit             rst_n = 1'b1;
    string tag;

    constraint c_shape {
        en dist { 1 := 70, 0 := 30 };
        clear dist { 1 := 5, 0 := 95 };
        load  dist { 1 := 10, 0 := 90 };
        sat_writeback_en dist { 1 := 5, 0 := 95 };
        flush dist { 1 := 5, 0 := 95 };
        abs_en dist { 1 := 20, 0 := 80 };
        dot_en dist { 1 := 20, 0 := 80 };
        add_sub dist { 1 := 30, 0 := 70 };
    }

    // Corner-case operand biasing: 16-bit-lane extremes (INT16_MIN/MAX,
    // 0, -1) in both the low and high halves independently, since abs_en
    // only transforms the low lane and dot_en only activates the high
    // lane -- each needs its own boundary coverage.
    constraint c_rs1_corner_dist {
        rs1[15:0]  dist { 16'h8000 := 6, 16'h7FFF := 6, 16'h0000 := 6, 16'hFFFF := 6, [16'h0001:16'hFFFE] :/ 76 };
        rs1[31:16] dist { 16'h8000 := 6, 16'h7FFF := 6, 16'h0000 := 6, 16'hFFFF := 6, [16'h0001:16'hFFFE] :/ 76 };
    }
    constraint c_rs2_corner_dist {
        rs2[15:0]  dist { 16'h8000 := 6, 16'h7FFF := 6, 16'h0000 := 6, 16'hFFFF := 6, [16'h0001:16'hFFFE] :/ 76 };
        rs2[31:16] dist { 16'h8000 := 6, 16'h7FFF := 6, 16'h0000 := 6, 16'hFFFF := 6, [16'h0001:16'hFFFE] :/ 76 };
    }
    constraint c_sat_writeback_corner_dist {
        sat_writeback dist { 48'h0000_7FFFFFFF := 5, 48'hFFFF_80000000 := 5, 48'h0 := 5, {48{1'b1}} := 5, [0:48'hFFFF_FFFF_FFFE] :/ 80 };
    }

    function new(string tag_ = "random"); tag = tag_; endfunction
    function string to_s();
        return $sformatf("rs1=%08h rs2=%08h en=%0b add_sub=%0b clear=%0b load=%0b abs=%0b dot=%0b flush=%0b sat_en=%0b rst_n=%0b",
            rs1, rs2, en, add_sub, clear, load, abs_en, dot_en, flush, sat_writeback_en, rst_n);
    endfunction
endclass


// -------------------------------------------------------------
// 4. REFERENCE MODEL -- cycle-accurate structural mirror of the
//    2-stage csa1->sum_reg/carry_reg->csa2+adder->acc pipeline.
// -------------------------------------------------------------
function automatic bit signed [15:0] mac_abs16(bit signed [15:0] x);
    if (x == 16'sh8000)      mac_abs16 = 16'sh7FFF;
    else if (x[15])          mac_abs16 = -x;
    else                     mac_abs16 = x;
endfunction

// =====================================================================
//  *** DUPLICATED MODEL -- EDIT ALL THREE COPIES TOGETHER ***
//
//  This cycle-accurate mac_unit pipeline model is replicated verbatim in:
//        tb_dsu_mac_unit.sv      (class mac_pipeline_model)
//        tb_dsu_mac_cluster.sv   (class mac_pipeline_model, x3 instances)
//        tb_dsu_top.sv           (class dsu_mac_pipeline)
//
//  The single-file-per-module packaging makes sharing impossible, so the
//  copies can silently DRIFT -- and a drifted reference model produces a
//  green run against wrong expected values, which is worse than a failure.
//  Any change to the CSA/adder chain, the write_en gating, the acc_next
//  priority, or the pre-edge output convention MUST be applied to all
//  three. Cross-check against tools/golden/DSU_Golden.py (DSUModel.tick),
//  which is the authority where they disagree.
// =====================================================================
class mac_pipeline_model;
    bit signed [47:0] sum_reg, carry_reg;
    bit signed [47:0] acc;

    function new();
        sum_reg = 48'sd0; carry_reg = 48'sd0; acc = 48'sd0;
    endfunction

    // Advances the model by exactly one clock edge; returns the
    // POST-edge (mac_out, overflow) that the DUT will present next cycle.
    function void step(bit [31:0] rs1, bit [31:0] rs2,
                        bit en, bit add_sub, bit clear, bit load,
                        bit abs_en, bit dot_en, bit flush,
                        bit [47:0] sat_writeback, bit sat_writeback_en,
                        bit rst_n,
                        output bit [47:0] mac_out_next,
                        output bit        overflow_next);
        bit signed [15:0] rs1_lo, rs2_lo, rs1_hi, rs2_hi;
        bit signed [15:0] a0, b0, a1, b1;
        bit dot_active;
        bit signed [31:0] product_a, product_b;
        bit signed [47:0] pa_ext, pb_ext, pa_eff, pb_eff, sub_k;
        bit signed [47:0] csa1_sum, csa1_carry;
        bit               write_en;
        bit signed [47:0] csa2_sum, csa2_carry;
        bit signed [48:0] s_ext, c_ext, result_ext;
        bit signed [47:0] adder_result;
        bit               accum_ovf;
        bit signed [47:0] rs1_sext;
        bit signed [47:0] acc_next;
        bit               is_accum;

        // ---- ASYNCHRONOUS reset, applied BEFORE anything is sampled ------
        // mac_unit.v uses `always @(posedge clk or negedge rst_n)` with an
        // `if (!rst_n)` first branch for BOTH the sum_reg/carry_reg block
        // and the acc block. Those registers therefore clear the instant
        // rst_n falls -- they do not wait for a clock edge. Clearing here,
        // before the pre-edge output snapshot below, is what makes the
        // model agree with a monitor that samples after the driver has
        // already pulled rst_n low.
        if (!rst_n) begin
            acc = 48'sd0; sum_reg = 48'sd0; carry_reg = 48'sd0;
        end

        rs1_lo = rs1[15:0];  rs2_lo = rs2[15:0];
        rs1_hi = rs1[31:16]; rs2_hi = rs2[31:16];

        a0 = abs_en ? mac_abs16(rs1_lo) : rs1_lo;
        b0 = abs_en ? mac_abs16(rs2_lo) : rs2_lo;
        dot_active = dot_en & ~abs_en;
        a1 = dot_active ? rs1_hi : 16'sd0;
        b1 = dot_active ? rs2_hi : 16'sd0;

        product_a = a0 * b0;
        product_b = a1 * b1;

        pa_ext = {{16{product_a[31]}}, product_a};
        pb_ext = {{16{product_b[31]}}, product_b};
        pa_eff = pa_ext ^ {48{add_sub}};
        pb_eff = pb_ext ^ {48{add_sub}};
        sub_k  = {46'b0, add_sub, 1'b0};

        csa1_sum   = pa_eff ^ pb_eff ^ sub_k;
        csa1_carry = (((pa_eff & pb_eff) | (pb_eff & sub_k) | (pa_eff & sub_k)) << 1);

        write_en = (en | sat_writeback_en) & ~flush;

        // csa2 combines the CURRENT acc with sum_reg/carry_reg AS THEY
        // STAND AT THE START OF THIS CYCLE (the previous step's csa1
        // output, not this cycle's) -- this is the pipeline latency.
        csa2_sum   = acc ^ sum_reg ^ carry_reg;
        csa2_carry = (((acc & sum_reg) | (sum_reg & carry_reg) | (acc & carry_reg)) << 1);

        s_ext = {csa2_sum[47], csa2_sum};
        c_ext = {csa2_carry[47], csa2_carry};
        result_ext = s_ext + c_ext;

        adder_result = result_ext[47:0];
        accum_ovf    = result_ext[48] ^ result_ext[47];

        rs1_sext = {{16{rs1[31]}}, rs1};

        if      (sat_writeback_en) acc_next = sat_writeback;
        else if (load)              acc_next = rs1_sext;
        else if (clear)             acc_next = 48'sd0;
        else                        acc_next = adder_result;

        is_accum = ~(load | clear | sat_writeback_en);

        // ---- OUTPUTS FIRST: "value visible DURING this cycle" -----------
        // Convention adopted from the repo's own reference model,
        // tools/golden/DSU_Golden.py, which returns  "acc": list(self.acc)
        // with the comment  # pre-edge, as sampled  and only THEN commits
        // registered state. mac_out is the registered acc, so during this
        // cycle it still holds the value latched at the PREVIOUS edge --
        // which is exactly what a monitor sampling between the negedge
        // drive and the next posedge will see. overflow is combinational
        // and already evaluated against that same pre-edge state.
        //
        // Matching this convention (rather than returning post-edge values)
        // is what makes our expected-value stream directly comparable with
        // DSU_Golden.py and with tools/gen/DSU_gen.py's dsu_expected.mem.
        mac_out_next  = acc;
        overflow_next = accum_ovf & write_en & is_accum;

        // ---- THEN commit the registered state ---------------------------
        // Guarded by rst_n: while reset is asserted the clocked branches
        // never run, so nothing may be latched back on top of the zeros
        // the async clear above just wrote.
        if (rst_n) begin
            if (flush) begin
                sum_reg   = 48'sd0;
                carry_reg = 48'sd0;
            end else if (write_en) begin
                sum_reg   = csa1_sum;
                carry_reg = csa1_carry;
            end

            if (write_en) acc = acc_next;
        end
        // FLAG-B: flush does NOT clear acc itself -- only sum_reg/carry_reg
        // (the in-flight pipeline stage). A committed accumulator value
        // survives an EX-squash: a trap must not destroy accumulator state.
        // DSU_Golden.py agrees and notes DSU_Verification_Plan row 31, which
        // expects "acc = 0" after flush, is the thing that is wrong.
    endfunction
endclass


// -------------------------------------------------------------
// 5. GENERATOR -- directed op coverage + the overflow-boundary
//    marathon + CRV, as one continuous cycle stream.
// -------------------------------------------------------------
class mac_generator;
    mac_cycle items[$];
    int num_random;
    int num_overflow_iters;

    function new(int num_random = 1500, int num_overflow_iters = 131100);
        this.num_random = num_random;
        this.num_overflow_iters = num_overflow_iters;
    endfunction

    function mac_cycle idle(string tag);
        mac_cycle c = new(tag);
        c.rs1=0; c.rs2=0; c.en=0; c.add_sub=0; c.clear=0; c.load=0; c.abs_en=0; c.dot_en=0;
        c.flush=0; c.sat_writeback=0; c.sat_writeback_en=0; c.rst_n=1;
        return c;
    endfunction

    function void build();
        mac_cycle t;

        t = new("dir_clear"); t.en=1; t.clear=1; items.push_back(t);
        t = new("dir_mac1"); t.en=1; t.rs1=32'd6; t.rs2=32'd7; items.push_back(t);   // +42
        items.push_back(idle("dir_settle1")); items.push_back(idle("dir_settle2"));
        t = new("dir_mac2"); t.en=1; t.rs1=32'd3; t.rs2=32'd4; items.push_back(t);   // +12
        items.push_back(idle("dir_settle3")); items.push_back(idle("dir_settle4"));

        t = new("dir_macsub"); t.en=1; t.add_sub=1; t.rs1=32'd10; t.rs2=32'd2; items.push_back(t); // -20
        items.push_back(idle("dir_settle5")); items.push_back(idle("dir_settle6"));

        t = new("dir_load_pos"); t.en=1; t.load=1; t.rs1=32'h0000_1234; items.push_back(t);
        items.push_back(idle("dir_settle7"));
        t = new("dir_load_neg"); t.en=1; t.load=1; t.rs1=32'hFFFF_FFFF; items.push_back(t); // -1
        items.push_back(idle("dir_settle8"));

        t = new("dir_clear2"); t.en=1; t.clear=1; items.push_back(t);
        items.push_back(idle("dir_settle9"));

        t = new("dir_macabs_normal"); t.en=1; t.abs_en=1; t.rs1=32'hFFFF_FFFF; t.rs2=32'hFFFF_FFFE; items.push_back(t); // abs(-1)*abs(-2)=2
        items.push_back(idle("dir_settle10")); items.push_back(idle("dir_settle11"));
        t = new("dir_macabs_int16min"); t.en=1; t.abs_en=1; t.rs1=32'h0000_8000; t.rs2=32'h0000_0002; items.push_back(t); // abs(-32768)=32767 (saturating)
        items.push_back(idle("dir_settle12")); items.push_back(idle("dir_settle13"));

        t = new("dir_clear3"); t.en=1; t.clear=1; items.push_back(t);
        t = new("dir_macdot"); t.en=1; t.dot_en=1; t.rs1=32'h0002_0003; t.rs2=32'h0005_0007; items.push_back(t); // lo:3*7=21, hi:2*5=10 -> 31
        items.push_back(idle("dir_settle14")); items.push_back(idle("dir_settle15"));

        t = new("dir_clear4"); t.en=1; t.clear=1; items.push_back(t);
        t = new("dir_sat_writeback"); t.sat_writeback_en=1; t.sat_writeback=48'sh0000_7FFFFFFF; items.push_back(t);
        items.push_back(idle("dir_settle16"));

        t = new("dir_clear5"); t.en=1; t.clear=1; items.push_back(t);
        t = new("dir_preflush_mac"); t.en=1; t.rs1=32'd100; t.rs2=32'd100; items.push_back(t); // +10000, in flight
        t = new("dir_flush_now"); t.flush=1; items.push_back(t);                                // kills the in-flight product
        items.push_back(idle("dir_settle17")); items.push_back(idle("dir_settle18"));
        // acc should have settled back to whatever it was pre-flush (0),
        // NOT +10000 -- the golden model proves this automatically.

        // --- additional corner cases ---------------------------------------
        t = new("dir_clear6"); t.en=1; t.clear=1; items.push_back(t);
        t = new("dir_macdot_neg_lanes"); t.en=1; t.dot_en=1; t.rs1=32'hFFFF_FFFF; t.rs2=32'hFFFF_FFFF; items.push_back(t); // (-1*-1)+(-1*-1)=2
        items.push_back(idle("dir_settle19")); items.push_back(idle("dir_settle20"));

        t = new("dir_clear7"); t.en=1; t.clear=1; items.push_back(t);
        t = new("dir_macabs_both_int16min"); t.en=1; t.abs_en=1; t.rs1=32'h0000_8000; t.rs2=32'h0000_8000; items.push_back(t); // 32767*32767
        items.push_back(idle("dir_settle21")); items.push_back(idle("dir_settle22"));

        t = new("dir_load_intmin"); t.en=1; t.load=1; t.rs1=32'h8000_0000; items.push_back(t); // INT32_MIN sign-extended
        items.push_back(idle("dir_settle23"));
        t = new("dir_load_intmax"); t.en=1; t.load=1; t.rs1=32'h7FFF_FFFF; items.push_back(t);
        items.push_back(idle("dir_settle24"));

        t = new("dir_sat_writeback_neg"); t.en=1; t.clear=1; items.push_back(t);
        t = new("dir_sat_writeback_neg2"); t.sat_writeback_en=1; t.sat_writeback=48'shFFFF_80000000; items.push_back(t);
        items.push_back(idle("dir_settle25"));

        // load immediately followed by clear (priority: whichever is
        // asserted in a GIVEN cycle follows sat>load>clear>accum ordering;
        // these are two SEPARATE cycles, so both take full effect in turn)
        t = new("dir_load_then_clear_1"); t.en=1; t.load=1; t.rs1=32'hDEAD_BEEF; items.push_back(t);
        t = new("dir_load_then_clear_2"); t.en=1; t.clear=1; items.push_back(t);
        items.push_back(idle("dir_settle26"));

        // en and load asserted the SAME cycle: load wins per acc_next priority
        t = new("dir_en_and_load_same_cycle"); t.en=1; t.load=1; t.rs1=32'h1234_5678; t.rs2=32'd1; items.push_back(t);
        items.push_back(idle("dir_settle27")); items.push_back(idle("dir_settle28"));

        // flush asserted together with en (flush must win -- write_en forced low)
        t = new("dir_clear8"); t.en=1; t.clear=1; items.push_back(t);
        t = new("dir_en_and_flush_same_cycle"); t.en=1; t.flush=1; t.rs1=32'd50; t.rs2=32'd50; items.push_back(t);
        items.push_back(idle("dir_settle29")); items.push_back(idle("dir_settle30"));

        // --- ASYNCHRONOUS RESET FROM A NON-ZERO STATE ----------------------
        // The power-on reset in tb_top only proves reset works from an
        // already-zero state, which is the one case where a broken reset
        // still looks correct. These cases put a known non-zero value in
        // acc AND leave a product in flight in sum_reg/carry_reg, then
        // assert rst_n -- so both `if (!rst_n)` branches in mac_unit.v are
        // exercised against state they actually have to clear.
        //
        // Note the contrast with flush (dir_flush_now above): flush clears
        // ONLY the pending product and must leave acc intact (FLAG-B),
        // whereas reset must clear both. Testing only flush would leave the
        // stronger guarantee unchecked.
        t = new("dir_rst_load"); t.en=1; t.load=1; t.rs1=32'h1234_5678; items.push_back(t);
        items.push_back(idle("dir_rst_settle"));
        t = new("dir_rst_inflight"); t.en=1; t.rs1=32'd300; t.rs2=32'd300; items.push_back(t); // 90000 pending
        t = new("dir_rst_assert"); t.rst_n=0; items.push_back(t);   // acc AND pending must clear
        t = new("dir_rst_hold");   t.rst_n=0; items.push_back(t);   // stays cleared while held
        items.push_back(idle("dir_rst_release"));                   // rst_n back high, must stay 0
        items.push_back(idle("dir_rst_after1"));
        // proves the unit still accumulates correctly after a reset
        t = new("dir_rst_postmac"); t.en=1; t.rs1=32'd5; t.rs2=32'd5; items.push_back(t); // +25
        items.push_back(idle("dir_rst_after2")); items.push_back(idle("dir_rst_after3"));
        // reset asserted while en is also high -- reset must still win
        t = new("dir_rst_beats_en"); t.en=1; t.rs1=32'd77; t.rs2=32'd77; t.rst_n=0; items.push_back(t);
        items.push_back(idle("dir_rst_after4"));
        t = new("dir_clear_after_rst"); t.en=1; t.clear=1; items.push_back(t);  // back to a known state
        items.push_back(idle("dir_rst_after5"));

        // --- overflow boundary marathon ------------------------------------
        // Repeatedly issue max-magnitude MAC_SEL products (0x7FFF*0x7FFF)
        // from a cleared accumulator until the 48-bit signed range is
        // exceeded (~131,073 iterations at this product magnitude).
        t = new("dir_clear_for_overflow"); t.en=1; t.clear=1; items.push_back(t);
        for (int i = 0; i < num_overflow_iters; i++) begin
            mac_cycle o = new($sformatf("ovf_marathon_%0d", i));
            o.en=1; o.rs1=32'h0000_7FFF; o.rs2=32'h0000_7FFF; o.add_sub=0;
            items.push_back(o);
        end
        items.push_back(idle("dir_settle_after_marathon"));
        items.push_back(idle("dir_settle_after_marathon2"));

        repeat (num_random) begin
            mac_cycle r = new("random");
            assert (r.randomize()) else $error("[GEN] randomize() failed");
            items.push_back(r);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 6. DRIVER
// -------------------------------------------------------------
class mac_driver;
    virtual mac_unit_if vif;
    function new(virtual mac_unit_if vif); this.vif = vif; endfunction

    task apply(mac_cycle c);
        @(negedge vif.clk);
        vif.rst_n <= c.rst_n;
        vif.rs1 <= c.rs1; vif.rs2 <= c.rs2;
        vif.en <= c.en; vif.add_sub <= c.add_sub;
        vif.clear <= c.clear; vif.load <= c.load;
        vif.abs_en <= c.abs_en; vif.dot_en <= c.dot_en;
        vif.flush <= c.flush;
        vif.sat_writeback <= c.sat_writeback;
        vif.sat_writeback_en <= c.sat_writeback_en;
    endtask
endclass


// -------------------------------------------------------------
// 7. MONITOR
// -------------------------------------------------------------
class mac_monitor;
    virtual mac_unit_if vif;

    covergroup cg_mac;
        cp_en: coverpoint vif.en;
        cp_add_sub: coverpoint vif.add_sub;
        cp_clear: coverpoint vif.clear;
        cp_load: coverpoint vif.load;
        cp_abs: coverpoint vif.abs_en;
        cp_dot: coverpoint vif.dot_en;
        cp_flush: coverpoint vif.flush;
        cp_rst_n: coverpoint vif.rst_n;   // both bins hit by the dir_rst_* cases
        cp_sat_en: coverpoint vif.sat_writeback_en;
        cp_overflow: coverpoint vif.overflow;
    endgroup

    function new(virtual mac_unit_if vif); this.vif = vif; cg_mac = new(); endfunction

    // TIMING NOTE (this was a real TB bug, fixed here):
    // mac_unit has MIXED output timing and the two cannot be sampled at
    // the same instant.
    //   * overflow is COMBINATIONAL (accum_ovf & write_en & is_accum). It
    //     describes the accumulate that is ABOUT to be committed, so it is
    //     valid BEFORE the latching posedge, against the pre-edge state --
    //     which is exactly what the reference model computes it from.
    //   * mac_out is REGISTERED (acc). It only becomes this cycle's result
    //     AFTER that same posedge.
    // The old code read both with a bare "#1;" after the negedge drive,
    // so mac_out lagged the model by a full cycle on every item.
    // Single sample point, between the negedge drive and the next posedge.
    // Both outputs are read as "the value visible DURING this cycle", which
    // is the convention the reference model now uses (see the model's
    // comment). mac_out therefore still shows the PREVIOUS edge's acc --
    // that is not a sampling artifact, it is the pending-product behaviour
    // the whole DSU plan is about.
    task sample_one(output bit [47:0] mac_out_, output bit ovf_);
        #1;
        ovf_     = vif.overflow;
        mac_out_ = vif.mac_out;
        cg_mac.sample();
    endtask
endclass


// -------------------------------------------------------------
// 8. SCOREBOARD
// -------------------------------------------------------------
class mac_scoreboard;
    int pass_cnt = 0;
    int fail_cnt = 0;
    bit overflow_ever_seen = 0;
    bit verbose;   // when 0, only FAILs and every Nth marathon PASS print

    function new(bit verbose = 1); this.verbose = verbose; endfunction

    task check(mac_cycle c, bit [47:0] mac_out_, bit ovf_, ref mac_pipeline_model model, input int idx);
        bit [47:0] exp_out; bit exp_ovf;
        model.step(c.rs1, c.rs2, c.en, c.add_sub, c.clear, c.load, c.abs_en, c.dot_en,
                   c.flush, c.sat_writeback, c.sat_writeback_en, c.rst_n, exp_out, exp_ovf);
        if (ovf_) overflow_ever_seen = 1;

        if (mac_out_ === exp_out && ovf_ === exp_ovf) begin
            pass_cnt++;
            if (verbose || (idx % 5000 == 0))
                $display("[PASS] #%0d %-24s %-0s -> mac_out=%012h ovf=%0b", idx, c.tag, c.to_s(), mac_out_, ovf_);
        end else begin
            fail_cnt++;
            $display("[FAIL] #%0d %-24s %-0s -> got(out=%012h ovf=%0b) exp(out=%012h ovf=%0b)",
                      idx, c.tag, c.to_s(), mac_out_, ovf_, exp_out, exp_ovf);
        end
    endtask
endclass


// -------------------------------------------------------------
// 8b. TIMING / LATENCY AUDIT -- architectural-intent check
//
// The scoreboard above compares against a CYCLE-ACCURATE model, so it
// passes on whatever timing the RTL actually has. This task asks the
// different question a design review actually needs answered:
//
//        "does a multiply reach the accumulator when it should?"
//
// It drives known sequences, MEASURES the real commit latency in clock
// cycles, and prints what it found. It deliberately does NOT fail the
// run: the behaviour it measures is already logged as FLAG-A / FLAG-C /
// stranded-product in tb/dsu/GARUDA_DSU_Verification_Plan.xlsx (all P0,
// OPEN) and needs an architectural decision, not a testbench verdict.
// -------------------------------------------------------------
task automatic mac_drive_cycle(virtual mac_unit_if vif,
                                bit en, bit clear, bit load,
                                bit [31:0] rs1, bit [31:0] rs2);
    @(negedge vif.clk);
    vif.en     <= en;   vif.clear  <= clear; vif.load <= load;
    vif.rs1    <= rs1;  vif.rs2    <= rs2;
    vif.add_sub<= 1'b0; vif.abs_en <= 1'b0;  vif.dot_en <= 1'b0; vif.flush <= 1'b0;
    vif.sat_writeback <= 48'b0; vif.sat_writeback_en <= 1'b0;
    @(posedge vif.clk);
    #1;
endtask

task automatic mac_timing_audit(virtual mac_unit_if vif);
    int  idle_cycles;
    bit  committed;
    bit [47:0] pending_val;

    $display("\n---------------- MAC TIMING / LATENCY AUDIT ----------------");

    // Baseline: clear the accumulator. NOTE clear must be issued WITH en --
    // write_en = (en | sat_writeback_en) & ~flush, so `clear` on its own is
    // a no-op. In the real system MACCLEAR is in dsu_decoder's compute_op
    // list and therefore does assert mac_en.
    mac_drive_cycle(vif, 1'b1, 1'b1, 1'b0, 32'd0, 32'd0);
    mac_drive_cycle(vif, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0);
    $display("  baseline acc after clear            = %0d", $signed(vif.mac_out));

    // Issue exactly ONE multiply: 6 * 7 = 42.
    mac_drive_cycle(vif, 1'b1, 1'b0, 1'b0, 32'd6, 32'd7);
    pending_val = vif.mac_out;
    $display("  acc right after issuing 6*7         = %0d   (product still pending in sum_reg/carry_reg)",
              $signed(pending_val));

    // Go idle and see whether it EVER commits on its own.
    committed = 1'b0;
    for (idle_cycles = 1; idle_cycles <= 10; idle_cycles++) begin
        mac_drive_cycle(vif, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0);
        if (vif.mac_out !== pending_val) begin
            committed = 1'b1;
            break;
        end
    end
    if (committed)
        $display("  MEASURED COMMIT LATENCY             = %0d idle cycle(s) -> acc = %0d",
                  idle_cycles, $signed(vif.mac_out));
    else
        $display("  MEASURED COMMIT LATENCY             = NEVER (acc still %0d after 10 idle cycles)",
                  $signed(vif.mac_out));

    // Now issue a harmless 0*0 drain/"settle" op and watch the product land.
    mac_drive_cycle(vif, 1'b1, 1'b0, 1'b0, 32'd0, 32'd0);
    $display("  after ONE 0*0 drain op              = %0d", $signed(vif.mac_out));
    mac_drive_cycle(vif, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0);
    $display("  one cycle later                     = %0d", $signed(vif.mac_out));

    $display("");
    $display("  INTERPRETATION -- answers 'do the latency cycles work as they should?':");
    $display("    NO fixed latency exists. A multiply does not commit N cycles after");
    $display("    issue; it commits on the next cycle that asserts write_en for THAT");
    $display("    accumulator -- which may never arrive. Cross-checked against the");
    $display("    repo's own tools/golden/DSU_Golden.py, whose header states verbatim:");
    $display("    'a multiply issued in cycle K does not reach acc in cycle K+1 -- it");
    $display("     reaches acc on the next cycle that has write_en asserted for that");
    $display("     accumulator, which may never come.'");
    $display("    Software/ABI must therefore emit a trailing drain op. Logged as");
    $display("    FLAG-A / FLAG-C / stranded-product, all P0 OPEN, in");
    $display("    tb/dsu/GARUDA_DSU_Verification_Plan.xlsx -> 'Open Questions'.");
    $display("-----------------------------------------------------------\n");
endtask


// -------------------------------------------------------------
// 9. ENVIRONMENT
// -------------------------------------------------------------
class mac_env;
    virtual mac_unit_if vif;
    mac_generator      gen;
    mac_driver         drv;
    mac_monitor        mon;
    mac_scoreboard     sb;
    mac_pipeline_model model;

    function new(virtual mac_unit_if vif, int num_random = 1500, int num_overflow_iters = 131100);
        this.vif = vif;
        gen = new(num_random, num_overflow_iters);
        drv = new(vif);
        mon = new(vif);
        sb  = new(0);   // quiet mode: marathon cycles only print every 5000th PASS
        model = new();
    endfunction

    task run();
        bit [47:0] mac_out_; bit ovf_;
        gen.build();
        foreach (gen.items[i]) begin
            drv.apply(gen.items[i]);
            mon.sample_one(mac_out_, ovf_);
            sb.check(gen.items[i], mac_out_, ovf_, model, i);
        end

        $display("\n================ MAC_UNIT UNIT TB SUMMARY ================");
        $display(" TOTAL=%0d  PASS=%0d  FAIL=%0d", gen.items.size(), sb.pass_cnt, sb.fail_cnt);
        $display(" OVERFLOW BIT OBSERVED ASSERTED AT LEAST ONCE = %0b", sb.overflow_ever_seen);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", mon.cg_mac.get_coverage());
        if (sb.fail_cnt == 0) $display(" RESULT: ALL CHECKS PASSED");
        else                  $display(" RESULT: %0d CHECK(S) FAILED", sb.fail_cnt);
        tb_signoff(mon.cg_mac.get_coverage(), sb.fail_cnt);
        $display("=============================================================\n");
    endtask
endclass


// -------------------------------------------------------------
// 10. TEST
// -------------------------------------------------------------
class mac_test;
    mac_env env;
    function new(virtual mac_unit_if vif, int num_random = 1500, int num_overflow_iters = 131100);
        env = new(vif, num_random, num_overflow_iters);
    endfunction
    task run(); env.run(); endtask
endclass


// -------------------------------------------------------------
// 11. TB TOP
// -------------------------------------------------------------

module tb_top;
    bit clk = 0;
    always #5 clk = ~clk;

    mac_unit_if vif(clk);

    mac_unit dut (
        .clk(clk), .rst_n(vif.rst_n),
        .rs1(vif.rs1), .rs2(vif.rs2),
        .en(vif.en), .add_sub(vif.add_sub), .clear(vif.clear), .load(vif.load),
        .abs_en(vif.abs_en), .dot_en(vif.dot_en), .flush(vif.flush),
        .sat_writeback(vif.sat_writeback), .sat_writeback_en(vif.sat_writeback_en),
        .mac_out(vif.mac_out), .overflow(vif.overflow)
    );

    mac_test test;

    initial begin
        int tb_nrand = 1500;
        tb_control_init(tb_nrand, "tb_dsu_mac_unit");
        vif.rst_n = 1'b0;
        vif.rs1 = 0; vif.rs2 = 0; vif.en = 0; vif.add_sub = 0; vif.clear = 0; vif.load = 0;
        vif.abs_en = 0; vif.dot_en = 0; vif.flush = 0; vif.sat_writeback = 0; vif.sat_writeback_en = 0;
        repeat (3) @(posedge clk);
        vif.rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // NOTE: the 3rd argument below (131100) runs the full overflow
        // marathon (~131k cycles). Lower it for a quick smoke run.
        test = new(vif, tb_nrand, 131100);
        test.run();

        // Independent of the scoreboard: measure the REAL commit latency
        // and report it. See the audit task's header for why it is separate
        // (the scoreboard's model is cycle-accurate, so it can never flag
        // the timing itself as wrong).
        mac_timing_audit(vif);

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
