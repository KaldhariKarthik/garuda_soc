// =============================================================================
// dsu_cov_vplan.sv -- DSU design-behaviour functional coverage named by the DSU
// vPlan (tb/dsu/GARUDA_DSU_vplan.csv) and not modelled by cg_dsu (garuda_cov.sv:
// op x accumulator x format). Found by tools/run/vplan_trace.py dsu (Track A
// wrap-up, 2026-10-12). Bound into dsu_top, so it samples in the DSU block bench
// and in every core run; reported with the DSU (tb/dsu/cov/cov.toml).
//
//   cg_dsu_mac   F01  MAC / MACSUB x operand signs x accumulator
//   cg_dsu_dot   F02  MACDOT: sign of the high-half and low-half products
//   cg_dsu_shift F05  MACSHIFT amount band x accumulator sign
//   cg_dsu_sat   F06  MACSAT: the accumulator against the 32-bit range
//   cg_dsu_abs   F07  MACABS operand: positive, negative, zero, 0x8000
//   cg_dsu_ovf   F10  an accumulator overflow: accumulator x direction x op
//   cg_dsu_ill   F12/F13  ACCSEL = 3 with each op; every illegal class
//   cg_dsu_pair  F16  two DSU instructions back to back: kinds x same accumulator
//
// An instruction is counted when it completes: dsu_en high, not held by the
// interlock (dsu_busy) and not flushed. Explicit bins, crosses without
// intersect, explicit sample() calls (portable to Verilator 5.052 and irun 15.2).
// =============================================================================
`timescale 1ns/1ps

`ifndef __ICARUS__   // covergroups and bind: not for Icarus (same rule as the cov files on main)
module dsu_cov_vplan (
    input wire        clk, rst_n, flush, dsu_en, dsu_busy, illegal_instr,
    input wire [31:0] instr, rs1, rs2,
    input wire [2:0]  mac_overflow,
    input wire        sat_overflow,
    input wire [47:0] acc0, acc1, acc2
);
    wire [2:0] f3   = instr[14:12];
    wire       ityp = (f3 == 3'b001);
    wire [4:0] f5   = ityp ? 5'd9 : instr[31:27];          // 9 = MACSHIFT, as cg_dsu
    wire [1:0] sel  = ityp ? instr[27:26] : instr[26:25];
    wire [5:0] amt  = instr[25:20];
    wire       done = rst_n && dsu_en && !dsu_busy && !flush;
    function automatic [47:0] acc_of(input [1:0] s);
        case (s) 2'd0: return acc0; 2'd1: return acc1; default: return acc2; endcase
    endfunction
    // kinds for the back-to-back pairs: accumulate, read, write, shift
    function automatic [1:0] kind(input [4:0] op);
        if (op inside {5'd0, 5'd1, 5'd2, 5'd3}) return 2'd0;
        if (op inside {5'd6, 5'd7, 5'd8})       return 2'd1;
        if (op inside {5'd4, 5'd5})             return 2'd2;
        return 2'd3;
    endfunction

    covergroup cg_dsu_mac with function sample(bit sub, bit sa, bit sb, bit [1:0] s);
        cp_op:  coverpoint sub { bins mac_sel = {0}; bins macsub = {1}; }
        cp_sa:  coverpoint sa;
        cp_sb:  coverpoint sb;
        cp_acc: coverpoint s { bins fx = {0}; bins fy = {1}; bins mag = {2}; }
        x_op_signs_acc: cross cp_op, cp_sa, cp_sb, cp_acc;
    endgroup
    covergroup cg_dsu_dot with function sample(bit hi_neg, bit lo_neg);
        cp_pair: coverpoint {hi_neg, lo_neg} { bins pp = {2'b00}; bins pn = {2'b01}; bins np = {2'b10}; bins nn = {2'b11}; }
    endgroup
    covergroup cg_dsu_shift with function sample(bit [5:0] a, bit neg);
        cp_amount: coverpoint a { bins zero = {0}; bins a1_15 = {[1:15]}; bins a16_31 = {[16:31]}; bins a32_47 = {[32:47]}; }
        cp_sign:   coverpoint neg;
        x_amount_sign: cross cp_amount, cp_sign;
    endgroup
    covergroup cg_dsu_sat with function sample(int r);
        cp_range: coverpoint r { bins below_min = {0}; bins at_min = {1}; bins in_range = {2}; bins at_max = {3}; bins above_max = {4}; }
    endgroup
    covergroup cg_dsu_abs with function sample(int v);
        cp_value: coverpoint v { bins zero = {0}; bins positive = {1}; bins negative = {2}; bins most_negative = {3}; }
    endgroup
    covergroup cg_dsu_ovf with function sample(bit [1:0] a, bit neg, int op);
        cp_acc: coverpoint a { bins fx = {0}; bins fy = {1}; bins mag = {2}; }
        cp_dir: coverpoint neg { bins positive = {0}; bins negative = {1}; }
        cp_op:  coverpoint op { bins mac_sel = {0}; bins macsub = {1}; bins macdot = {3}; }
        x_acc_dir_op: cross cp_acc, cp_dir, cp_op;
    endgroup
    covergroup cg_dsu_ill with function sample(int what, bit [4:0] op);
        cp_insn_with_sel3: coverpoint op iff (what == 0) {
            bins mac_sel = {0}; bins macsub = {1}; bins macabs = {2}; bins macdot = {3}; bins macload = {4};
            bins macclear = {5}; bins macsat = {6}; bins rd_lo = {7}; bins rd_hi = {8}; bins macshift = {9}; }
        cp_class: coverpoint what { bins bad_accsel = {0}; bins bad_funct3 = {1}; bins bad_funct5 = {2}; bins bad_shift_amount = {3}; }
    endgroup
    covergroup cg_dsu_pair with function sample(bit [1:0] k1, bit [1:0] k2, bit same);
        cp_first:  coverpoint k1 { bins acc = {0}; bins rd = {1}; bins wr = {2}; bins sh = {3}; }
        cp_second: coverpoint k2 { bins acc = {0}; bins rd = {1}; bins wr = {2}; bins sh = {3}; }
        cp_same:   coverpoint same;
        x_first_second_same: cross cp_first, cp_second, cp_same;
    endgroup

    cg_dsu_mac   c_mac   = new();
    cg_dsu_dot   c_dot   = new();
    cg_dsu_shift c_shift = new();
    cg_dsu_sat   c_sat   = new();
    cg_dsu_abs   c_abs   = new();
    cg_dsu_ovf   c_ovf   = new();
    cg_dsu_ill   c_ill   = new();
    cg_dsu_pair  c_pair  = new();

    reg [4:0] last_op; reg [1:0] last_sel; int since;
    reg [4:0] op_q; reg [1:0] sel_q; reg done_q;
    reg [2:0] ovf_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            since = 99; done_q <= 1'b0; ovf_q <= 3'b0;
        end else begin
            since++;
            if (done && illegal_instr) begin
                if (sel == 2'b11) c_ill.sample(0, f5);
                else if (!(f3 inside {3'b000, 3'b001})) c_ill.sample(1, f5);
                else if (ityp && amt >= 6'd48) c_ill.sample(3, f5);
                else c_ill.sample(2, f5);
            end else if (done) begin
                case (f5)
                    5'd0, 5'd1: c_mac.sample(f5[0], rs1[15], rs2[15], sel);
                    5'd2: c_abs.sample(rs1[15:0] == 16'h0 ? 0 : rs1[15:0] == 16'h8000 ? 3 : rs1[15] ? 2 : 1);
                    5'd3: c_dot.sample(rs1[31] ^ rs2[31] && rs1[31:16] != 0 && rs2[31:16] != 0,
                                       rs1[15] ^ rs2[15] && rs1[15:0] != 0 && rs2[15:0] != 0);
                    5'd6: begin
                        automatic logic signed [47:0] a = acc_of(sel);
                        c_sat.sample(a < -48'sd2147483648 ? 0 : a == -48'sd2147483648 ? 1 :
                                     a <  48'sd2147483647 ? 2 : a == 48'sd2147483647 ? 3 : 4);
                    end
                    5'd9: c_shift.sample(amt, acc_of(sel)[47]);
                    default: ;
                endcase
                if (since <= 2) c_pair.sample(kind(last_op), kind(f5), last_sel == sel);
                last_op <= f5; last_sel <= sel; since = 0;
            end
            // an overflow: the accumulator's overflow strobe of the completing op
            done_q <= done && !illegal_instr; op_q <= f5; sel_q <= sel; ovf_q <= mac_overflow;
            for (int k = 0; k < 3; k++)
                if (mac_overflow[k] && !ovf_q[k]) c_ovf.sample(2'(k), acc_of(2'(k))[47], int'(op_q));
        end
    end
endmodule

bind dsu_top dsu_cov_vplan u_dsu_cov_vplan (
    .clk(clk), .rst_n(rst_n), .flush(flush), .dsu_en(dsu_en), .dsu_busy(dsu_busy),
    .illegal_instr(illegal_instr), .instr(instr), .rs1(rs1), .rs2(rs2),
    .mac_overflow(mac_overflow), .sat_overflow(sat_overflow),
    .acc0(dbg_acc_0), .acc1(dbg_acc_1), .acc2(dbg_acc_2));
`endif
