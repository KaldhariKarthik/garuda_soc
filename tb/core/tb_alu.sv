// =============================================================================
// tb_alu.sv -- SystemVerilog unit TB for rtl/core/alu.v
//
// Spec: AERO-GARUDA-DS-001 Rev 1.1, Sec. 8.1 (32-bit combinational ALU).
// Plan: supports C01 (RV32I base ISA) and C05 (dependent ALU chains) at the
//       unit level. Every op is checked against an independent golden
//       expression written from the spec text, so a swapped encoding in
//       garuda_defs.vh cannot pass.
//
// Structure follows tb_imm_gen.sv: interface + bound SVA, rand/constraint
// stimulus class, generator with directed sequences plus CRV, reference
// model, driver, monitor with covergroup, shared scoreboard. Top is tb_top.
//
// NOTE ON THE INLINED DUT COPY: the older unit TBs each paste a snapshot of
// their DUT under `ifndef GARUDA_REAL_RTL. tb_imm_gen.sv's own header records
// that its snapshot HAD ALREADY DRIFTED from rtl/core, so "a green run
// against it proves nothing about the RTL that actually ships". This file
// carries no snapshot: tb/core/filelist_alu.f always binds the real
// rtl/core/alu.v, which is the only configuration worth reporting a result
// from.
//
// Discriminating vectors (a plausible wrong ALU cannot pass these):
//   * shift by 32 / 33 / 0xFFFF_FFE1 -- the shift amount is op_b[4:0] ONLY.
//     A shifter fed the full op_b returns 0 and passes a naive directed test.
//   * SLT vs SLTU on (0xFFFF_FFFF, 1) -- separates signed from unsigned.
//   * ALU_PASSB with a non-zero op_a -- the LUI leg must ignore op_a. This is
//     the encoding garuda_defs.vh's header says drifted once already.
// =============================================================================

`timescale 1ns/1ps
`include "garuda_defs.vh"

// -------------------------------------------------------------
// 1. INTERFACE (+ bound SVA)
// -------------------------------------------------------------
interface alu_if (input bit clk);
    logic [31:0] op_a;
    logic [31:0] op_b;
    logic [3:0]  alu_op;
    logic [31:0] result;

    // A1: the shift amount is op_b[4:0]. Stated as a property so it holds on
    //     every cycle of every sequence, not only the directed shift vectors.
    property p_shift_uses_low5;
        @(posedge clk) (alu_op == `ALU_SLL) |-> (result == (op_a << op_b[4:0]));
    endproperty
    a_sll_low5: assert property (p_shift_uses_low5)
        else $error("[SVA-FAIL] SLL did not mask the shift amount to op_b[4:0]");

    property p_srl_uses_low5;
        @(posedge clk) (alu_op == `ALU_SRL) |-> (result == (op_a >> op_b[4:0]));
    endproperty
    a_srl_low5: assert property (p_srl_uses_low5)
        else $error("[SVA-FAIL] SRL did not mask the shift amount to op_b[4:0]");

    // A2: SRA replicates the sign bit; SRL never does. A shift-right of a
    //     negative value by a non-zero amount must differ between the two.
    property p_sra_is_arithmetic;
        @(posedge clk) ((alu_op == `ALU_SRA) && op_a[31] && (op_b[4:0] != 0))
                       |-> result[31];
    endproperty
    a_sra_arith: assert property (p_sra_is_arithmetic)
        else $error("[SVA-FAIL] SRA of a negative value did not keep the sign bit");

    // A3: the comparison ops are Boolean -- bits [31:1] must be clear, or a
    //     downstream branch on the result reads garbage.
    property p_compare_is_boolean;
        @(posedge clk) (alu_op inside {`ALU_SLT, `ALU_SLTU})
                       |-> (result[31:1] == 31'b0);
    endproperty
    a_cmp_bool: assert property (p_compare_is_boolean)
        else $error("[SVA-FAIL] SLT/SLTU returned a non-Boolean result");

    // A4: LUI leg -- result is op_b regardless of op_a (Sec. 8.1).
    property p_passb_ignores_a;
        @(posedge clk) (alu_op == `ALU_PASSB) |-> (result == op_b);
    endproperty
    a_passb: assert property (p_passb_ignores_a)
        else $error("[SVA-FAIL] ALU_PASSB did not pass op_b through unchanged");

    // A5: X-propagation.
    property p_no_x;
        @(posedge clk) (!$isunknown({op_a, op_b, alu_op})) |-> (!$isunknown(result));
    endproperty
    a_no_x: assert property (p_no_x)
        else $error("[SVA-FAIL] result went unknown with known inputs");
endinterface


// -------------------------------------------------------------
// 2. STIMULUS ITEM -- rand + constraints
// -------------------------------------------------------------
typedef enum {
    AK_ARITH, AK_LOGIC, AK_SHIFT, AK_COMPARE, AK_PASSB, AK_UNMAPPED,
    AK_SHIFT_BOUNDARY, AK_SIGN_BOUNDARY, AK_RANDOM
} alu_kind_e;

class alu_cycle;
    rand alu_kind_e   kind;
    rand bit [31:0]   a;
    rand bit [31:0]   b;
    rand bit [3:0]    op;

    constraint c_kind_dist {
        kind dist { AK_ARITH :/ 10, AK_LOGIC :/ 10, AK_SHIFT :/ 15,
                    AK_COMPARE :/ 15, AK_PASSB :/ 5, AK_UNMAPPED :/ 5,
                    AK_SHIFT_BOUNDARY :/ 15, AK_SIGN_BOUNDARY :/ 10,
                    AK_RANDOM :/ 15 };
    }

    constraint c_op_matches_kind {
        (kind == AK_ARITH)   -> op inside {`ALU_ADD, `ALU_SUB};
        (kind == AK_LOGIC)   -> op inside {`ALU_AND, `ALU_OR, `ALU_XOR};
        (kind == AK_SHIFT)   -> op inside {`ALU_SLL, `ALU_SRL, `ALU_SRA};
        (kind == AK_COMPARE) -> op inside {`ALU_SLT, `ALU_SLTU};
        (kind == AK_PASSB)   -> op == `ALU_PASSB;
        // 4'hB..4'hF are unmapped: Sec. 8.1 says they fall back to ADD.
        (kind == AK_UNMAPPED)         -> op inside {[4'hB:4'hF]};
        (kind == AK_SHIFT_BOUNDARY)   -> op inside {`ALU_SLL, `ALU_SRL, `ALU_SRA};
        (kind == AK_SIGN_BOUNDARY)    -> op inside {`ALU_SLT, `ALU_SLTU,
                                                    `ALU_ADD, `ALU_SUB};
        (kind == AK_RANDOM)           -> op inside {[4'h0:4'hF]};
    }

    // Shift boundaries: cluster op_b around the 5-bit wrap point so the
    // masking behaviour is hit far more often than $random would give.
    constraint c_shift_boundary {
        (kind == AK_SHIFT_BOUNDARY) -> b inside {0, 1, 30, 31, 32, 33, 63, 64,
                                                 32'hFFFF_FFE0, 32'hFFFF_FFE1,
                                                 32'hFFFF_FFFF};
    }

    // Sign boundaries: the values where signed and unsigned interpretations
    // diverge.
    constraint c_sign_boundary {
        (kind == AK_SIGN_BOUNDARY) -> a inside {32'h0000_0000, 32'h0000_0001,
                                                32'h7FFF_FFFF, 32'h8000_0000,
                                                32'hFFFF_FFFF};
        (kind == AK_SIGN_BOUNDARY) -> b inside {32'h0000_0000, 32'h0000_0001,
                                                32'h7FFF_FFFF, 32'h8000_0000,
                                                32'hFFFF_FFFF};
    }
endclass


// -------------------------------------------------------------
// 3. REFERENCE MODEL -- written from Sec. 8.1, not from the RTL case
// -------------------------------------------------------------
class alu_ref_model;
    function automatic bit [31:0] step(bit [31:0] a, bit [31:0] b, bit [3:0] op);
        bit [4:0] sh = b[4:0];
        case (op)
            `ALU_ADD:   return a + b;
            `ALU_SUB:   return a - b;
            `ALU_AND:   return a & b;
            `ALU_OR:    return a | b;
            `ALU_XOR:   return a ^ b;
            `ALU_SLL:   return a << sh;
            `ALU_SRL:   return a >> sh;
            `ALU_SRA:   return $signed(a) >>> sh;
            `ALU_SLT:   return {31'b0, ($signed(a) < $signed(b))};
            `ALU_SLTU:  return {31'b0, (a < b)};
            `ALU_PASSB: return b;
            default:    return a + b;      // Sec. 8.1 safe default
        endcase
    endfunction
endclass


// -------------------------------------------------------------
// 4. GENERATOR -- directed sequences then CRV
// -------------------------------------------------------------
class alu_generator;
    alu_cycle seq_q[$][$];
    string    seq_name[$];
    int       num_random_seqs;
    int       random_seq_len;

    function new(int num_random_seqs = 8, int random_seq_len = 250);
        this.num_random_seqs = num_random_seqs;
        this.random_seq_len  = random_seq_len;
    endfunction

    function alu_cycle mk(alu_kind_e k, bit [31:0] a, bit [31:0] b, bit [3:0] op);
        alu_cycle c = new();
        c.kind = k; c.a = a; c.b = b; c.op = op;
        return c;
    endfunction

    function void add_seq(string name, alu_cycle q[$]);
        seq_name.push_back(name); seq_q.push_back(q);
    endfunction

    function void build();
        // 1) arithmetic, including wrap in both directions
        begin
            alu_cycle q[$];
            q.push_back(mk(AK_ARITH, 32'd7,          32'd5, `ALU_ADD));
            q.push_back(mk(AK_ARITH, 32'hFFFF_FFFF,  32'd1, `ALU_ADD));   // wrap
            q.push_back(mk(AK_ARITH, 32'd7,          32'd5, `ALU_SUB));
            q.push_back(mk(AK_ARITH, 32'd0,          32'd1, `ALU_SUB));   // borrow
            q.push_back(mk(AK_ARITH, 32'h8000_0000,  32'h8000_0000, `ALU_ADD));
            add_seq("arith", q);
        end
        // 2) logic ops with a pattern that makes each distinguishable
        begin
            alu_cycle q[$];
            q.push_back(mk(AK_LOGIC, 32'hF0F0_AAAA, 32'h0FF0_5555, `ALU_AND));
            q.push_back(mk(AK_LOGIC, 32'hF0F0_AAAA, 32'h0FF0_5555, `ALU_OR));
            q.push_back(mk(AK_LOGIC, 32'hF0F0_AAAA, 32'h0FF0_5555, `ALU_XOR));
            add_seq("logic", q);
        end
        // 3) shift amount is op_b[4:0] ONLY -- the discriminating sequence
        begin
            alu_cycle q[$];
            q.push_back(mk(AK_SHIFT, 32'h0000_0001, 32'd1,  `ALU_SLL));
            q.push_back(mk(AK_SHIFT, 32'h0000_0001, 32'd31, `ALU_SLL));
            q.push_back(mk(AK_SHIFT_BOUNDARY, 32'h0000_00FF, 32'd32, `ALU_SLL));
            q.push_back(mk(AK_SHIFT_BOUNDARY, 32'h0000_00FF, 32'd33, `ALU_SLL));
            q.push_back(mk(AK_SHIFT_BOUNDARY, 32'h0000_00FF, 32'hFFFF_FFE1, `ALU_SLL));
            q.push_back(mk(AK_SHIFT, 32'h8000_0000, 32'd31, `ALU_SRL));
            q.push_back(mk(AK_SHIFT_BOUNDARY, 32'hDEAD_BEEF, 32'd32, `ALU_SRL));
            q.push_back(mk(AK_SHIFT, 32'h8000_0000, 32'd31, `ALU_SRA));
            q.push_back(mk(AK_SHIFT, 32'h4000_0000, 32'd30, `ALU_SRA));
            q.push_back(mk(AK_SHIFT_BOUNDARY, 32'hFFFF_0000, 32'd32, `ALU_SRA));
            add_seq("shift_amount_masking", q);
        end
        // 4) signed vs unsigned compare
        begin
            alu_cycle q[$];
            q.push_back(mk(AK_COMPARE, 32'hFFFF_FFFF, 32'd1, `ALU_SLT));   // -1 < 1
            q.push_back(mk(AK_COMPARE, 32'hFFFF_FFFF, 32'd1, `ALU_SLTU));  // 4G > 1
            q.push_back(mk(AK_COMPARE, 32'd5, 32'd5, `ALU_SLT));
            q.push_back(mk(AK_COMPARE, 32'd5, 32'd5, `ALU_SLTU));
            q.push_back(mk(AK_COMPARE, 32'd4, 32'd5, `ALU_SLT));
            q.push_back(mk(AK_COMPARE, 32'h8000_0000, 32'h7FFF_FFFF, `ALU_SLT));
            q.push_back(mk(AK_COMPARE, 32'h8000_0000, 32'h7FFF_FFFF, `ALU_SLTU));
            add_seq("signed_vs_unsigned_compare", q);
        end
        // 5) LUI leg: op_a must be ignored
        begin
            alu_cycle q[$];
            q.push_back(mk(AK_PASSB, 32'hDEAD_BEEF, 32'h1234_5000, `ALU_PASSB));
            q.push_back(mk(AK_PASSB, 32'hFFFF_FFFF, 32'h0000_0000, `ALU_PASSB));
            q.push_back(mk(AK_PASSB, 32'h0000_0000, 32'hFFFF_F000, `ALU_PASSB));
            add_seq("lui_passb", q);
        end
        // 6) unmapped encodings fall back to ADD
        begin
            alu_cycle q[$];
            for (int e = 4'hB; e <= 4'hF; e++)
                q.push_back(mk(AK_UNMAPPED, 32'd10, 32'd20, e[3:0]));
            add_seq("unmapped_defaults_to_add", q);
        end
        // 7) toggle-coverage vectors: complementary patterns through both
        //    operands, aimed at the wide-bus toggle shortfall in COVERAGE.md
        begin
            alu_cycle q[$];
            bit [31:0] pat[4] = '{32'h0000_0000, 32'hFFFF_FFFF,
                                  32'h5555_5555, 32'hAAAA_AAAA};
            foreach (pat[i])
                foreach (pat[j]) begin
                    q.push_back(mk(AK_RANDOM, pat[i], pat[j], `ALU_ADD));
                    q.push_back(mk(AK_RANDOM, pat[i], pat[j], `ALU_XOR));
                end
            add_seq("toggle_patterns", q);
        end
        // 8) CRV sequences
        for (int s = 0; s < num_random_seqs; s++) begin
            alu_cycle q[$];
            for (int i = 0; i < random_seq_len; i++) begin
                alu_cycle c = new();
                if (!c.randomize())
                    $fatal(1, "alu_cycle randomize() failed");
                q.push_back(c);
            end
            add_seq($sformatf("crv_seq_%0d", s), q);
        end
        // 9) exhaustive op sweep at fixed operands: all 16 encodings
        begin
            alu_cycle q[$];
            for (int e = 0; e < 16; e++)
                q.push_back(mk(AK_RANDOM, 32'hA5A5_5A5A, 32'h0000_0011, e[3:0]));
            add_seq("all_16_encodings", q);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 5. DRIVER / MONITOR
// -------------------------------------------------------------
class alu_driver;
    virtual alu_if vif;
    function new(virtual alu_if vif); this.vif = vif; endfunction
    task apply(alu_cycle c);
        @(negedge vif.clk);
        vif.op_a   <= c.a;
        vif.op_b   <= c.b;
        vif.alu_op <= c.op;
    endtask
endclass

class alu_monitor;
    virtual alu_if vif;

    covergroup cg_alu;
        cp_op: coverpoint vif.alu_op {
            bins add = {`ALU_ADD};  bins sub  = {`ALU_SUB};
            bins and_ = {`ALU_AND}; bins or_  = {`ALU_OR};
            bins xor_ = {`ALU_XOR}; bins sll  = {`ALU_SLL};
            bins srl  = {`ALU_SRL}; bins sra  = {`ALU_SRA};
            bins slt  = {`ALU_SLT}; bins sltu = {`ALU_SLTU};
            bins passb = {`ALU_PASSB};
            bins unmapped = {[4'hB:4'hF]};
        }
        // The shift-amount masking corner: 0, 31, and >=32 must all be hit.
        cp_shamt: coverpoint vif.op_b[5:0] iff (vif.alu_op inside {`ALU_SLL, `ALU_SRL, `ALU_SRA}) {
            bins zero      = {0};
            bins low       = {[1:30]};
            bins max_valid = {31};
            bins wraps     = {[32:63]};      // must alias back onto 0..31
        }
        cp_a_sign: coverpoint vif.op_a[31];
        cp_b_sign: coverpoint vif.op_b[31];
        // Signed/unsigned divergence is only interesting when the operand
        // signs differ, which is exactly this cross.
        cross cp_a_sign, cp_b_sign;
        cp_result_shape: coverpoint vif.result {
            bins zero     = {32'h0000_0000};
            bins all_ones = {32'hFFFF_FFFF};
            bins generic  = default;
        }
    endgroup

    function new(virtual alu_if vif);
        this.vif = vif;
        cg_alu = new();
    endfunction

    task sample_one(output bit [31:0] r);
        #1;                       // let the combinational cone settle
        r = vif.result;
        cg_alu.sample();
    endtask
endclass


// -------------------------------------------------------------
// 6. ENV / TEST
// -------------------------------------------------------------
class alu_env;
    virtual alu_if      vif;
    alu_generator       gen;
    alu_driver          drv;
    alu_monitor         mon;
    alu_ref_model       model;
    garuda_tb_pkg::scoreboard sb;

    function new(virtual alu_if vif, int nseq = 8, int slen = 250);
        this.vif = vif;
        gen   = new(nseq, slen);
        drv   = new(vif);
        mon   = new(vif);
        model = new();
        sb    = new("ALU");
    endfunction

    task run();
        gen.build();
        foreach (gen.seq_q[s]) begin
            foreach (gen.seq_q[s][i]) begin
                alu_cycle  c = gen.seq_q[s][i];
                bit [31:0] act, exp;
                drv.apply(c);
                mon.sample_one(act);
                exp = model.step(c.a, c.b, c.op);
                sb.chk(gen.seq_name[s],
                       $sformatf("op=%0h a=%08h b=%08h", c.op, c.a, c.b),
                       act, exp);
            end
        end
        sb.summary(mon.cg_alu.get_coverage());
    endtask
endclass


// -------------------------------------------------------------
// 7. TB TOP
// -------------------------------------------------------------
module tb_top;
    bit clk = 0;
    always #5 clk = ~clk;

    alu_if vif(clk);

    alu dut (
        .op_a   (vif.op_a),
        .op_b   (vif.op_b),
        .alu_op (vif.alu_op),
        .result (vif.result)
    );

    alu_env env;

    initial begin
        vif.op_a = 32'd0; vif.op_b = 32'd0; vif.alu_op = `ALU_ADD;
        repeat (3) @(posedge clk);
        env = new(vif, 8, 250);
        env.run();
        $finish;
    end
endmodule
