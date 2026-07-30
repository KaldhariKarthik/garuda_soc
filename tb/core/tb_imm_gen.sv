// =============================================================
// tapeout_imm_gen.sv
// Tapeout-grade SV verification environment for GARUDA imm_gen.v
// (ID-stage immediate generator, Sec. 7.3, Sec. 13.3)
//
// imm_gen is PURELY COMBINATIONAL - no clk/rst port, no internal state to
// carry across sequences. The sequence-based generator / synchronous
// apply-sample-check loop below still applies for structural consistency
// with the rest of this test set; the reset-isolation step a stateful DUT
// needs is a documented no-op here.
//
// Requires a simulator with full IEEE1800 support (covergroup, assert
// property). NOT Icarus Verilog.
// =============================================================

`timescale 1ns / 1ps

// -------------------------------------------------------------
// 0. DEFINES (inlined from garuda_defs.vh)
// -------------------------------------------------------------
// imm_gen.v's real source begins with `` `include "garuda_defs.vh" ``.
// That include is REMOVED from the pasted DUT below (a literal `include
// would require the file on disk, breaking standalone compilation) and
// its content is inlined here instead - a textual substitution of the
// include mechanism, not a behavioral edit.
`ifndef GARUDA_DEFS_VH
`define GARUDA_DEFS_VH
`define ALU_ADD   4'h0
`define ALU_SUB   4'h1
`define ALU_AND   4'h2
`define ALU_OR    4'h3
`define ALU_XOR   4'h4
`define ALU_SLL   4'h5
`define ALU_SRL   4'h6
`define ALU_SRA   4'h7
`define ALU_SLT   4'h8
`define ALU_SLTU  4'h9
`define ALU_PASSB 4'hA
`define IMM_I    3'h0
`define IMM_S    3'h1
`define IMM_B    3'h2
`define IMM_U    3'h3
`define IMM_J    3'h4
`define IMM_CSR  3'h5
`define IMM_NONE 3'h6
`endif // GARUDA_DEFS_VH

// -------------------------------------------------------------
// 1. DUT: imm_gen.v (pasted verbatim, `include line substituted per above)
// -------------------------------------------------------------
module imm_gen (
    input  wire [31:0] instr_i,
    input  wire [2:0]  imm_sel_i,

    output reg  [31:0] imm_o,
    output wire [31:0] imm_b_o,
    output wire [31:0] imm_j_o
);

    wire [31:0] imm_i_f, imm_s_f, imm_b_f, imm_u_f, imm_j_f, imm_csr_f;

    assign imm_i_f   = {{20{instr_i[31]}}, instr_i[31:20]};
    assign imm_s_f   = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};
    assign imm_b_f   = {{19{instr_i[31]}}, instr_i[31], instr_i[7],
                         instr_i[30:25], instr_i[11:8], 1'b0};
    assign imm_u_f   = {instr_i[31:12], 12'b0};
    assign imm_j_f   = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12],
                         instr_i[20], instr_i[30:21], 1'b0};
    assign imm_csr_f = {27'b0, instr_i[19:15]};

    assign imm_b_o = imm_b_f;
    assign imm_j_o = imm_j_f;

    always @(*) begin
        case (imm_sel_i)
            `IMM_I:   imm_o = imm_i_f;
            `IMM_S:   imm_o = imm_s_f;
            `IMM_B:   imm_o = imm_b_f;
            `IMM_U:   imm_o = imm_u_f;
            `IMM_J:   imm_o = imm_j_f;
            `IMM_CSR: imm_o = imm_csr_f;
            default:  imm_o = 32'b0;
        endcase
    end

endmodule


// -------------------------------------------------------------
// 2. INTERFACE (+ bound SVA assertions)
// -------------------------------------------------------------
interface imm_gen_if (input bit clk);
    logic [31:0] instr;
    logic [2:0]  imm_sel;
    logic [31:0] imm;
    logic [31:0] imm_b;
    logic [31:0] imm_j;

    // A1/A2: branch_predict.v consumes imm_b_o/imm_j_o EVERY cycle to make
    //        its static prediction, regardless of what imm_sel_i currently
    //        says - decode hasn't necessarily even settled on IMM_B yet.
    //        If these ever depended on imm_sel_i, prediction breaks for
    //        every branch/jal.
    property p_imm_b_always_live;
        @(posedge clk) imm_b == {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    endproperty
    a_imm_b_live: assert property (p_imm_b_always_live)
        else $error("[SVA-FAIL] imm_b_o did not track instr_i independent of imm_sel_i");

    property p_imm_j_always_live;
        @(posedge clk) imm_j == {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
    endproperty
    a_imm_j_live: assert property (p_imm_j_always_live)
        else $error("[SVA-FAIL] imm_j_o did not track instr_i independent of imm_sel_i");

    // A3: IMM_NONE (R-type ALU ops with no immediate field) must present
    //     a clean zero, or the ALU-source mux could misread a phantom
    //     operand.
    property p_none_forces_zero;
        @(posedge clk) (imm_sel == `IMM_NONE) |-> (imm == 32'b0);
    endproperty
    a_none_zero: assert property (p_none_forces_zero)
        else $error("[SVA-FAIL] IMM_NONE selected but imm_o was not zero");

    // A4: CSRRWI/SI/CI (Sec. 13.3) zero-extend a 5-bit register-number
    //     field rather than sign-extending it.
    property p_csr_zero_extended;
        @(posedge clk) (imm_sel == `IMM_CSR) |-> (imm[31:5] == 27'b0);
    endproperty
    a_csr_zero_ext: assert property (p_csr_zero_extended)
        else $error("[SVA-FAIL] IMM_CSR selection was not zero-extended above bit 4");

    // A5: U-type immediates are "upper 20 bits, lower 12 forced to zero".
    property p_u_type_lower_bits_zero;
        @(posedge clk) (imm_sel == `IMM_U) |-> (imm[11:0] == 12'b0);
    endproperty
    a_u_lower_zero: assert property (p_u_type_lower_bits_zero)
        else $error("[SVA-FAIL] U-type immediate did not clear its low 12 bits");

    // A6: B/J-type immediates encode a byte offset that is always even -
    //     RISC-V branches/jumps only ever target 2-byte-aligned addresses.
    property p_b_j_type_lsb_zero;
        @(posedge clk) ((imm_sel == `IMM_B) || (imm_sel == `IMM_J)) |-> (imm[0] == 1'b0);
    endproperty
    a_b_j_lsb_zero: assert property (p_b_j_type_lsb_zero)
        else $error("[SVA-FAIL] B/J-type immediate had a non-zero LSB");

    // A7: X-propagation.
    property p_no_x_propagation;
        @(posedge clk) (!$isunknown({instr, imm_sel})) |-> (!$isunknown({imm, imm_b, imm_j}));
    endproperty
    a_no_x_propagation: assert property (p_no_x_propagation)
        else $error("[SVA-FAIL] an immediate output went unknown with known inputs");

endinterface


// -------------------------------------------------------------
// 3. PER-CYCLE STIMULUS ITEM -- rand + constraint => real CRV
// -------------------------------------------------------------
typedef enum {
    IK_I_TYPE, IK_S_TYPE, IK_B_TYPE, IK_U_TYPE, IK_J_TYPE, IK_CSR_TYPE, IK_NONE_TYPE,
    IK_BOUNDARY_MIN, IK_BOUNDARY_MAX, IK_BOUNDARY_ZERO, IK_RANDOM
} imm_op_e;

class imm_cycle;
    rand imm_op_e op;
    rand bit [31:0] instr_val;
    rand bit [2:0]  sel_val;

    constraint c_op_dist {
        op dist {
            IK_I_TYPE :/ 10, IK_S_TYPE :/ 10, IK_B_TYPE :/ 10, IK_U_TYPE :/ 10,
            IK_J_TYPE :/ 10, IK_CSR_TYPE :/ 10, IK_NONE_TYPE :/ 5,
            IK_BOUNDARY_MIN :/ 5, IK_BOUNDARY_MAX :/ 5, IK_BOUNDARY_ZERO :/ 5, IK_RANDOM :/ 20
        };
    }

    constraint c_sel_matches_op {
        (op == IK_I_TYPE)   -> (sel_val == `IMM_I);
        (op == IK_S_TYPE)   -> (sel_val == `IMM_S);
        (op == IK_B_TYPE)   -> (sel_val == `IMM_B);
        (op == IK_U_TYPE)   -> (sel_val == `IMM_U);
        (op == IK_J_TYPE)   -> (sel_val == `IMM_J);
        (op == IK_CSR_TYPE) -> (sel_val == `IMM_CSR);
        (op == IK_NONE_TYPE) -> (sel_val == `IMM_NONE);
        (op inside {IK_BOUNDARY_MIN, IK_BOUNDARY_MAX, IK_BOUNDARY_ZERO, IK_RANDOM}) -> (sel_val inside {[0:6]});
    }

    constraint c_boundary_shape {
        (op == IK_BOUNDARY_ZERO) -> (instr_val == 32'b0);
        (op == IK_BOUNDARY_MIN)  -> (instr_val[31] == 1'b1);
        (op == IK_BOUNDARY_MAX)  -> (instr_val == 32'h7FFF_FFFF);
    }

    // Trivial pass-through - no encoding step beyond what's already in
    // instr_val/sel_val - kept for structural parity with the rest of
    // this test set.
    function void fields(output bit [31:0] o_instr, output bit [2:0] o_sel);
        o_instr = instr_val; o_sel = sel_val;
    endfunction
endclass


// -------------------------------------------------------------
// 4. GENERATOR -- directed sequences + CRV.
// -------------------------------------------------------------
class imm_generator;
    imm_cycle seq_q[$][$];
    string    seq_name[$];
    int num_random_seqs;
    int random_seq_len;

    function new(int num_random_seqs = 10, int random_seq_len = 200);
        this.num_random_seqs = num_random_seqs;
        this.random_seq_len  = random_seq_len;
    endfunction

    function imm_cycle mk(imm_op_e op, bit [31:0] instr, bit [2:0] sel);
        imm_cycle c = new();
        c.op = op; c.instr_val = instr; c.sel_val = sel;
        return c;
    endfunction

    function void add_seq(string name, imm_cycle q[$]);
        seq_name.push_back(name);
        seq_q.push_back(q);
    endfunction

    function void build();
        // 1) Idle/reset vector - NOP
        begin
            imm_cycle q[$];
            q.push_back(mk(IK_NONE_TYPE, 32'h0000_0013, `IMM_NONE));
            add_seq("idle_nop", q);
        end

        // 2) I-type boundary values
        begin
            imm_cycle q[$];
            q.push_back(mk(IK_I_TYPE, {12'h800, 20'h0}, `IMM_I)); // -2048
            q.push_back(mk(IK_I_TYPE, {12'h7FF, 20'h0}, `IMM_I)); // +2047
            q.push_back(mk(IK_I_TYPE, {12'h000, 20'h0}, `IMM_I)); // 0
            q.push_back(mk(IK_I_TYPE, {12'hFFF, 20'h0}, `IMM_I)); // -1
            add_seq("i_type_boundaries", q);
        end

        // 3) S-type boundary values
        begin
            imm_cycle q[$];
            q.push_back(mk(IK_S_TYPE, {7'b1000000, 13'h0, 5'b00000, 7'h0}, `IMM_S)); // -2048
            q.push_back(mk(IK_S_TYPE, {7'b0111111, 13'h0, 5'b11111, 7'h0}, `IMM_S)); // +2047
            q.push_back(mk(IK_S_TYPE, 32'h0, `IMM_S));
            add_seq("s_type_boundaries", q);
        end

        // 4) B-type boundary values
        begin
            imm_cycle q[$];
            q.push_back(mk(IK_B_TYPE, 32'h8000_0000, `IMM_B)); // -4096 (min)
            q.push_back(mk(IK_B_TYPE, 32'h0000_0000, `IMM_B)); // 0
            q.push_back(mk(IK_B_TYPE, 32'h7E00_0F80, `IMM_B)); // +4094 (max even value)
            add_seq("b_type_boundaries", q);
        end

        // 5) U-type boundary values
        begin
            imm_cycle q[$];
            q.push_back(mk(IK_U_TYPE, {20'hFFFFF, 12'h0}, `IMM_U));
            q.push_back(mk(IK_U_TYPE, {20'h00000, 12'h0}, `IMM_U));
            q.push_back(mk(IK_U_TYPE, {20'h80000, 12'h0}, `IMM_U));
            add_seq("u_type_boundaries", q);
        end

        // 6) J-type boundary values
        begin
            imm_cycle q[$];
            q.push_back(mk(IK_J_TYPE, 32'h0, `IMM_J));
            q.push_back(mk(IK_J_TYPE, {1'b1, 20'h0, 11'h0}, `IMM_J)); // sign-only (most negative)
            add_seq("j_type_boundaries", q);
        end

        // 7) CSR zero-extension boundaries
        begin
            imm_cycle q[$];
            q.push_back(mk(IK_CSR_TYPE, {12'hFFF, 5'd0,  15'h0}, `IMM_CSR));
            q.push_back(mk(IK_CSR_TYPE, {12'hFFF, 5'd31, 15'h0}, `IMM_CSR)); // rs1[4]=1 must NOT sign-extend
            q.push_back(mk(IK_CSR_TYPE, {12'hFFF, 5'd17, 15'h0}, `IMM_CSR));
            add_seq("csr_zero_extension_boundaries", q);
        end

        // 8) IMM_NONE forces zero regardless of instr bits
        begin
            imm_cycle q[$];
            q.push_back(mk(IK_NONE_TYPE, 32'hFFFF_FFFF, `IMM_NONE));
            q.push_back(mk(IK_NONE_TYPE, 32'hDEAD_BEEF, `IMM_NONE));
            add_seq("none_forces_zero", q);
        end

        // 9) imm_b_o/imm_j_o liveness across every imm_sel value
        begin
            imm_cycle q[$];
            for (int s = 0; s < 7; s++) q.push_back(mk(IK_RANDOM, 32'hA5A5_A5A5, s[2:0]));
            add_seq("imm_b_j_liveness_all_sel", q);
        end

        // 10) Illegal/unreachable imm_sel encoding (3'd7 is unassigned -
        //     nothing in decode_control.v is documented to ever drive it,
        //     but the port has no hardware interlock preventing it)
        begin
            imm_cycle q[$];
            q.push_back(mk(IK_RANDOM, 32'hFFFF_FFFF, 3'd7));
            add_seq("unassigned_sel_encoding", q);
        end

        // 11) Back-to-back repeated identical select (stress)
        begin
            imm_cycle q[$];
            repeat (10) q.push_back(mk(IK_I_TYPE, 32'h1234_5678, `IMM_I));
            add_seq("stress_repeated_select", q);
        end

        // 12) Alternating format toggle (stress)
        begin
            imm_cycle q[$];
            for (int i = 0; i < 8; i++) begin
                if (i % 2 == 0) q.push_back(mk(IK_U_TYPE, 32'hFFFF_FFFF, `IMM_U));
                else            q.push_back(mk(IK_J_TYPE, 32'hFFFF_FFFF, `IMM_J));
            end
            add_seq("stress_alternating_format", q);
        end

        // 13) CONSTRAINED-RANDOM sequences
        for (int s = 0; s < num_random_seqs; s++) begin
            imm_cycle q[$];
            for (int c = 0; c < random_seq_len; c++) begin
                imm_cycle t = new();
                assert (t.randomize()) else $error("[GEN] randomize() failed");
                q.push_back(t);
            end
            add_seq($sformatf("crv_seq_%0d", s), q);
        end
    endfunction
endclass


// -------------------------------------------------------------
// 5. REFERENCE MODEL -- stateless. Built around one GENERIC
//    sign_extend() helper plus a per-format bit-gathering function,
//    rather than the RTL's six independent hardcoded concatenation
//    formulas - two different decompositions of the same rule agreeing is
//    a stronger signal than checking the RTL against a transcription of
//    itself.
// -------------------------------------------------------------
class imm_ref_model;
    static function bit [31:0] sign_extend(bit [31:0] raw, int width);
        bit sign = raw[width-1];
        bit [31:0] field_mask = (32'h1 << width) - 32'h1;
        bit [31:0] extend_mask = sign ? ~field_mask : 32'b0;
        return (raw & field_mask) | extend_mask;
    endfunction

    function automatic bit [31:0] imm_i(bit [31:0] instr); return sign_extend({20'b0, instr[31:20]}, 12); endfunction
    function automatic bit [31:0] imm_s(bit [31:0] instr);
        bit [31:0] raw = {20'b0, instr[31:25], instr[11:7]};
        return sign_extend(raw, 12);
    endfunction
    function automatic bit [31:0] imm_b(bit [31:0] instr);
        bit [31:0] raw = {19'b0, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
        return sign_extend(raw, 13);
    endfunction
    function automatic bit [31:0] imm_u(bit [31:0] instr); return {instr[31:12], 12'b0}; endfunction
    function automatic bit [31:0] imm_j(bit [31:0] instr);
        bit [31:0] raw = {11'b0, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
        return sign_extend(raw, 21);
    endfunction
    function automatic bit [31:0] imm_csr(bit [31:0] instr); return {27'b0, instr[19:15]}; endfunction

    // Returns predicted {imm, imm_b, imm_j}. Stateless - kept as a "step"
    // for structural parity with the rest of this test set.
    function automatic void step(bit [31:0] instr, bit [2:0] sel,
                                  output bit [31:0] exp_imm, output bit [31:0] exp_imm_b, output bit [31:0] exp_imm_j);
        exp_imm_b = imm_b(instr);
        exp_imm_j = imm_j(instr);
        case (sel)
            `IMM_I:   exp_imm = imm_i(instr);
            `IMM_S:   exp_imm = imm_s(instr);
            `IMM_B:   exp_imm = exp_imm_b;
            `IMM_U:   exp_imm = imm_u(instr);
            `IMM_J:   exp_imm = exp_imm_j;
            `IMM_CSR: exp_imm = imm_csr(instr);
            default:  exp_imm = 32'b0;
        endcase
    endfunction
endclass


// -------------------------------------------------------------
// 6. DRIVER
// -------------------------------------------------------------
class imm_driver;
    virtual imm_gen_if vif;
    function new(virtual imm_gen_if vif); this.vif = vif; endfunction

    task apply_cycle(imm_cycle c);
        bit [31:0] i_v; bit [2:0] s_v;
        c.fields(i_v, s_v);
        @(negedge vif.clk);
        vif.instr   <= i_v;
        vif.imm_sel <= s_v;
    endtask
endclass


// -------------------------------------------------------------
// 7. MONITOR
// -------------------------------------------------------------
class imm_result;
    bit [31:0] imm, imm_b, imm_j;
endclass

class imm_monitor;
    virtual imm_gen_if vif;

    covergroup cg_imm_gen;
        cp_imm_sel: coverpoint vif.imm_sel {
            bins i_type = {`IMM_I}; bins s_type = {`IMM_S}; bins b_type = {`IMM_B};
            bins u_type = {`IMM_U}; bins j_type = {`IMM_J}; bins csr_type = {`IMM_CSR};
            bins none_type = {`IMM_NONE};
            bins unassigned_encoding = {3'd7};
        }
        cp_sign: coverpoint vif.imm[31] iff (vif.imm_sel inside {`IMM_I, `IMM_S, `IMM_B, `IMM_U, `IMM_J});
        cp_boundary: coverpoint vif.imm {
            bins zero = {32'h0000_0000}; bins all_ones = {32'hFFFF_FFFF}; bins generic = default;
        }
        cross cp_imm_sel, cp_sign {
            // cp_sign is gated off (never sampled) whenever imm_sel is
            // CSR_TYPE, NONE_TYPE, or the unassigned encoding (3'd7) --
            // csr_gen.v zero-extends CSR immediates and forces 0 for
            // NONE/unassigned, so imm[31] carries no "sign" meaning
            // there. These 6 cross combinations are therefore
            // permanently unreachable by construction, not under-
            // tested -- excluded explicitly here rather than silently
            // capping the group below 100%, mirroring dsu_stall_tb.sv's
            // own busy_during_reset_unreachable ignore_bins.
            ignore_bins sign_meaningless_for_non_sign_extending_types =
                binsof(cp_imm_sel) intersect {`IMM_CSR, `IMM_NONE, 3'd7};
        }
    endgroup

    function new(virtual imm_gen_if vif);
        this.vif = vif;
        cg_imm_gen = new();
    endfunction

    task sample_one(output imm_result r);
        #1; // allow combinational logic to settle after apply_cycle()'s NBA update
        r = new();
        r.imm = vif.imm; r.imm_b = vif.imm_b; r.imm_j = vif.imm_j;
        cg_imm_gen.sample();
    endtask
endclass


// -------------------------------------------------------------
// 8. SCOREBOARD
// -------------------------------------------------------------
class imm_scoreboard;
    int pass_cnt = 0;
    int fail_cnt = 0;

    task check(string seq_name, int cycle_idx, imm_cycle c, bit [31:0] instr, bit [2:0] sel,
               imm_result actual, ref imm_ref_model model);
        bit [31:0] exp_imm, exp_imm_b, exp_imm_j;
        model.step(instr, sel, exp_imm, exp_imm_b, exp_imm_j);

        if ((actual.imm === exp_imm) && (actual.imm_b === exp_imm_b) && (actual.imm_j === exp_imm_j)) begin
            pass_cnt++;
            $display("[PASS] seq=%-30s cyc=%0d op=%-16s instr=0x%08h sel=%0d -> imm=0x%08h",
                      seq_name, cycle_idx, c.op.name(), instr, sel, actual.imm);
        end else begin
            fail_cnt++;
            $display("[FAIL] seq=%-30s cyc=%0d op=%-16s instr=0x%08h sel=%0d", seq_name, cycle_idx, c.op.name(), instr, sel);
            $display("       imm:   exp=0x%08h act=0x%08h", exp_imm, actual.imm);
            $display("       imm_b: exp=0x%08h act=0x%08h", exp_imm_b, actual.imm_b);
            $display("       imm_j: exp=0x%08h act=0x%08h", exp_imm_j, actual.imm_j);
        end
    endtask
endclass


// -------------------------------------------------------------
// 9. ENVIRONMENT
// -------------------------------------------------------------
class imm_env;
    virtual imm_gen_if vif;
    imm_generator  gen;
    imm_driver     drv;
    imm_monitor    mon;
    imm_scoreboard sb;

    function new(virtual imm_gen_if vif, int num_random_seqs = 10, int random_seq_len = 200);
        this.vif = vif;
        gen = new(num_random_seqs, random_seq_len);
        drv = new(vif);
        mon = new(vif);
        sb  = new();
    endfunction

    task run();
        imm_ref_model model;
        int total_cycles = 0;

        gen.build();

        // NOTE: imm_gen.v has no registers and no clk/rst port - there is
        // no state to leak across sequences.
        model = new();

        foreach (gen.seq_q[s]) begin
            foreach (gen.seq_q[s][i]) begin
                imm_cycle c = gen.seq_q[s][i];
                bit [31:0] instr_v; bit [2:0] sel_v;
                imm_result actual;
                c.fields(instr_v, sel_v);
                drv.apply_cycle(c);
                mon.sample_one(actual);
                sb.check(gen.seq_name[s], i, c, instr_v, sel_v, actual, model);
                total_cycles++;
            end
        end

        $display("\n============ IMM_GEN UNIT TB SUMMARY ============");
        $display(" SEQUENCES=%0d  TOTAL_CYCLES=%0d  PASS=%0d  FAIL=%0d", gen.seq_q.size(), total_cycles, sb.pass_cnt, sb.fail_cnt);
        $display(" FUNCTIONAL COVERAGE = %0.2f %%", mon.cg_imm_gen.get_coverage());
        if (sb.fail_cnt == 0)
            $display(" RESULT: ALL CHECKS PASSED");
        else
            $display(" RESULT: %0d CHECK(S) FAILED", sb.fail_cnt);
        $display("===================================================\n");
    endtask
endclass


// -------------------------------------------------------------
// 10. TEST
// -------------------------------------------------------------
class imm_test;
    imm_env env;
    function new(virtual imm_gen_if vif, int num_random_seqs = 10, int random_seq_len = 200);
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

    imm_gen_if vif(clk);

    imm_gen dut (
        .instr_i   (vif.instr),
        .imm_sel_i (vif.imm_sel),
        .imm_o     (vif.imm),
        .imm_b_o   (vif.imm_b),
        .imm_j_o   (vif.imm_j)
    );

    imm_test test;

    initial begin
        vif.instr = 32'h0000_0013; vif.imm_sel = `IMM_NONE;
        repeat (3) @(posedge clk);

        test = new(vif, 10, 200);
        test.run();
        $finish;
    end
endmodule
