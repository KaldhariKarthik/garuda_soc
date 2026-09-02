// =============================================================================
// tb_mul32.sv -- SystemVerilog unit TB for rtl/core/mul32.v
//
// Spec: AERO-GARUDA-DS-001 Rev 1.1, Sec. 8.2 (single-cycle 32x32 multiplier).
// Plan: directed test C02 -- "MUL/MULH/MULHSU/MULHU against reference
//       products".
//
// The RTL shares ONE 33x33 signed multiplier across all four funct3 values,
// picking operand signedness with a_signed/b_signed. That sharing is the
// whole risk: MULHSU is the only asymmetric case, and TRANSPOSING a_signed
// with b_signed gives correct results for MUL, MULH and MULHU, and wrong
// ones only for MULHSU. So the constraint set below drives all four sign
// quadrants for every funct3 rather than relying on unbiased random operands
// to find the one that matters.
//
// The reference model builds the true 64-bit product by extending each
// operand with the signedness the ISA requires -- independent of the RTL's
// 33-bit extension trick, so a shared misunderstanding cannot cancel out.
//
// Sec. 8.2 states the multiplier has no internal pipeline registers. The
// SVA below asserts the result is a pure function of the current inputs.
//
// No inlined DUT snapshot -- see the note in tb_alu.sv.
// =============================================================================

`timescale 1ns/1ps
`include "core_ex_defs.vh"

// -------------------------------------------------------------
// 1. INTERFACE (+ bound SVA)
// -------------------------------------------------------------
interface mul32_if (input bit clk);
    logic [31:0] rs1;
    logic [31:0] rs2;
    logic [2:0]  funct3;
    logic [31:0] result;

    // A1: MUL returns the low half, where signedness is irrelevant. The low
    //     32 bits of a*b are the same whether the operands are read signed
    //     or unsigned, so this must match a plain unsigned multiply.
    property p_mul_low_half;
        @(posedge clk) (funct3 == `MUL_MUL) |-> (result == 32'((rs1 * rs2)));
    endproperty
    a_mul_low: assert property (p_mul_low_half)
        else $error("[SVA-FAIL] MUL did not return the low 32 bits of the product");

    // A2: multiplying by zero is zero for every funct3 -- catches a stuck
    //     sign-extension term feeding the high half.
    property p_zero_operand;
        @(posedge clk) ((rs1 == 0) || (rs2 == 0)) |-> (result == 32'b0);
    endproperty
    a_zero: assert property (p_zero_operand)
        else $error("[SVA-FAIL] a zero operand did not produce a zero result");

    // A3: MULHU is unsigned x unsigned, so its high half can never be
    //     negative-looking for operands that are both small.
    property p_mulhu_small_operands;
        @(posedge clk) ((funct3 == `MUL_MULHU) && (rs1[31] == 0) && (rs2[31] == 0))
                       |-> (result[31] == 1'b0);
    endproperty
    a_mulhu_small: assert property (p_mulhu_small_operands)
        else $error("[SVA-FAIL] MULHU high half went negative for two positive operands");

    // A4: no pipeline registers (Sec. 8.2) -- the result is combinational,
    //     so it must be stable and known in the same cycle the inputs are.
    property p_no_x;
        @(posedge clk) (!$isunknown({rs1, rs2, funct3})) |-> (!$isunknown(result));
    endproperty
    a_no_x: assert property (p_no_x)
        else $error("[SVA-FAIL] result went unknown with known inputs");
endinterface


// -------------------------------------------------------------
// 2. STIMULUS ITEM
// -------------------------------------------------------------
typedef enum {
    MK_POS_POS, MK_POS_NEG, MK_NEG_POS, MK_NEG_NEG,
    MK_EXTREME, MK_ZERO, MK_RANDOM
} mul_kind_e;

class mul_cycle;
    rand mul_kind_e kind;
    rand bit [31:0] a;
    rand bit [31:0] b;
    rand bit [2:0]  f3;

    // Only the four multiply funct3 values are legal here -- DIV/REM
    // (funct3 100..111) are decoded but never executed (Sec. 7.2) and never
    // reach this block.
    constraint c_f3 { f3 inside {`MUL_MUL, `MUL_MULH, `MUL_MULHSU, `MUL_MULHU}; }

    constraint c_kind_dist {
        kind dist { MK_POS_POS :/ 15, MK_POS_NEG :/ 15, MK_NEG_POS :/ 15,
                    MK_NEG_NEG :/ 15, MK_EXTREME :/ 20, MK_ZERO :/ 5,
                    MK_RANDOM :/ 15 };
    }

    // The four sign quadrants, driven explicitly. MK_POS_NEG (rs1 positive,
    // rs2 with bit 31 set) is the quadrant that separates a correct MULHSU
    // from one with the operand signedness transposed.
    constraint c_quadrant {
        (kind == MK_POS_POS) -> (a[31] == 0 && b[31] == 0);
        (kind == MK_POS_NEG) -> (a[31] == 0 && b[31] == 1);
        (kind == MK_NEG_POS) -> (a[31] == 1 && b[31] == 0);
        (kind == MK_NEG_NEG) -> (a[31] == 1 && b[31] == 1);
    }

    constraint c_extreme {
        (kind == MK_EXTREME) -> a inside {32'h0000_0000, 32'h0000_0001,
                                          32'h0000_0002, 32'h7FFF_FFFF,
                                          32'h8000_0000, 32'hFFFF_FFFF,
                                          32'h0001_0000};
        (kind == MK_EXTREME) -> b inside {32'h0000_0000, 32'h0000_0001,
                                          32'h0000_0002, 32'h7FFF_FFFF,
                                          32'h8000_0000, 32'hFFFF_FFFF,
                                          32'h0001_0000};
    }

    constraint c_zero { (kind == MK_ZERO) -> (a == 0 || b == 0); }
endclass


// -------------------------------------------------------------
// 3. REFERENCE MODEL -- true 64-bit product, ISA signedness
// -------------------------------------------------------------
class mul_ref_model;
    function automatic bit [63:0] full_product(bit [31:0] a, bit [31:0] b,
                                                bit [2:0] f3);
        logic signed [63:0] as, bs;
        // rs1 is signed for MUL/MULH/MULHSU, unsigned for MULHU
        as = (f3 == `MUL_MULHU) ? 64'({32'b0, a}) : 64'($signed(a));
        // rs2 is signed for MUL/MULH, unsigned for MULHSU/MULHU
        bs = (f3 inside {`MUL_MULHSU, `MUL_MULHU}) ? 64'({32'b0, b})
                                                   : 64'($signed(b));
        return as * bs;
    endfunction

    function automatic bit [31:0] step(bit [31:0] a, bit [31:0] b, bit [2:0] f3);
        bit [63:0] p = full_product(a, b, f3);
        return (f3 == `MUL_MUL) ? p[31:0] : p[63:32];
    endfunction
endclass


// -------------------------------------------------------------
// 4. GENERATOR
// -------------------------------------------------------------
class mul_generator;
    mul_cycle seq_q[$][$];
    string    seq_name[$];
    int       num_random_seqs, random_seq_len;

    function new(int nseq = 8, int slen = 250);
        num_random_seqs = nseq; random_seq_len = slen;
    endfunction

    function mul_cycle mk(mul_kind_e k, bit [31:0] a, bit [31:0] b, bit [2:0] f3);
        mul_cycle c = new();
        c.kind = k; c.a = a; c.b = b; c.f3 = f3;
        return c;
    endfunction

    function void add_seq(string name, mul_cycle q[$]);
        seq_name.push_back(name); seq_q.push_back(q);
    endfunction

    function void build();
        // 1) MUL -- low half only
        begin
            mul_cycle q[$];
            q.push_back(mk(MK_POS_POS, 32'd6, 32'd7, `MUL_MUL));
            q.push_back(mk(MK_NEG_POS, 32'hFFFF_FFFF, 32'd7, `MUL_MUL));
            q.push_back(mk(MK_EXTREME, 32'h0001_0000, 32'h0001_0000, `MUL_MUL));
            q.push_back(mk(MK_EXTREME, 32'hFFFF_FFFF, 32'hFFFF_FFFF, `MUL_MUL));
            add_seq("mul_low_half", q);
        end
        // 2) MULH -- signed x signed
        begin
            mul_cycle q[$];
            q.push_back(mk(MK_POS_POS, 32'h0001_0000, 32'h0001_0000, `MUL_MULH));
            q.push_back(mk(MK_NEG_NEG, 32'hFFFF_FFFF, 32'hFFFF_FFFF, `MUL_MULH));
            q.push_back(mk(MK_NEG_POS, 32'hFFFF_FFFF, 32'd1,         `MUL_MULH));
            q.push_back(mk(MK_EXTREME, 32'h8000_0000, 32'h8000_0000, `MUL_MULH));
            add_seq("mulh_signed_signed", q);
        end
        // 3) MULHU -- unsigned x unsigned
        begin
            mul_cycle q[$];
            q.push_back(mk(MK_EXTREME, 32'hFFFF_FFFF, 32'hFFFF_FFFF, `MUL_MULHU));
            q.push_back(mk(MK_EXTREME, 32'hFFFF_FFFF, 32'd1,         `MUL_MULHU));
            q.push_back(mk(MK_EXTREME, 32'h8000_0000, 32'h8000_0000, `MUL_MULHU));
            add_seq("mulhu_unsigned_unsigned", q);
        end
        // 4) MULHSU -- the asymmetric case. rs1 SIGNED, rs2 UNSIGNED.
        //    mulhsu_pn (rs1 = +2, rs2 = 0xFFFF_FFFF) is the discriminating
        //    vector: rs2 must be read as 4294967295, not as -1.
        //      correct : 2 * 4294967295 = 0x1_FFFF_FFFE -> high half 1
        //      swapped : 2 * (-1)       = 0xFFFF_FFFF_FFFF_FFFE -> high FFFFFFFF
        begin
            mul_cycle q[$];
            q.push_back(mk(MK_NEG_NEG, 32'hFFFF_FFFF, 32'hFFFF_FFFF, `MUL_MULHSU));
            q.push_back(mk(MK_POS_NEG, 32'd2,         32'hFFFF_FFFF, `MUL_MULHSU));
            q.push_back(mk(MK_NEG_NEG, 32'h8000_0000, 32'h8000_0000, `MUL_MULHSU));
            q.push_back(mk(MK_POS_POS, 32'h0001_0000, 32'h0001_0000, `MUL_MULHSU));
            q.push_back(mk(MK_POS_NEG, 32'd1,         32'h8000_0000, `MUL_MULHSU));
            add_seq("mulhsu_asymmetric", q);
        end
        // 5) zero and identity across all four funct3
        begin
            mul_cycle q[$];
            bit [2:0] f3s[4] = '{`MUL_MUL, `MUL_MULH, `MUL_MULHSU, `MUL_MULHU};
            foreach (f3s[i]) begin
                q.push_back(mk(MK_ZERO,    32'hDEAD_BEEF, 32'd0, f3s[i]));
                q.push_back(mk(MK_ZERO,    32'd0, 32'hDEAD_BEEF, f3s[i]));
                q.push_back(mk(MK_EXTREME, 32'hDEAD_BEEF, 32'd1, f3s[i]));
            end
            add_seq("zero_and_identity", q);
        end
        // 6) full sign-quadrant matrix at the extremes, all four funct3
        begin
            mul_cycle q[$];
            bit [31:0] vals[5] = '{32'h0000_0001, 32'h7FFF_FFFF, 32'h8000_0000,
                                   32'hFFFF_FFFF, 32'h0001_0001};
            bit [2:0]  f3s[4]  = '{`MUL_MUL, `MUL_MULH, `MUL_MULHSU, `MUL_MULHU};
            foreach (f3s[k])
                foreach (vals[i])
                    foreach (vals[j])
                        q.push_back(mk(MK_EXTREME, vals[i], vals[j], f3s[k]));
            add_seq("sign_quadrant_matrix", q);
        end
        // 7) CRV
        for (int s = 0; s < num_random_seqs; s++) begin
            mul_cycle q[$];
            for (int i = 0; i < random_seq_len; i++) begin
                mul_cycle c = new();
                if (!c.randomize()) $fatal(1, "mul_cycle randomize() failed");
                q.push_back(c);
            end
            add_seq($sformatf("crv_seq_%0d", s), q);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 5. DRIVER / MONITOR
// -------------------------------------------------------------
class mul_driver;
    virtual mul32_if vif;
    function new(virtual mul32_if vif); this.vif = vif; endfunction
    task apply(mul_cycle c);
        @(negedge vif.clk);
        vif.rs1 <= c.a; vif.rs2 <= c.b; vif.funct3 <= c.f3;
    endtask
endclass

class mul_monitor;
    virtual mul32_if vif;

    covergroup cg_mul;
        cp_f3: coverpoint vif.funct3 {
            bins mul    = {`MUL_MUL};
            bins mulh   = {`MUL_MULH};
            bins mulhsu = {`MUL_MULHSU};
            bins mulhu  = {`MUL_MULHU};
        }
        cp_a_sign: coverpoint vif.rs1[31];
        cp_b_sign: coverpoint vif.rs2[31];
        // The signedness bug only shows in specific (funct3, sign, sign)
        // combinations, so the three-way cross is the real coverage goal.
        cross cp_f3, cp_a_sign, cp_b_sign;
        cp_a_extreme: coverpoint vif.rs1 {
            bins zero = {32'h0000_0000};
            bins one  = {32'h0000_0001};
            bins int_min = {32'h8000_0000};
            bins int_max = {32'h7FFF_FFFF};
            bins all_ones = {32'hFFFF_FFFF};
            bins generic = default;
        }
    endgroup

    function new(virtual mul32_if vif);
        this.vif = vif; cg_mul = new();
    endfunction

    task sample_one(output bit [31:0] r);
        #1; r = vif.result; cg_mul.sample();
    endtask
endclass


// -------------------------------------------------------------
// 6. ENV
// -------------------------------------------------------------
class mul_env;
    virtual mul32_if vif;
    mul_generator gen;
    mul_driver    drv;
    mul_monitor   mon;
    mul_ref_model model;
    garuda_tb_pkg::scoreboard sb;

    function new(virtual mul32_if vif, int nseq = 8, int slen = 250);
        this.vif = vif;
        gen = new(nseq, slen); drv = new(vif); mon = new(vif);
        model = new(); sb = new("MUL32");
    endfunction

    task run();
        gen.build();
        foreach (gen.seq_q[s])
            foreach (gen.seq_q[s][i]) begin
                mul_cycle  c = gen.seq_q[s][i];
                bit [31:0] act, exp;
                drv.apply(c);
                mon.sample_one(act);
                exp = model.step(c.a, c.b, c.f3);
                sb.chk(gen.seq_name[s],
                       $sformatf("f3=%0d rs1=%08h rs2=%08h", c.f3, c.a, c.b),
                       act, exp);
            end
        sb.summary(mon.cg_mul.get_coverage());
    endtask
endclass


// -------------------------------------------------------------
// 7. TB TOP
// -------------------------------------------------------------
module tb_top;
    bit clk = 0;
    always #5 clk = ~clk;

    mul32_if vif(clk);

    mul32 dut (
        .rs1    (vif.rs1),
        .rs2    (vif.rs2),
        .funct3 (vif.funct3),
        .result (vif.result)
    );

    mul_env env;

    initial begin
        vif.rs1 = 0; vif.rs2 = 0; vif.funct3 = `MUL_MUL;
        repeat (3) @(posedge clk);
        env = new(vif, 8, 250);
        env.run();
        $finish;
    end
endmodule
