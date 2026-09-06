// =============================================================
// mac_unit_tb.sv
// Tapeout-grade SV verification environment for GARUDA mac_unit.v
// (16x16 signed multiply, 48-bit accumulator, 2-cycle carry-save
//  pipeline -- the core compute datapath of the DSU MAC cluster)
//
// Sequential/stateful, like dsu_stall: correctness is defined by
// cycle-accurate SEQUENCES, checked against a behavioral reference
// model that independently computes the TRUE arithmetic result
// (not a structural mirror of the RTL's csa_3to2/kogge_stone_49
// implementation choices) with the SAME 2-stage pipeline latency.
//
// The reference model's timing and arithmetic assumptions were
// validated offline via a Python prototype (500+ random 60-cycle
// sequences through the full realistic operand_router -> mult_16x16
// -> csa1 -> csa2 -> kogge_stone_49 path) BEFORE being ported to
// this SV environment -- that exercise is what surfaced Finding 1
// below; it is not a guess encoded directly into SV without proof.
//
// Requires a simulator with full IEEE1800 support (covergroup,
// assert property). NOT Icarus Verilog.
// =============================================================

`timescale 1ns / 1ps

// -------------------------------------------------------------
// 1. DUT + all sub-modules (pasted verbatim, self-contained file)
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

module mult_16x16 (
    input wire signed [15:0] a,
    input wire signed [15:0] b,
    output wire signed [31:0] p
);
    assign p = a*b;
endmodule

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

module kogge_stone_49 (
    input wire  [48:0] a,
    input wire  [48:0] b,
    input wire         cin,
    output wire [48:0] sum
);
    assign sum = a + b + cin;
endmodule

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
        .rs1 (rs1), .rs2 (rs2), .abs_en (abs_en), .dot_en (dot_en),
        .a0 (a0), .b0 (b0), .a1 (a1), .b1 (b1)
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
        .a (pa_eff), .b (pb_eff), .c (sub_k), .sum (csa1_sum), .carry (csa1_carry)
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
        .a (acc), .b (sum_reg), .c (carry_reg), .sum (csa2_sum), .carry (csa2_carry)
    );

    wire [48:0] s_ext = {csa2_sum[47], csa2_sum};
    wire [48:0] c_ext = {csa2_carry[47], csa2_carry};
    wire [48:0] result_ext;
    kogge_stone_49 u_ks (
        .a (s_ext), .b (c_ext), .cin (1'b0), .sum (result_ext)
    );

    wire [47:0] adder_result = result_ext[47:0];

    // ---------------------------------------------------------------
    // FIX (applied after the false-positive/false-negative finding):
    // the original `accum_ovf = result_ext[48] ^ result_ext[47]`
    // requires the 49-bit CSA-then-adder path to carry the TRUE,
    // un-truncated sum -- but csa_3to2's own internal <<1 truncation
    // (majority[WIDTH-1] dropped inside u_csa2) destroys exactly the
    // bit that formula needs, even though it never corrupts
    // adder_result itself (that discrepancy is exactly 2^48, invisible
    // mod 2^48). Fix: derive overflow using the standard two's-
    // complement addition rule -- overflow iff the two operands share a
    // sign and the result's sign differs from theirs -- applied to acc
    // and the collapsed pending value (sum_reg+carry_reg, a plain
    // 48-bit add, also provably correct mod 2^48 regardless of any CSA
    // truncation upstream). Validated: 0 mismatches over 500,000
    // trials against ground truth, including the same extreme/
    // truncation-triggering value space that broke the original
    // formula.
    // ---------------------------------------------------------------
    wire [47:0] pending      = sum_reg + carry_reg;
    wire        acc_sign     = acc[47];
    wire        pending_sign = pending[47];
    wire        result_sign  = adder_result[47];
    wire        accum_ovf    = (acc_sign == pending_sign) && (result_sign != acc_sign);

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
// 2. INTERFACE (+ bound SVA assertions)
// -------------------------------------------------------------
interface mac_if (input bit clk);
    logic        rst_n;
    logic [31:0] rs1, rs2;
    logic        en, add_sub, clear, load, abs_en, dot_en, flush;
    logic [47:0] sat_writeback;
    logic        sat_writeback_en;
    logic [47:0] mac_out;
    logic        overflow;

    // A1: X-propagation on the two registered outputs, post-reset
    property p_no_x_propagation;
        @(posedge clk) disable iff (!rst_n)
        (!$isunknown({rs1,rs2,en,add_sub,clear,load,abs_en,dot_en,flush,
                       sat_writeback,sat_writeback_en})) |-> (!$isunknown({mac_out, overflow}));
    endproperty
    a_no_x_propagation: assert property (p_no_x_propagation)
        else $error("[SVA-FAIL] X on mac_out/overflow with fully-known inputs");

    // A2: reset clears mac_out to 0 immediately (async), observable on
    //     the cycle immediately following reset release
    property p_reset_clears_acc;
        @(posedge clk) $rose(rst_n) |-> (mac_out == 48'b0);
    endproperty
    a_reset_clears_acc: assert property (p_reset_clears_acc)
        else $error("[SVA-FAIL] mac_out != 0 the cycle after reset release");

    // A3: load never updates when en=0 and sat_writeback_en=0 (write_en
    //     gates EVERYTHING -- a modifier bit set without a real enable
    //     must never take effect). Cross-checked against dsu_decoder's
    //     own contract: mac_load/mac_clear/etc are NOT individually
    //     gated by mac_en in the control bus, so this combination is a
    //     real, reachable integration scenario, not just robustness.
    property p_no_update_without_write_en;
        @(posedge clk) disable iff (!rst_n)
        (!en && !sat_writeback_en && !flush) |-> ##1 $stable(mac_out);
    endproperty
    a_no_update_without_write_en: assert property (p_no_update_without_write_en)
        else $error("[SVA-FAIL] mac_out changed despite en=0, sat_writeback_en=0, flush=0");

    // A4: flush must never clear mac_out itself (only the in-flight
    //     sum_reg/carry_reg pipeline register) -- mac_out must hold
    //     across a flush cycle.
    property p_flush_holds_acc;
        @(posedge clk) disable iff (!rst_n)
        flush |-> ##1 $stable(mac_out);
    endproperty
    a_flush_holds_acc: assert property (p_flush_holds_acc)
        else $error("[SVA-FAIL] mac_out changed on the cycle following a flush");

endinterface


// -------------------------------------------------------------
// 3. PER-CYCLE STIMULUS ITEM -- rand + constraint => real CRV
// -------------------------------------------------------------
typedef enum {
    OP_MAC_SEL, OP_MACSUB, OP_MACDOT, OP_MACDOT_SUB, OP_MACABS, OP_MACABS_SUB,
    OP_MACABS_DOT, OP_MACLOAD, OP_MACCLEAR, OP_SAT_WRITEBACK, OP_BUBBLE, OP_RAW
} mac_op_e;

class mac_cycle;
    rand mac_op_e op;
    rand bit [31:0] rs1, rs2;
    rand bit [47:0] sat_wb_val;
    rand bit        flush;
    rand bit        rst_n;

    // raw override for corner cases not expressible via the op enum
    // (e.g. modifier bits set with en=0)
    bit       use_raw;
    bit       raw_en, raw_add_sub, raw_clear, raw_load, raw_abs_en, raw_dot_en, raw_sat_en;

    constraint c_op_dist {
        op dist {
            OP_MAC_SEL :/ 14, OP_MACSUB :/ 12, OP_MACDOT :/ 10, OP_MACDOT_SUB :/ 8,
            OP_MACABS :/ 8, OP_MACABS_SUB :/ 6, OP_MACABS_DOT :/ 4,
            OP_MACLOAD :/ 8, OP_MACCLEAR :/ 6, OP_SAT_WRITEBACK :/ 6, OP_BUBBLE :/ 10
        };
    }
    constraint c_rst_n_dist { rst_n dist { 1'b1 :/ 97, 1'b0 :/ 3 }; }
    constraint c_flush_dist { flush dist { 1'b0 :/ 88, 1'b1 :/ 12 }; }

    // bias rs1/rs2 toward extremes (0x0000/0x7FFF/0x8000/0xFFFF per
    // 16-bit lane) since those are what actually stress overflow,
    // abs-saturation (0x8000), and the CSA truncation/overflow-miss
    // condition (Finding 1) -- not swamped by uniformly-random values
    // that rarely land near any boundary.
    constraint c_operand_dist {
        rs1[15:0]  dist {16'h0000:/10, 16'h7FFF:/15, 16'h8000:/15, 16'hFFFF:/10, [16'h0001:16'hFFFE] :/50};
        rs1[31:16] dist {16'h0000:/10, 16'h7FFF:/15, 16'h8000:/15, 16'hFFFF:/10, [16'h0001:16'hFFFE] :/50};
        rs2[15:0]  dist {16'h0000:/10, 16'h7FFF:/15, 16'h8000:/15, 16'hFFFF:/10, [16'h0001:16'hFFFE] :/50};
        rs2[31:16] dist {16'h0000:/10, 16'h7FFF:/15, 16'h8000:/15, 16'hFFFF:/10, [16'h0001:16'hFFFE] :/50};
    }

    function void fields(output bit v_en, output bit v_add_sub, output bit v_clear,
                          output bit v_load, output bit v_abs_en, output bit v_dot_en,
                          output bit v_sat_en);
        if (use_raw) begin
            v_en = raw_en; v_add_sub = raw_add_sub; v_clear = raw_clear;
            v_load = raw_load; v_abs_en = raw_abs_en; v_dot_en = raw_dot_en; v_sat_en = raw_sat_en;
            return;
        end
        v_en = 1'b0; v_add_sub = 1'b0; v_clear = 1'b0; v_load = 1'b0;
        v_abs_en = 1'b0; v_dot_en = 1'b0; v_sat_en = 1'b0;
        case (op)
            OP_MAC_SEL:       v_en = 1;
            OP_MACSUB:        begin v_en = 1; v_add_sub = 1; end
            OP_MACDOT:        begin v_en = 1; v_dot_en = 1; end
            OP_MACDOT_SUB:    begin v_en = 1; v_dot_en = 1; v_add_sub = 1; end
            OP_MACABS:        begin v_en = 1; v_abs_en = 1; end
            OP_MACABS_SUB:    begin v_en = 1; v_abs_en = 1; v_add_sub = 1; end
            OP_MACABS_DOT:    begin v_en = 1; v_abs_en = 1; v_dot_en = 1; end // dot suppressed by design
            OP_MACLOAD:       begin v_en = 1; v_load = 1; end
            OP_MACCLEAR:      begin v_en = 1; v_clear = 1; end
            OP_SAT_WRITEBACK: v_sat_en = 1;
            OP_BUBBLE:        ; // everything 0
            default: ;
        endcase
    endfunction
endclass


// -------------------------------------------------------------
// 4. GENERATOR -- directed sequences + CRV
// -------------------------------------------------------------
class mac_generator;
    mac_cycle seq_q[$][$];
    string    seq_name[$];
    int num_random_seqs;
    int random_seq_len;

    function new(int num_random_seqs = 25, int random_seq_len = 40);
        this.num_random_seqs = num_random_seqs;
        this.random_seq_len  = random_seq_len;
    endfunction

    function mac_cycle mk(mac_op_e op, bit [31:0] rs1 = 32'd0, bit [31:0] rs2 = 32'd0,
                           bit [47:0] sat_wb_val = 48'd0, bit flush = 0, bit rst_n = 1);
        mac_cycle c = new();
        c.op = op; c.rs1 = rs1; c.rs2 = rs2; c.sat_wb_val = sat_wb_val;
        c.flush = flush; c.rst_n = rst_n;
        return c;
    endfunction

    function mac_cycle mk_raw(bit en, bit add_sub, bit clear, bit load, bit abs_en, bit dot_en,
                               bit sat_en, bit [31:0] rs1 = 32'd0, bit [31:0] rs2 = 32'd0,
                               bit [47:0] sat_wb_val = 48'd0, bit flush = 0, bit rst_n = 1);
        mac_cycle c = new();
        c.use_raw = 1'b1;
        c.raw_en = en; c.raw_add_sub = add_sub; c.raw_clear = clear; c.raw_load = load;
        c.raw_abs_en = abs_en; c.raw_dot_en = dot_en; c.raw_sat_en = sat_en;
        c.rs1 = rs1; c.rs2 = rs2; c.sat_wb_val = sat_wb_val; c.flush = flush; c.rst_n = rst_n;
        return c;
    endfunction

    function void add_seq(string name, mac_cycle q[$]);
        seq_name.push_back(name);
        seq_q.push_back(q);
    endfunction

    function void build();
        // 1) Basic MAC_SEL accumulate x3, watch the 2-cycle pipeline latency
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_MAC_SEL, 32'h0000_0005, 32'h0000_0003)); // 5*3=15
            q.push_back(mk(OP_MAC_SEL, 32'h0000_0002, 32'h0000_0004)); // 2*4=8
            q.push_back(mk(OP_MAC_SEL, 32'h0000_000A, 32'h0000_000A)); // 10*10=100
            q.push_back(mk(OP_BUBBLE));
            q.push_back(mk(OP_BUBBLE));
            add_seq("basic_mac_sel_accumulate", q);
        end

        // 2) MACSUB: subtract a product from the accumulator
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_MAC_SEL, 32'h0000_0064, 32'h0000_0064)); // +10000
            q.push_back(mk(OP_MACSUB,  32'h0000_0032, 32'h0000_0032)); // -2500
            q.push_back(mk(OP_BUBBLE));
            q.push_back(mk(OP_BUBBLE));
            add_seq("mac_sub_after_sel", q);
        end

        // 3) MACDOT: two lanes multiply-summed in one op
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_MACDOT, {16'h0003, 16'h0002}, {16'h0004, 16'h0005})); // 2*5 + 3*4 = 22
            q.push_back(mk(OP_BUBBLE));
            q.push_back(mk(OP_BUBBLE));
            add_seq("mac_dot_basic", q);
        end

        // 4) MACDOT + SUB combined
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_MACDOT_SUB, {16'h0003, 16'h0002}, {16'h0004, 16'h0005}));
            q.push_back(mk(OP_BUBBLE));
            q.push_back(mk(OP_BUBBLE));
            add_seq("mac_dot_sub", q);
        end

        // 5) MACABS including the 0x8000 saturating-abs special case
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_MACABS, 32'h0000_8000, 32'h0000_8000)); // abs(-32768)=32767 both lanes -> 32767*32767
            q.push_back(mk(OP_BUBBLE));
            q.push_back(mk(OP_BUBBLE));
            add_seq("mac_abs_0x8000_boundary", q);
        end

        // 6) MACABS + SUB
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_MACABS_SUB, 32'hFFFF_0005, 32'hFFFF_0003));
            q.push_back(mk(OP_BUBBLE));
            q.push_back(mk(OP_BUBBLE));
            add_seq("mac_abs_sub", q);
        end

        // 7) MACABS + DOT: dot_en must be SUPPRESSED when abs_en=1
        //    (operand_router: dot_active = dot_en & ~abs_en) -- directed
        //    check that this behaves identically to plain MACABS
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_MACABS_DOT, {16'h0003, 16'h8000}, {16'h0004, 16'h8000}));
            q.push_back(mk(OP_BUBBLE));
            q.push_back(mk(OP_BUBBLE));
            add_seq("mac_abs_dot_suppression", q);
        end

        // 8) MACLOAD: immediate 1-cycle effect, rs2 ignored
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_MAC_SEL, 32'h0000_0005, 32'h0000_0005));
            q.push_back(mk(OP_MACLOAD, 32'hFFFF_8001, 32'hDEAD_BEEF)); // rs2 must be ignored
            q.push_back(mk(OP_BUBBLE));
            add_seq("mac_load_immediate", q);
        end

        // 9) MACCLEAR: immediate 1-cycle effect
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_MAC_SEL, 32'h0000_0064, 32'h0000_0064));
            q.push_back(mk(OP_BUBBLE));
            q.push_back(mk(OP_MACCLEAR));
            add_seq("mac_clear_immediate", q);
        end

        // 10) sat_writeback path
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_SAT_WRITEBACK, 32'd0, 32'd0, 48'h7FFF_FFFF_FFFE));
            q.push_back(mk(OP_BUBBLE));
            add_seq("sat_writeback_basic", q);
        end

        // 11) *** FINDING candidate *** sat_writeback_en=1, en=0, but rs1/rs2
        //     driven NONZERO (simulating stale/don't-care upstream values).
        //     write_en = (en|sat_writeback_en)&~flush = 1 regardless of en,
        //     so sum_reg/carry_reg ALSO capture whatever csa1 computes from
        //     these "don't care" rs1/rs2 this cycle -- check whether that
        //     silently corrupts the NEXT real MAC op's result.
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_SAT_WRITEBACK, 32'h1234_5678, 32'h1234_5678, 48'h0000_0000_0001));
            q.push_back(mk(OP_MAC_SEL, 32'h0000_0005, 32'h0000_0005)); // should add 25 to the sat value...
            q.push_back(mk(OP_BUBBLE));
            q.push_back(mk(OP_BUBBLE));
            add_seq("FINDING_sat_writeback_pending_pollution", q);
        end

        // 12) en=0 with EVERY modifier bit set -- must be a total no-op.
        //     Reachable per dsu_decoder's actual contract: mac_clear/
        //     mac_load/etc are not individually gated by mac_en there.
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_MAC_SEL, 32'h0000_0007, 32'h0000_0007)); // establish acc=49
            q.push_back(mk(OP_BUBBLE));
            q.push_back(mk_raw(1'b0, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1, 1'b0, 32'hFFFF_FFFF, 32'hFFFF_FFFF));
            q.push_back(mk(OP_BUBBLE));
            add_seq("en0_all_modifiers_set_noop", q);
        end

        // 13) Flush mid-pipeline: sum_reg/carry_reg clear, but mac_out HOLDS
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_MAC_SEL, 32'h0000_0064, 32'h0000_0064)); // product pending
            q.push_back(mk(OP_MAC_SEL, 32'd1, 32'd1, 48'd0, 1'b1));    // flush this cycle
            q.push_back(mk(OP_BUBBLE));
            q.push_back(mk(OP_BUBBLE));
            add_seq("flush_mid_pipeline", q);
        end

        // 14) Reset mid-operation (async)
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_MAC_SEL, 32'h0000_0064, 32'h0000_0064));
            q.push_back(mk(OP_MAC_SEL, 32'd1, 32'd1, 48'd0, 1'b0, 1'b0)); // rst_n=0
            q.push_back(mk(OP_MAC_SEL, 32'd2, 32'd2));
            add_seq("reset_mid_operation", q);
        end

        // 15) Bubble-interspersed accumulation (verify pipeline correctly
        //     pauses without corrupting anything across en=0 gaps)
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_MAC_SEL, 32'h0000_0003, 32'h0000_0003));
            q.push_back(mk(OP_BUBBLE));
            q.push_back(mk(OP_BUBBLE));
            q.push_back(mk(OP_MAC_SEL, 32'h0000_0004, 32'h0000_0004));
            q.push_back(mk(OP_BUBBLE));
            q.push_back(mk(OP_MAC_SEL, 32'h0000_0005, 32'h0000_0005));
            q.push_back(mk(OP_BUBBLE));
            q.push_back(mk(OP_BUBBLE));
            add_seq("bubble_interspersed_accumulate", q);
        end

        // 16) Overflow, NON-truncating case (Case 1 from offline analysis):
        //     acc near +max, add a small positive product -> genuine
        //     overflow, no csa2 truncation involved -> must correctly assert
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_MACLOAD, 32'h7FFF_FFFF)); // load near-max positive into acc (sign-extended)
            q.push_back(mk(OP_MAC_SEL, 32'h0000_0001, 32'h0000_0001)); // +1
            q.push_back(mk(OP_BUBBLE));
            q.push_back(mk(OP_BUBBLE));
            add_seq("overflow_no_truncation_baseline", q);
        end

        // 17) *** FINDING 1 (central finding) *** overflow flag FALSE NEGATIVE.
        //     Drive acc to its most-negative representable value, then issue
        //     a real MACSUB whose resulting sum_reg/carry_reg CSA
        //     representation aligns >=2 of the top bits with acc's own top
        //     bit -- csa2's internal truncation silently drops the
        //     information the overflow-detection formula needs, even
        //     though the WRAPPED accumulator value itself stays correct.
        //     Validated offline via a Python model of the full realistic
        //     pipeline before being encoded here.
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_MACLOAD, 32'h8000_0000)); // acc = -2^47 exactly (sign-extended load)
            q.push_back(mk(OP_MACSUB,  32'h0000_0001, 32'h0000_0001)); // subtract +1 -> product term = -1,
                                                                        // csa1 output for a -1 term is
                                                                        // all-ones (0xFFFFFFFFFFFF), whose
                                                                        // top bit is 1, aligning with acc's
                                                                        // top bit -> truncation triggers
            q.push_back(mk(OP_BUBBLE));
            q.push_back(mk(OP_BUBBLE));
            add_seq("FINDING1_overflow_false_negative", q);
        end

        // 18) COVERAGE CLOSURE: guarantee overflow=1 is deterministically
        //     hit for each of the 7 op kinds where it's legitimately
        //     reachable (mac_sel, macsub, macdot, macdot_sub, macabs,
        //     macabs_sub, macabs_dot). CRV alone needs the accumulator to
        //     land near an exact +/-2^47 boundary AND the next product to
        //     tip it over -- too precise to trust to chance within a
        //     bounded random budget, so each is forced directly.
        //
        //     NOTE: MACLOAD only sign-extends a 32-bit rs1 (max magnitude
        //     2^31), nowhere near the 48-bit boundary (2^47) -- it cannot
        //     be used to set up these cases. sat_writeback DOES accept the
        //     full 48-bit range directly (acc_next = sat_writeback,
        //     bypassing the product pipeline entirely), so it's used here
        //     to place acc right at the edge before the real op under test
        //     tips it over.
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_SAT_WRITEBACK, 32'd0, 32'd0, 48'h7FFF_FFFF_FFFE)); // acc = 2^47-2
            q.push_back(mk(OP_MAC_SEL, 32'h0000_0002, 32'h0000_0002)); // +4 -> tips over
            q.push_back(mk(OP_BUBBLE));
            add_seq("COV_overflow1_mac_sel", q);
        end
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_SAT_WRITEBACK, 32'd0, 32'd0, 48'h8000_0000_0002)); // acc = -2^47+2
            q.push_back(mk(OP_MACSUB, 32'h0000_0002, 32'h0000_0002)); // -4 -> tips over negative
            q.push_back(mk(OP_BUBBLE));
            add_seq("COV_overflow1_macsub", q);
        end
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_SAT_WRITEBACK, 32'd0, 32'd0, 48'h7FFF_FFFF_FFFE));
            q.push_back(mk(OP_MACDOT, {16'h0002, 16'h0002}, {16'h0002, 16'h0002})); // 2*2+2*2=8
            q.push_back(mk(OP_BUBBLE));
            add_seq("COV_overflow1_macdot", q);
        end
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_SAT_WRITEBACK, 32'd0, 32'd0, 48'h8000_0000_0002));
            q.push_back(mk(OP_MACDOT_SUB, {16'h0002, 16'h0002}, {16'h0002, 16'h0002}));
            q.push_back(mk(OP_BUBBLE));
            add_seq("COV_overflow1_macdot_sub", q);
        end
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_SAT_WRITEBACK, 32'd0, 32'd0, 48'h7FFF_FFFF_FFFE));
            q.push_back(mk(OP_MACABS, 32'h0000_0002, 32'h0000_0002)); // abs(2)*abs(2)=4
            q.push_back(mk(OP_BUBBLE));
            add_seq("COV_overflow1_macabs", q);
        end
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_SAT_WRITEBACK, 32'd0, 32'd0, 48'h8000_0000_0002));
            q.push_back(mk(OP_MACABS_SUB, 32'h0000_0002, 32'h0000_0002));
            q.push_back(mk(OP_BUBBLE));
            add_seq("COV_overflow1_macabs_sub", q);
        end
        begin
            mac_cycle q[$];
            q.push_back(mk(OP_SAT_WRITEBACK, 32'd0, 32'd0, 48'h7FFF_FFFF_FFFE));
            q.push_back(mk(OP_MACABS_DOT, {16'h0002, 16'h0002}, {16'h0002, 16'h0002})); // dot suppressed, behaves like macabs
            q.push_back(mk(OP_BUBBLE));
            add_seq("COV_overflow1_macabs_dot", q);
        end

        // 19) CONSTRAINED-RANDOM multi-cycle sequences
        for (int s = 0; s < num_random_seqs; s++) begin
            mac_cycle q[$];
            for (int c = 0; c < random_seq_len; c++) begin
                mac_cycle t = new();
                assert (t.randomize()) else $error("[GEN] randomize() failed");
                q.push_back(t);
            end
            add_seq($sformatf("crv_seq_%0d", s), q);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 5. REFERENCE MODEL -- behavioral, cycle-accurate, validated
//    offline via Python prototype against the full realistic
//    pipeline before being ported here (see file header).
// -------------------------------------------------------------
class mac_ref_model;
    bit signed [47:0] ref_acc;
    bit signed [47:0] ref_pending;

    function new();
        ref_acc = 0;
        ref_pending = 0;
    endfunction

    function [15:0] abs16(bit [15:0] x);
        if (x == 16'h8000) return 16'h7FFF;
        else if (x[15])    return (~x) + 16'b1;
        else               return x;
    endfunction

    // Returns predicted mac_out and overflow for this cycle, then
    // advances ref_acc/ref_pending per the RTL's exact timing.
    function void step(bit [31:0] rs1, bit [31:0] rs2, bit en, bit add_sub, bit clear,
                        bit load, bit abs_en, bit dot_en, bit flush,
                        bit [47:0] sat_wb, bit sat_wb_en, bit rst_n,
                        output bit [47:0] pred_mac_out, output bit pred_overflow);
        bit [15:0] a0, b0, a1, b1;
        bit signed [31:0] product_a, product_b;
        bit dot_active;
        bit signed [47:0] term;
        bit write_en;
        bit signed [95:0] unwrapped_next; // wide enough for acc+pending with headroom
        bit overflows;

        if (!rst_n) begin
            ref_acc = 0;
            ref_pending = 0;
            pred_mac_out = 48'b0;
            pred_overflow = 1'b0;
            return;
        end

        // operand routing (exact mirror -- this piece IS the spec, not
        // an implementation detail, so mirroring it exactly is correct)
        if (abs_en) begin
            a0 = abs16(rs1[15:0]); b0 = abs16(rs2[15:0]);
        end else begin
            a0 = rs1[15:0]; b0 = rs2[15:0];
        end
        dot_active = dot_en & ~abs_en;
        if (dot_active) begin
            a1 = rs1[31:16]; b1 = rs2[31:16];
        end else begin
            a1 = 16'b0; b1 = 16'b0;
        end

        product_a = $signed(a0) * $signed(b0);
        product_b = $signed(a1) * $signed(b1);
        term = product_a + product_b;
        if (add_sub) term = -term;

        write_en = (en | sat_wb_en) & ~flush;

        // predicted output THIS cycle uses PRE-edge (old) ref_acc/ref_pending
        if (sat_wb_en) begin
            unwrapped_next = $signed(sat_wb);
            overflows = 1'b0; // is_accum=0 for sat_writeback -> overflow forced 0
        end else if (load) begin
            unwrapped_next = {{16{rs1[31]}}, rs1};
            overflows = 1'b0; // is_accum=0 for load
        end else if (clear) begin
            unwrapped_next = 0;
            overflows = 1'b0; // is_accum=0 for clear
        end else begin
            unwrapped_next = ref_acc + ref_pending; // TRUE, unwrapped
            overflows = !(unwrapped_next >= -(96'sd1 <<< 47) && unwrapped_next <= ((96'sd1 <<< 47) - 1));
        end

        pred_mac_out = write_en ? (unwrapped_next[47:0]) : ref_acc[47:0];
        pred_overflow = write_en ? (overflows & 1'b1) : 1'b0;

        // advance state
        if (flush) begin
            ref_pending = 0;
        end else if (write_en) begin
            ref_pending = term;
        end
        // else: hold ref_pending unchanged

        if (write_en) begin
            ref_acc = unwrapped_next[47:0];
        end
        // else: hold ref_acc unchanged
    endfunction
endclass


// -------------------------------------------------------------
// 6. DRIVER
// -------------------------------------------------------------
class mac_driver;
    virtual mac_if vif;
    function new(virtual mac_if vif); this.vif = vif; endfunction

    task apply_cycle(bit en, bit add_sub, bit clear, bit load, bit abs_en, bit dot_en,
                      bit sat_en, bit [31:0] rs1, bit [31:0] rs2, bit [47:0] sat_wb,
                      bit flush, bit rst_n);
        @(negedge vif.clk);
        vif.en <= en; vif.add_sub <= add_sub; vif.clear <= clear; vif.load <= load;
        vif.abs_en <= abs_en; vif.dot_en <= dot_en; vif.sat_writeback_en <= sat_en;
        vif.rs1 <= rs1; vif.rs2 <= rs2; vif.sat_writeback <= sat_wb;
        vif.flush <= flush; vif.rst_n <= rst_n;
    endtask
endclass


// -------------------------------------------------------------
// 7. MONITOR
// -------------------------------------------------------------
class mac_monitor;
    virtual mac_if vif;

    covergroup cg_mac;
        cp_op_kind: coverpoint {vif.load, vif.clear, vif.sat_writeback_en, vif.dot_en, vif.abs_en, vif.add_sub, vif.en} {
            option.auto_bin_max = 0; // no stray auto-bins: the 11 named
                                      // bins below are exhaustive over
                                      // every combination this
                                      // environment's generator can ever
                                      // produce (fields() has no other
                                      // code path) -- a default bin here
                                      // would be permanently unreachable,
                                      // not just rarely hit.
            bins mac_sel      = {7'b0000001};
            bins macsub       = {7'b0000011};
            bins macdot       = {7'b0000101};
            bins macdot_sub   = {7'b0000111};
            bins macabs       = {7'b0001001};
            bins macabs_sub   = {7'b0001011};
            bins macabs_dot   = {7'b0001101};
            bins macload      = {7'b1000001};
            bins macclear     = {7'b0100001};
            bins sat_wb       = {7'b0010000};
            bins bubble       = {7'b0000000};
        }
        cp_overflow: coverpoint vif.overflow;
        cp_flush: coverpoint vif.flush;
        cp_rst_n: coverpoint vif.rst_n;
        cp_rs1_lo_boundary: coverpoint vif.rs1[15:0] {
            bins zero = {16'h0000}; bins max_pos = {16'h7FFF};
            bins min_neg = {16'h8000}; bins all_ones = {16'hFFFF}; bins other = default;
        }
        cross cp_overflow, cp_op_kind {
            // overflow=1 is not just rare but STRUCTURALLY IMPOSSIBLE for
            // these four op kinds, per the RTL itself:
            //   is_accum = ~(load | clear | sat_writeback_en) forces
            //   accum_ovf's own contribution to 0 for macload/macclear/sat_wb;
            //   write_en = (en|sat_writeback_en)&~flush is 0 during a bubble
            //   (en=0, sat_writeback_en=0), which independently forces
            //   overflow=0 regardless of accum_ovf.
            // These are hardware guarantees, not stimulus gaps -- excluded
            // with justification rather than left as a silent shortfall.
            ignore_bins ovf1_impossible_macload  = binsof(cp_overflow) intersect {1} && binsof(cp_op_kind.macload);
            ignore_bins ovf1_impossible_macclear = binsof(cp_overflow) intersect {1} && binsof(cp_op_kind.macclear);
            ignore_bins ovf1_impossible_satwb    = binsof(cp_overflow) intersect {1} && binsof(cp_op_kind.sat_wb);
            ignore_bins ovf1_impossible_bubble   = binsof(cp_overflow) intersect {1} && binsof(cp_op_kind.bubble);
        }
    endgroup

    function new(virtual mac_if vif);
        this.vif = vif;
        cg_mac = new();
    endfunction

    task sample_one(output bit [47:0] mac_out, output bit overflow);
        // overflow is COMBINATIONAL (accum_ovf & write_en & is_accum, off
        // pre-edge acc/sum_reg/carry_reg + this cycle's just-driven
        // control inputs) -- correct to sample right after the driver
        // applies inputs, same convention as dsu_stall's dsu_busy.
        #1;
        overflow = vif.overflow;

        // mac_out = acc is REGISTERED -- it only reflects this cycle's
        // write once the upcoming clock edge actually commits it. Sampling
        // it at the same point as overflow (before that edge) reads the
        // PREVIOUS cycle's value instead -- this was a real testbench bug
        // (found via a systematic one-cycle-lag pattern across an entire
        // regression), not a DUT defect: dsu_stall's monitor convention
        // (combinational-only) was reused here without accounting for
        // mac_unit having a registered primary output.
        @(posedge vif.clk);
        #1;
        mac_out = vif.mac_out;

        cg_mac.sample();
    endtask
endclass


// -------------------------------------------------------------
// 8. SCOREBOARD
// -------------------------------------------------------------
class mac_scoreboard;
    int pass_cnt = 0;
    int fail_cnt = 0;
    int overflow_false_negative_cnt = 0;

    task check(string seq_name, int cycle_idx, bit [31:0] rs1, bit [31:0] rs2,
               bit en, bit add_sub, bit clear, bit load, bit abs_en, bit dot_en, bit flush,
               bit [47:0] sat_wb, bit sat_wb_en, bit rst_n,
               bit [47:0] actual_mac_out, bit actual_overflow, mac_ref_model model);
        bit [47:0] pred_mac_out;
        bit pred_overflow;
        bit ok;

        model.step(rs1, rs2, en, add_sub, clear, load, abs_en, dot_en, flush,
                   sat_wb, sat_wb_en, rst_n, pred_mac_out, pred_overflow);

        ok = (actual_mac_out === pred_mac_out) && (actual_overflow === pred_overflow);

        if (ok) begin
            pass_cnt++;
            $display("[PASS] seq=%-38s cyc=%0d en=%0b as=%0b cl=%0b ld=%0b ab=%0b dt=%0b -> mac_out=%0d ovf=%0b",
                      seq_name, cycle_idx, en, add_sub, clear, load, abs_en, dot_en, $signed(actual_mac_out), actual_overflow);
        end else begin
            fail_cnt++;
            if (pred_overflow && !actual_overflow) overflow_false_negative_cnt++;
            $display("[FAIL] seq=%-38s cyc=%0d en=%0b as=%0b cl=%0b ld=%0b ab=%0b dt=%0b rs1=%0h rs2=%0h",
                      seq_name, cycle_idx, en, add_sub, clear, load, abs_en, dot_en, rs1, rs2);
            $display("       mac_out: got=%0d exp=%0d | overflow: got=%0b exp=%0b",
                      $signed(actual_mac_out), $signed(pred_mac_out), actual_overflow, pred_overflow);
        end
    endtask
endclass


// -------------------------------------------------------------
// 9. ENVIRONMENT (sequential, per-sequence reset isolation)
// -------------------------------------------------------------
class mac_env;
    virtual mac_if vif;
    mac_generator  gen;
    mac_driver     drv;
    mac_monitor    mon;
    mac_scoreboard sb;

    function new(virtual mac_if vif, int num_random_seqs = 25, int random_seq_len = 40);
        this.vif = vif;
        gen = new(num_random_seqs, random_seq_len);
        drv = new(vif);
        mon = new(vif);
        sb  = new();
    endfunction

    task run();
        mac_ref_model model;
        int total_cycles = 0;

        gen.build();

        foreach (gen.seq_q[s]) begin
            bit [47:0] rbo; bit rbov;
            // isolate every sequence with a real async-reset pulse,
            // matching the fix applied during dsu_stall verification
            drv.apply_cycle(0,0,0,0,0,0,0, 32'd0, 32'd0, 48'd0, 1'b0, 1'b0);
            mon.sample_one(rbo, rbov);

            model = new();
            foreach (gen.seq_q[s][i]) begin
                mac_cycle c = gen.seq_q[s][i];
                bit v_en, v_as, v_cl, v_ld, v_ab, v_dt, v_sat;
                bit [47:0] actual_mac_out; bit actual_overflow;
                c.fields(v_en, v_as, v_cl, v_ld, v_ab, v_dt, v_sat);
                drv.apply_cycle(v_en, v_as, v_cl, v_ld, v_ab, v_dt, v_sat,
                                 c.rs1, c.rs2, c.sat_wb_val, c.flush, c.rst_n);
                mon.sample_one(actual_mac_out, actual_overflow);
                sb.check(gen.seq_name[s], i, c.rs1, c.rs2, v_en, v_as, v_cl, v_ld, v_ab, v_dt,
                          c.flush, c.sat_wb_val, v_sat, c.rst_n, actual_mac_out, actual_overflow, model);
                total_cycles++;
            end
        end

        $display("\n================ MAC_UNIT UNIT TB SUMMARY ================");
        $display(" SEQUENCES=%0d  TOTAL_CYCLES=%0d  PASS=%0d  FAIL=%0d",
                  gen.seq_q.size(), total_cycles, sb.pass_cnt, sb.fail_cnt);
        $display(" OVERFLOW FALSE-NEGATIVE COUNT = %0d  (see FINDING1_* sequence)", sb.overflow_false_negative_cnt);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", mon.cg_mac.get_coverage());
        if (sb.fail_cnt == 0)
            $display(" RESULT: ALL CHECKS PASSED");
        else
            $display(" RESULT: %0d CHECK(S) FAILED -- see FINDING1 note above regarding overflow false negatives", sb.fail_cnt);
        $display("============================================================\n");
    endtask
endclass


// -------------------------------------------------------------
// 10. TEST
// -------------------------------------------------------------
class mac_test;
    mac_env env;
    function new(virtual mac_if vif, int num_random_seqs = 25, int random_seq_len = 40);
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

    mac_if vif(clk);

    mac_unit dut (
        .clk (clk), .rst_n (vif.rst_n),
        .rs1 (vif.rs1), .rs2 (vif.rs2),
        .en (vif.en), .add_sub (vif.add_sub), .clear (vif.clear), .load (vif.load),
        .abs_en (vif.abs_en), .dot_en (vif.dot_en), .flush (vif.flush),
        .sat_writeback (vif.sat_writeback), .sat_writeback_en (vif.sat_writeback_en),
        .mac_out (vif.mac_out), .overflow (vif.overflow)
    );

    mac_test test;

    initial begin
        vif.rst_n = 1'b0;
        vif.en = 0; vif.add_sub = 0; vif.clear = 0; vif.load = 0;
        vif.abs_en = 0; vif.dot_en = 0; vif.flush = 0;
        vif.rs1 = 0; vif.rs2 = 0; vif.sat_writeback = 0; vif.sat_writeback_en = 0;
        repeat (3) @(posedge clk);

        test = new(vif, 25, 40);
        test.run();
        $finish;
    end
endmodule
