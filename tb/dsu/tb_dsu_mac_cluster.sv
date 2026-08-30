// =============================================================
// tb_dsu_mac_cluster.sv
//
//  BLOCK      : II -- DSU (Custom-0 MAC coprocessor)
//  RTL SOURCE : rtl/dsu/mac_cluster.v   (GARUDA_DSU_DesignSpec)
//  SCOPE      : DSU unit module
//
// Single-file SV verification environment for GARUDA mac_cluster.v
// (three mac_unit instances, steered by acc_sel; dbg_acc_* always
// exposes all three raw accumulators regardless of acc_sel)
//
// SEQUENTIAL. This env focuses on STEERING/MUX correctness (the
// right accumulator is selected and updated, the other two are held
// untouched, cluster_out follows the selected one, dbg_acc_* always
// shows all three) using three instances of the SAME cycle-accurate
// mac_pipeline_model used in tb_mac_unit.sv. Per-instance arithmetic
// depth (incl. the overflow boundary) is tb_mac_unit's job, not
// repeated here.
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
// 0. DEFINES (inlined from dsu_defs.vh)
// -------------------------------------------------------------
`ifndef DSU_DEFS_VH
`define DSU_DEFS_VH
`define ACC_FX  2'b00
`define ACC_FY  2'b01
`define ACC_MAG 2'b10
`define MAC_CTRL_W      7
`define MAC_CTRL_EN     6
`define MAC_CTRL_ADDSUB 5
`define MAC_CTRL_CLEAR  4
`define MAC_CTRL_LOAD   3
`define MAC_CTRL_ABS    2
`define MAC_CTRL_DOT    1
`define MAC_CTRL_FLUSH  0
`define FUNCT5_MAC_SEL  5'd0
`define FUNCT5_MACSUB   5'd1
`define FUNCT5_MACABS   5'd2
`define FUNCT5_MACDOT   5'd3
`define FUNCT5_MACLOAD  5'd4
`define FUNCT5_MACCLEAR 5'd5
`define FUNCT5_MACSAT   5'd6
`define FUNCT5_MACRD_LO 5'd7
`define FUNCT5_MACRD_HI 5'd8
`define FUNCT5_MACSHIFT 5'd9
`endif

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
// 1e. DUT SUB-MODULE: mac_unit.v (pasted verbatim)
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
// 1f. DUT: mac_cluster.v (pasted verbatim, self-contained file)
// -------------------------------------------------------------
module mac_cluster (
    input wire clk,
    input wire rst_n,

    input wire [31:0] rs1,
    input wire [31:0] rs2,

    input wire [`MAC_CTRL_W-1:0] control,
    input wire [1:0]             acc_sel,

    input wire [47:0] sat_writeback,
    input wire        sat_writeback_en,

    output wire [47:0] cluster_out,
    output wire [2:0]  overflow,

    output wire [47:0] dbg_acc_0,
    output wire [47:0] dbg_acc_1,
    output wire [47:0] dbg_acc_2
);

    wire ctrl_en     = control[`MAC_CTRL_EN];
    wire ctrl_addsub = control[`MAC_CTRL_ADDSUB];
    wire ctrl_clear  = control[`MAC_CTRL_CLEAR];
    wire ctrl_load   = control[`MAC_CTRL_LOAD];
    wire ctrl_abs    = control[`MAC_CTRL_ABS];
    wire ctrl_dot    = control[`MAC_CTRL_DOT];
    wire ctrl_flush  = control[`MAC_CTRL_FLUSH];

    wire [2:0] en_onehot;
    assign en_onehot[0] = ctrl_en & (acc_sel == `ACC_FX);
    assign en_onehot[1] = ctrl_en & (acc_sel == `ACC_FY);
    assign en_onehot[2] = ctrl_en & (acc_sel == `ACC_MAG);

    wire [2:0] sat_we_onehot;
    assign sat_we_onehot[0] = sat_writeback_en & (acc_sel == `ACC_FX);
    assign sat_we_onehot[1] = sat_writeback_en & (acc_sel == `ACC_FY);
    assign sat_we_onehot[2] = sat_writeback_en & (acc_sel == `ACC_MAG);

    wire [47:0] mac_out_0, mac_out_1, mac_out_2;

    mac_unit u_mac0 (
        .clk              (clk),
        .rst_n            (rst_n),
        .rs1              (rs1),
        .rs2              (rs2),
        .en               (en_onehot[0]),
        .add_sub          (ctrl_addsub),
        .clear            (ctrl_clear),
        .load             (ctrl_load),
        .abs_en           (ctrl_abs),
        .dot_en           (ctrl_dot),
        .flush            (ctrl_flush),
        .sat_writeback    (sat_writeback),
        .sat_writeback_en (sat_we_onehot[0]),
        .mac_out          (mac_out_0),
        .overflow         (overflow[0])
    );

    mac_unit u_mac1 (
        .clk              (clk),
        .rst_n            (rst_n),
        .rs1              (rs1),
        .rs2              (rs2),
        .en               (en_onehot[1]),
        .add_sub          (ctrl_addsub),
        .clear            (ctrl_clear),
        .load             (ctrl_load),
        .abs_en           (ctrl_abs),
        .dot_en           (ctrl_dot),
        .flush            (ctrl_flush),
        .sat_writeback    (sat_writeback),
        .sat_writeback_en (sat_we_onehot[1]),
        .mac_out          (mac_out_1),
        .overflow         (overflow[1])
    );

    mac_unit u_mac2 (
        .clk              (clk),
        .rst_n            (rst_n),
        .rs1              (rs1),
        .rs2              (rs2),
        .en               (en_onehot[2]),
        .add_sub          (ctrl_addsub),
        .clear            (ctrl_clear),
        .load             (ctrl_load),
        .abs_en           (ctrl_abs),
        .dot_en           (ctrl_dot),
        .flush            (ctrl_flush),
        .sat_writeback    (sat_writeback),
        .sat_writeback_en (sat_we_onehot[2]),
        .mac_out          (mac_out_2),
        .overflow         (overflow[2])
    );

    reg [47:0] cluster_out_r;
    always @(*) begin
        case (acc_sel)
            `ACC_FX:  cluster_out_r = mac_out_0;
            `ACC_FY:  cluster_out_r = mac_out_1;
            `ACC_MAG: cluster_out_r = mac_out_2;
            default: cluster_out_r = 48'b0;
        endcase
    end

    assign cluster_out = cluster_out_r;

    assign dbg_acc_0 = mac_out_0;
    assign dbg_acc_1 = mac_out_1;
    assign dbg_acc_2 = mac_out_2;

endmodule


// -------------------------------------------------------------
// 2. INTERFACE (+ bound SVA)
// -------------------------------------------------------------
interface mac_cluster_if (input bit clk);
    logic        rst_n;
    logic [31:0] rs1, rs2;
    logic [6:0]  control;
    logic [1:0]  acc_sel;
    logic [47:0] sat_writeback;
    logic        sat_writeback_en;
    logic [47:0] cluster_out;
    logic [2:0]  overflow;
    logic [47:0] dbg_acc_0, dbg_acc_1, dbg_acc_2;

    property p_no_x_propagation;
        @(posedge clk) disable iff (!rst_n)
        (!$isunknown({rs1, rs2, control, acc_sel, sat_writeback_en}))
        |-> (!$isunknown({cluster_out, overflow}));
    endproperty
    a_no_x_propagation: assert property (p_no_x_propagation)
        else $error("[SVA-FAIL] X detected on mac_cluster outputs with fully-known inputs");

    // acc_sel==11 must never assert any of the 3 overflow bits (none of
    // the accumulators are touched in that case).
    property p_reserved_accsel_no_overflow;
        @(posedge clk) disable iff (!rst_n)
        (acc_sel == 2'b11) |-> (overflow == 3'b000);
    endproperty
    a_reserved_accsel_no_overflow: assert property (p_reserved_accsel_no_overflow)
        else $error("[SVA-FAIL] overflow asserted while acc_sel was the reserved 2'b11 encoding");

    // While reset is asserted ALL THREE accumulators must read as zero --
    // not merely the one acc_sel happens to point at. Deliberately has NO
    // `disable iff (!rst_n)`: every other property in this interface
    // switches itself off during reset, so without this one nothing checks
    // the cluster at all while rst_n is low.
    property p_reset_clears_all_three;
        @(posedge clk) (!rst_n) |->
            (dbg_acc_0 == 48'd0 && dbg_acc_1 == 48'd0 && dbg_acc_2 == 48'd0);
    endproperty
    a_reset_clears_all_three: assert property (p_reset_clears_all_three)
        else $error("[SVA-FAIL] an accumulator was non-zero while rst_n asserted");
endinterface


// -------------------------------------------------------------
// 3. PER-CYCLE STIMULUS ITEM
// -------------------------------------------------------------
class cluster_cycle;
    rand bit [31:0] rs1, rs2;
    rand bit [6:0]  control;
    rand bit [1:0]  acc_sel;
    rand bit [47:0] sat_writeback;
    rand bit        sat_writeback_en;
    // Deliberately NOT rand -- see the same field in tb_dsu_mac_unit.sv.
    // Reset is driven only by the directed dir_rst_* cases, which assert it
    // with ALL THREE accumulators holding distinct non-zero values.
    bit             rst_n = 1'b1;
    string tag;

    constraint c_acc_sel_dist { acc_sel dist { `ACC_FX:=30, `ACC_FY:=30, `ACC_MAG:=30, 2'b11:=10 }; }
    constraint c_control_shape {
        control[`MAC_CTRL_EN] dist { 1:=70, 0:=30 };
        control[`MAC_CTRL_CLEAR] dist {1:=5,0:=95};
        control[`MAC_CTRL_LOAD] dist {1:=8,0:=92};
        control[`MAC_CTRL_FLUSH] dist {1:=5,0:=95};
        control[`MAC_CTRL_ABS] dist {1:=15,0:=85};
        control[`MAC_CTRL_DOT] dist {1:=15,0:=85};
        control[`MAC_CTRL_ADDSUB] dist {1:=30,0:=70};
        sat_writeback_en dist {1:=5,0:=95};
    }
    // Operand corner biasing per 16-bit lane, same rationale as mac_unit's
    // own TB: abs_en/dot_en only touch specific lanes, so each needs
    // independent extreme-value coverage.
    constraint c_rs1_corner_dist {
        rs1[15:0]  dist { 16'h8000 := 6, 16'h7FFF := 6, 16'h0000 := 6, 16'hFFFF := 6, [16'h0001:16'hFFFE] :/ 76 };
        rs1[31:16] dist { 16'h8000 := 6, 16'h7FFF := 6, 16'h0000 := 6, 16'hFFFF := 6, [16'h0001:16'hFFFE] :/ 76 };
    }
    constraint c_rs2_corner_dist {
        rs2[15:0]  dist { 16'h8000 := 6, 16'h7FFF := 6, 16'h0000 := 6, 16'hFFFF := 6, [16'h0001:16'hFFFE] :/ 76 };
        rs2[31:16] dist { 16'h8000 := 6, 16'h7FFF := 6, 16'h0000 := 6, 16'hFFFF := 6, [16'h0001:16'hFFFE] :/ 76 };
    }

    function new(string tag_ = "random"); tag = tag_; endfunction
    function string to_s();
        return $sformatf("rs1=%08h rs2=%08h control=%07b acc_sel=%02b sat_en=%0b rst_n=%0b", rs1, rs2, control, acc_sel, sat_writeback_en, rst_n);
    endfunction
endclass


// -------------------------------------------------------------
// 4. REFERENCE MODEL -- three instances of mac_unit.v's own pipeline
//    (reused struct from tb_mac_unit.sv), steered exactly like
//    mac_cluster.v's one-hot enable/sat_we logic.
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
        // mac_unit.v (instantiated three times below this level) resets
        // sum_reg/carry_reg and acc from `negedge rst_n`, so they clear the
        // instant rst_n falls rather than on a clock edge. Each of the three
        // model instances applies it independently -- which is exactly what
        // makes a reset that clears only SOME of the accumulators visible
        // here, a failure mode the single-instance mac_unit TB cannot see.
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

        // Convention adopted from tools/golden/DSU_Golden.py: every output is
        // the value VISIBLE DURING THIS CYCLE. Registered outputs therefore
        // report their PRE-edge contents and state is committed afterwards --
        // the reference model returns "acc": list(self.acc) with the comment
        // '# pre-edge, as sampled' for exactly this reason. Aligning to it
        // keeps our expected values directly comparable with DSU_Golden.py
        // and with tools/gen/DSU_gen.py's dsu_expected.mem.
        mac_out_next  = acc;
        overflow_next = accum_ovf & write_en & is_accum;

        // Guarded by rst_n: while reset is asserted the clocked branches
        // never run, so nothing may be latched back over the async clear.
        if (rst_n) begin
            if (flush) begin
                sum_reg   = 48'sd0;
                carry_reg = 48'sd0;
            end else if (write_en) begin
                sum_reg   = csa1_sum;
                carry_reg = csa1_carry;
            end

            if (write_en) acc = acc_next;   // FLAG-B: flush spares acc
        end
    endfunction
endclass


// -------------------------------------------------------------
// 5. GENERATOR
// -------------------------------------------------------------
class cluster_generator;
    cluster_cycle items[$];
    int num_random;

    function new(int num_random = 1500); this.num_random = num_random; endfunction

    function cluster_cycle mk(string tag, bit [1:0] acc_sel, bit en, bit addsub, bit clear, bit load,
                               bit abs_, bit dot_, bit flush, bit [31:0] rs1, bit [31:0] rs2,
                               bit sat_en = 0, bit [47:0] sat_wb = 0, bit rst_n_ = 1'b1);
        cluster_cycle c = new(tag);
        c.acc_sel = acc_sel;
        c.control = {en, addsub, clear, load, abs_, dot_, flush};
        c.rs1 = rs1; c.rs2 = rs2;
        c.sat_writeback_en = sat_en; c.sat_writeback = sat_wb;
        c.rst_n = rst_n_;
        return c;
    endfunction

    function void build();
        items.push_back(mk("dir_clear_fx",  `ACC_FX,  1,0,1,0,0,0,0, 0,0));
        items.push_back(mk("dir_clear_fy",  `ACC_FY,  1,0,1,0,0,0,0, 0,0));
        items.push_back(mk("dir_clear_mag", `ACC_MAG, 1,0,1,0,0,0,0, 0,0));

        items.push_back(mk("dir_mac_fx1", `ACC_FX, 1,0,0,0,0,0,0, 32'd5, 32'd6));
        items.push_back(mk("dir_idle1",   `ACC_FX, 0,0,0,0,0,0,0, 0,0));
        items.push_back(mk("dir_idle2",   `ACC_FX, 0,0,0,0,0,0,0, 0,0));

        items.push_back(mk("dir_mac_fy1", `ACC_FY, 1,0,0,0,0,0,0, 32'd2, 32'd9));
        items.push_back(mk("dir_idle3",   `ACC_FY, 0,0,0,0,0,0,0, 0,0));
        items.push_back(mk("dir_idle4",   `ACC_FY, 0,0,0,0,0,0,0, 0,0));

        items.push_back(mk("dir_mac_mag1", `ACC_MAG, 1,0,0,0,0,0,0, 32'd4, 32'd4));
        items.push_back(mk("dir_idle5",    `ACC_MAG, 0,0,0,0,0,0,0, 0,0));
        items.push_back(mk("dir_idle6",    `ACC_MAG, 0,0,0,0,0,0,0, 0,0));

        items.push_back(mk("dir_accsel_reserved", 2'b11, 1,0,0,0,0,0,0, 32'd99, 32'd99));
        items.push_back(mk("dir_idle7", 2'b11, 0,0,0,0,0,0,0, 0,0));

        items.push_back(mk("dir_sat_fx", `ACC_FX, 0,0,0,0,0,0,0, 0,0, 1, 48'sh0000_00001111));
        items.push_back(mk("dir_idle8", `ACC_FX, 0,0,0,0,0,0,0, 0,0));

        // --- ASYNCHRONOUS RESET WITH ALL THREE ACCUMULATORS LOADED ---------
        // The power-on reset in tb_top only clears an already-zero cluster.
        // Here each accumulator is first loaded with a DIFFERENT non-zero
        // value, so a reset that clears only the selected accumulator (or
        // only acc[0]) shows up as a mismatch on the other two -- a wiring
        // failure mode the single-instance tb_dsu_mac_unit.sv cannot see,
        // since it has only one accumulator to get right.
        items.push_back(mk("dir_rst_load_fx",  `ACC_FX,  1,0,0,1,0,0,0, 32'h1111_1111, 0));
        items.push_back(mk("dir_rst_load_fy",  `ACC_FY,  1,0,0,1,0,0,0, 32'h2222_2222, 0));
        items.push_back(mk("dir_rst_load_mag", `ACC_MAG, 1,0,0,1,0,0,0, 32'h3333_3333, 0));
        // leave a product in flight in FX as well, so sum_reg/carry_reg are
        // non-zero at the moment reset lands
        items.push_back(mk("dir_rst_inflight", `ACC_FX, 1,0,0,0,0,0,0, 32'd300, 32'd300));
        items.push_back(mk("dir_rst_assert",   `ACC_FX, 0,0,0,0,0,0,0, 0,0, 0, 0, 1'b0));
        items.push_back(mk("dir_rst_hold",     `ACC_FY, 0,0,0,0,0,0,0, 0,0, 0, 0, 1'b0));
        // reset must win even with en asserted
        items.push_back(mk("dir_rst_beats_en", `ACC_MAG, 1,0,0,0,0,0,0, 32'd77, 32'd77, 0, 0, 1'b0));
        items.push_back(mk("dir_rst_release",  `ACC_FX, 0,0,0,0,0,0,0, 0,0));
        items.push_back(mk("dir_rst_after1",   `ACC_FX, 0,0,0,0,0,0,0, 0,0));
        // all three must accumulate correctly again after the reset
        items.push_back(mk("dir_rst_post_fx",  `ACC_FX,  1,0,0,0,0,0,0, 32'd5, 32'd5));
        items.push_back(mk("dir_rst_post_fy",  `ACC_FY,  1,0,0,0,0,0,0, 32'd6, 32'd6));
        items.push_back(mk("dir_rst_post_mag", `ACC_MAG, 1,0,0,0,0,0,0, 32'd7, 32'd7));
        items.push_back(mk("dir_rst_after2",   `ACC_FX, 0,0,0,0,0,0,0, 0,0));
        items.push_back(mk("dir_rst_after3",   `ACC_FX, 0,0,0,0,0,0,0, 0,0));

        repeat (num_random) begin
            cluster_cycle r = new("random");
            assert (r.randomize()) else $error("[GEN] randomize() failed");
            items.push_back(r);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 6. DRIVER
// -------------------------------------------------------------
class cluster_driver;
    virtual mac_cluster_if vif;
    function new(virtual mac_cluster_if vif); this.vif = vif; endfunction

    task apply(cluster_cycle c);
        @(negedge vif.clk);
        vif.rst_n <= c.rst_n;
        vif.rs1 <= c.rs1; vif.rs2 <= c.rs2;
        vif.control <= c.control; vif.acc_sel <= c.acc_sel;
        vif.sat_writeback <= c.sat_writeback; vif.sat_writeback_en <= c.sat_writeback_en;
    endtask
endclass


// -------------------------------------------------------------
// 7. MONITOR
// -------------------------------------------------------------
class cluster_monitor;
    virtual mac_cluster_if vif;

    covergroup cg_cluster;
        cp_accsel: coverpoint vif.acc_sel;
        cp_rst_n: coverpoint vif.rst_n;   // both bins hit by the dir_rst_* cases
        cp_en: coverpoint vif.control[`MAC_CTRL_EN];
        cp_satwe: coverpoint vif.sat_writeback_en;
        cross cp_accsel, cp_en;
    endgroup

    function new(virtual mac_cluster_if vif); this.vif = vif; cg_cluster = new(); endfunction

    // TIMING NOTE (this was a real TB bug, fixed here) -- see the same note
    // in tb_mac_unit.sv. overflow[2:0] is COMBINATIONAL (it describes the
    // accumulate about to commit, evaluated against pre-edge state), while
    // cluster_out and dbg_acc_* are REGISTERED (they are the three acc
    // registers). Reading all of them with one bare "#1;" after the negedge
    // drive made every accumulator value lag the reference model by a full
    // cycle. Combinational first, then cross the posedge for the registers.
    task sample_one(output bit [47:0] co_, output bit [2:0] ovf_, output bit [47:0] d0_, output bit [47:0] d1_, output bit [47:0] d2_);
        #1;
        ovf_ = vif.overflow;
        co_  = vif.cluster_out;
        d0_ = vif.dbg_acc_0; d1_ = vif.dbg_acc_1; d2_ = vif.dbg_acc_2;
        cg_cluster.sample();
    endtask
endclass


// -------------------------------------------------------------
// 8. SCOREBOARD
// -------------------------------------------------------------
class cluster_scoreboard;
    int pass_cnt = 0;
    int fail_cnt = 0;

    task check(cluster_cycle c, bit [47:0] co_, bit [2:0] ovf_, bit [47:0] d0_, bit [47:0] d1_, bit [47:0] d2_,
               ref mac_pipeline_model m_fx, ref mac_pipeline_model m_fy, ref mac_pipeline_model m_mag);
        bit en, addsub, clear, load, abs_, dot_, flush;
        bit en_fx, en_fy, en_mag, satwe_fx, satwe_fy, satwe_mag;
        bit [47:0] out_fx, out_fy, out_mag, co_exp;
        bit ovf_fx, ovf_fy, ovf_mag; bit [2:0] ovf_exp;
        bit ok;

        en     = c.control[`MAC_CTRL_EN];
        addsub = c.control[`MAC_CTRL_ADDSUB];
        clear  = c.control[`MAC_CTRL_CLEAR];
        load   = c.control[`MAC_CTRL_LOAD];
        abs_   = c.control[`MAC_CTRL_ABS];
        dot_   = c.control[`MAC_CTRL_DOT];
        flush  = c.control[`MAC_CTRL_FLUSH];

        en_fx  = en & (c.acc_sel == `ACC_FX);
        en_fy  = en & (c.acc_sel == `ACC_FY);
        en_mag = en & (c.acc_sel == `ACC_MAG);
        satwe_fx  = c.sat_writeback_en & (c.acc_sel == `ACC_FX);
        satwe_fy  = c.sat_writeback_en & (c.acc_sel == `ACC_FY);
        satwe_mag = c.sat_writeback_en & (c.acc_sel == `ACC_MAG);

        m_fx.step(c.rs1, c.rs2, en_fx, addsub, clear, load, abs_, dot_, flush, c.sat_writeback, satwe_fx, c.rst_n, out_fx, ovf_fx);
        m_fy.step(c.rs1, c.rs2, en_fy, addsub, clear, load, abs_, dot_, flush, c.sat_writeback, satwe_fy, c.rst_n, out_fy, ovf_fy);
        m_mag.step(c.rs1, c.rs2, en_mag, addsub, clear, load, abs_, dot_, flush, c.sat_writeback, satwe_mag, c.rst_n, out_mag, ovf_mag);

        case (c.acc_sel)
            `ACC_FX:  co_exp = out_fx;
            `ACC_FY:  co_exp = out_fy;
            `ACC_MAG: co_exp = out_mag;
            default:  co_exp = 48'b0;
        endcase
        ovf_exp = {ovf_mag, ovf_fy, ovf_fx};

        ok = (co_===co_exp) & (ovf_===ovf_exp) & (d0_===out_fx) & (d1_===out_fy) & (d2_===out_mag);

        if (ok) begin
            pass_cnt++;
            $display("[PASS] %-20s %-0s -> cluster_out=%012h ovf=%03b", c.tag, c.to_s(), co_, ovf_);
        end else begin
            fail_cnt++;
            $display("[FAIL] %-20s %-0s -> got(co=%012h ovf=%03b d0=%012h d1=%012h d2=%012h) exp(co=%012h ovf=%03b d0=%012h d1=%012h d2=%012h)",
                      c.tag, c.to_s(), co_, ovf_, d0_, d1_, d2_, co_exp, ovf_exp, out_fx, out_fy, out_mag);
        end
    endtask
endclass


// -------------------------------------------------------------
// 9. ENVIRONMENT
// -------------------------------------------------------------
class cluster_env;
    virtual mac_cluster_if vif;
    cluster_generator  gen;
    cluster_driver     drv;
    cluster_monitor    mon;
    cluster_scoreboard sb;
    mac_pipeline_model m_fx, m_fy, m_mag;

    function new(virtual mac_cluster_if vif, int num_random = 1500);
        this.vif = vif;
        gen = new(num_random);
        drv = new(vif);
        mon = new(vif);
        sb  = new();
        m_fx = new(); m_fy = new(); m_mag = new();
    endfunction

    task run();
        bit [47:0] co_; bit [2:0] ovf_; bit [47:0] d0_, d1_, d2_;
        gen.build();
        foreach (gen.items[i]) begin
            drv.apply(gen.items[i]);
            mon.sample_one(co_, ovf_, d0_, d1_, d2_);
            sb.check(gen.items[i], co_, ovf_, d0_, d1_, d2_, m_fx, m_fy, m_mag);
        end

        $display("\n================ MAC_CLUSTER UNIT TB SUMMARY ================");
        $display(" TOTAL=%0d  PASS=%0d  FAIL=%0d", gen.items.size(), sb.pass_cnt, sb.fail_cnt);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", mon.cg_cluster.get_coverage());
        if (sb.fail_cnt == 0) $display(" RESULT: ALL CHECKS PASSED");
        else                  $display(" RESULT: %0d CHECK(S) FAILED", sb.fail_cnt);
        tb_signoff(mon.cg_cluster.get_coverage(), sb.fail_cnt);
        $display("=================================================================\n");
    endtask
endclass


// -------------------------------------------------------------
// 10. TEST
// -------------------------------------------------------------
class cluster_test;
    cluster_env env;
    function new(virtual mac_cluster_if vif, int num_random = 1500);
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

    mac_cluster_if vif(clk);

    mac_cluster dut (
        .clk(clk), .rst_n(vif.rst_n),
        .rs1(vif.rs1), .rs2(vif.rs2),
        .control(vif.control), .acc_sel(vif.acc_sel),
        .sat_writeback(vif.sat_writeback), .sat_writeback_en(vif.sat_writeback_en),
        .cluster_out(vif.cluster_out), .overflow(vif.overflow),
        .dbg_acc_0(vif.dbg_acc_0), .dbg_acc_1(vif.dbg_acc_1), .dbg_acc_2(vif.dbg_acc_2)
    );

    cluster_test test;

    initial begin
        int tb_nrand = 1500;
        tb_control_init(tb_nrand, "tb_dsu_mac_cluster");
        vif.rst_n = 1'b0;
        vif.rs1 = 0; vif.rs2 = 0; vif.control = 0; vif.acc_sel = 0;
        vif.sat_writeback = 0; vif.sat_writeback_en = 0;
        repeat (3) @(posedge clk);
        vif.rst_n = 1'b1;
        repeat (2) @(posedge clk);

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
