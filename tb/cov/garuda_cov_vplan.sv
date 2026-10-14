// =============================================================================
// garuda_cov_vplan.sv -- core design-behaviour functional coverage, part 3
// (Track A wrap-up, 2026-10-12). Bound into garuda_core_top next to
// garuda_cov.sv and garuda_cov_ext.sv. It adds the coverage items the core vPlan
// (tb/core/GARUDA_CORE_vplan.csv) names and parts 1-2 do not model, found by
// tools/run/vplan_trace.py core. Covergroup and coverpoint names are the vPlan's,
// so the trace maps them without an alias:
//
//   cg_isa       F01  operand corners (0, 1, -1, INT_MIN, INT_MAX, other) of
//                     register-register ALU and branch instructions
//   cg_mul       F02  MUL / MULH / MULHSU / MULHU x operand signs
//   cg_div       F03  DIV / DIVU / REM / REMU each trapping illegal (Zmmul core:
//                     decoded, not executed, decode_control.v:14)
//   cg_illegal   F04  class of every illegal-instruction trap
//   cg_sys       F07  every system / fence instruction executed
//   cg_csr_op    F08/F12  CSR group x op, writes to the machine counters
//   cg_trap_x    F14/F16/F17  an older exception over a younger fault, a faulting
//                     fetch squashed before it could trap, traps back to back
//   cg_irq       F18/F20/F23  interrupt x class of the interrupted instruction,
//                     MTI and CLIC pending together, an exception winning over a
//                     takeable interrupt
//   cg_hazard_lu F25  the consumer of a load-use stall
//   cg_branch_k  F28  branch kind x direction x outcome
//   cg_pipe_pair F30  consecutive instruction classes in EX
//   cg_wfi       F31/F34  wake source x MIE, time asleep
//
// Portable subset (Verilator 5.052 and irun 15.2): explicit bins, crosses
// without intersect, combinations as concatenated coverpoints. Bound, never
// instantiated. Sampled with explicit sample() calls (no clocking events) so a
// bin's condition reads exactly as written below.
// =============================================================================
`timescale 1ns/1ps

module garuda_cov_vplan (
    input wire        clk_i, rst_n_i,
    input wire        xe_valid, xe_mul_en, xe_dsu_en, xe_csr_en, xe_branch, xe_jal, xe_jalr,
    input wire        xe_pred_taken, ex_mispredict,
    input wire [31:0] xe_instr, xe_rs1, xe_rs2,
    input wire [4:0]  xe_rd,
    input wire        mem_stall, dsu_busy, load_use,
    input wire        id_valid, id_illegal, id_fault,
    input wire [31:0] id_instr,
    input wire        ex_redir, tr_redir,
    input wire        tr_enter, tr_is_int, tr_mret,
    input wire [31:0] tr_cause,
    input wire        csr_illegal,
    input wire        irq_valid, mtip, take_cond, mie,
    input wire        quiescent
);
    // ---- instruction classes ---------------------------------------------------
    localparam [2:0] K_ALU = 3'd0, K_MEM = 3'd1, K_CTRL = 3'd2, K_MUL = 3'd3, K_SYS = 3'd4, K_DSU = 3'd5;
    function automatic [2:0] klass(input [31:0] i, input bit dsu);
        case (i[6:0])
            7'b0110011: return (i[31:25] == 7'b0000001) ? K_MUL : K_ALU;
            7'b0010011, 7'b0110111, 7'b0010111: return K_ALU;
            7'b0000011, 7'b0100011: return K_MEM;
            7'b1100011, 7'b1101111, 7'b1100111: return K_CTRL;
            7'b1110011, 7'b0001111: return K_SYS;
            default: return dsu ? K_DSU : K_SYS;
        endcase
    endfunction
    function automatic [2:0] corner(input [31:0] v);
        case (v)
            32'h0000_0000: return 3'd0;
            32'h0000_0001: return 3'd1;
            32'hFFFF_FFFF: return 3'd2;
            32'h8000_0000: return 3'd3;
            32'h7FFF_FFFF: return 3'd4;
            default:       return 3'd5;
        endcase
    endfunction
    wire adv = rst_n_i && xe_valid && !mem_stall && !dsu_busy;   // the EX instruction moves on
    wire [6:0] opc = xe_instr[6:0];
    wire [2:0] f3  = xe_instr[14:12];
    wire is_rr_alu = (opc == 7'b0110011) && (xe_instr[31:25] != 7'b0000001);
    wire is_div    = (opc == 7'b0110011) && (xe_instr[31:25] == 7'b0000001) && f3[2];

    // ---- F01 / F02 / F03 / F04 / F07 ---------------------------------------------
    covergroup cg_isa with function sample(bit [2:0] a, bit [2:0] b);
        cp_operand_corner: coverpoint {a, b} {
            bins ab[] = {6'o00, 6'o01, 6'o02, 6'o03, 6'o04, 6'o05, 6'o10, 6'o11, 6'o12, 6'o13, 6'o14, 6'o15,
                         6'o20, 6'o21, 6'o22, 6'o23, 6'o24, 6'o25, 6'o30, 6'o31, 6'o32, 6'o33, 6'o34, 6'o35,
                         6'o40, 6'o41, 6'o42, 6'o43, 6'o44, 6'o45, 6'o50, 6'o51, 6'o52, 6'o53, 6'o54, 6'o55};
        }
    endgroup
    covergroup cg_mul with function sample(bit [1:0] op, bit sa, bit sb);
        cp_op: coverpoint op { bins mul = {0}; bins mulh = {1}; bins mulhsu = {2}; bins mulhu = {3}; }
        cp_sa: coverpoint sa;
        cp_sb: coverpoint sb;
        x_op_signs: cross cp_op, cp_sa, cp_sb;
    endgroup
    covergroup cg_div with function sample(bit [1:0] op);
        cp_op_illegal: coverpoint op { bins div = {0}; bins divu = {1}; bins rem = {2}; bins remu = {3}; }
    endgroup
    covergroup cg_illegal with function sample(int c);
        cp_class: coverpoint c { bins csr = {0}; bins zero_word = {1}; bins div = {2}; bins opcode = {3}; bins funct = {4}; }
    endgroup
    covergroup cg_sys with function sample(int k);
        cp_insn: coverpoint k { bins ecall = {0}; bins ebreak = {1}; bins mret = {2}; bins wfi = {3};
                                bins fence = {4}; bins fence_i = {5}; bins csr = {6}; }
    endgroup

    // ---- F08 / F12: CSR group x op, counter writes -----------------------------------
    function automatic int csr_group(input [11:0] a);
        if (a inside {12'h300, 12'h301, 12'h304, 12'h305, 12'h340, 12'h341, 12'h342, 12'h343,
                      12'h344, 12'h345, 12'h346, 12'h347, 12'h7C0}) return 0;            // machine RW
        if (a inside {12'hB00, 12'hB02, 12'hB80, 12'hB82}) return 1;                       // machine counters
        if (a inside {12'hC00, 12'hC02, 12'hC80, 12'hC82}) return 2;                       // user counters (RO)
        if (a inside {12'hF11, 12'hF12, 12'hF13, 12'hF14, 12'hFB1}) return 3;              // ID / RO
        if (a == 12'hBC0) return 4;                                                        // dsu_ovf
        return 5;                                                                          // read-zero / other
    endfunction
    covergroup cg_csr_op with function sample(int grp, bit [2:0] op, int counter_wr);
        cp_grp: coverpoint grp { bins m_rw = {0}; bins m_cnt = {1}; bins u_cnt = {2}; bins id_ro = {3}; bins dsu = {4}; bins rz = {5}; }
        cp_op:  coverpoint op  { bins rw = {1}; bins rs = {2}; bins rc = {3}; bins rwi = {5}; bins rsi = {6}; bins rci = {7}; }
        x_addr_op: cross cp_grp, cp_op;
        cp_counter_write: coverpoint counter_wr { bins mcycle = {0}; bins minstret = {1}; bins mcycleh = {2}; bins minstreth = {3}; }
    endgroup

    // ---- F14 / F16 / F17 -------------------------------------------------------------
    covergroup cg_trap_x with function sample(int what, int gap);
        cp_x_cause_younger: coverpoint what iff (what >= 0 && what < 2) { bins over_illegal = {0}; bins over_fetch_fault = {1}; }
        cp_fetch_err_flushed: coverpoint what iff (what == 2) { bins squashed = {2}; }
        cp_back_to_back: coverpoint gap iff (gap >= 0) { bins b2b_1_8 = {[1:8]}; bins near_9_63 = {[9:63]}; bins far = {[64:$]}; }
    endgroup

    // ---- F18 / F20 / F23 ---------------------------------------------------------------
    covergroup cg_irq with function sample(int what, int klass_in_ex);
        x_insn_class: coverpoint klass_in_ex iff (what == 0) {
            bins alu = {0}; bins mem = {1}; bins ctrl = {2}; bins mul = {3}; bins sys = {4}; bins dsu = {5}; bins bubble = {6}; }
        cp_mti_with_clic: coverpoint what iff (what >= 1 && what <= 3) { bins both_pending = {1}; bins clic_taken = {2}; bins mti_taken = {3}; }
        cp_with_exception: coverpoint what iff (what == 4) { bins exception_wins = {4}; }
    endgroup

    // ---- F25 / F28 / F30 / F31 / F34 -----------------------------------------------------
    covergroup cg_hazard_lu with function sample(int c);
        cp_load_use_consumer: coverpoint c { bins alu_rs1 = {0}; bins alu_rs2 = {1}; bins alu_both = {2};
                                             bins store_data = {3}; bins store_base = {4}; bins branch = {5};
                                             bins jalr = {6}; bins load_base = {7}; }
    endgroup
    covergroup cg_branch_k with function sample(bit [2:0] kind, bit back, bit taken);
        cp_kind:  coverpoint kind { bins beq = {0}; bins bne = {1}; bins blt = {4}; bins bge = {5}; bins bltu = {6}; bins bgeu = {7}; }
        cp_dir:   coverpoint back;
        cp_taken: coverpoint taken;
        x_kind_dir_outcome: cross cp_kind, cp_dir, cp_taken;
    endgroup
    covergroup cg_pipe_pair with function sample(bit [2:0] prev, bit [2:0] cur);
        cp_prev: coverpoint prev { bins k[] = {[0:5]}; }
        cp_cur:  coverpoint cur  { bins k[] = {[0:5]}; }
        x_class_pair: cross cp_prev, cp_cur;
    endgroup
    covergroup cg_wfi with function sample(bit mti, bit mie_v, int asleep);
        cp_src: coverpoint mti { bins clic = {0}; bins mti = {1}; }
        cp_mie: coverpoint mie_v;
        x_wake_mie: cross cp_src, cp_mie;
        cp_wake_timing: coverpoint asleep { bins short_1_15 = {[1:15]}; bins mid_16_255 = {[16:255]}; bins long_256p = {[256:$]}; }
    endgroup

    cg_isa       c_isa   = new();
    cg_mul       c_mul   = new();
    cg_div       c_div   = new();
    cg_illegal   c_ill   = new();
    cg_sys       c_sys   = new();
    cg_csr_op    c_csr   = new();
    cg_trap_x    c_trap  = new();
    cg_irq       c_irq   = new();
    cg_hazard_lu c_lu    = new();
    cg_branch_k  c_br    = new();
    cg_pipe_pair c_pair  = new();
    cg_wfi       c_wfi   = new();

    // ---- sampling ----------------------------------------------------------------------
    reg [2:0]  prev_k;
    reg        prev_ok;
    int        since_trap, asleep_n;
    reg        q_q;
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            prev_ok <= 1'b0; prev_k <= 3'd0; since_trap = -1; asleep_n = 0; q_q <= 1'b0;
        end else begin
            // EX instruction moving on
            if (adv) begin
                automatic bit [2:0] k = klass(xe_instr, xe_dsu_en);
                if (is_rr_alu || opc == 7'b1100011) c_isa.sample(corner(xe_rs1), corner(xe_rs2));
                if (xe_mul_en) c_mul.sample(f3[1:0], xe_rs1[31], xe_rs2[31]);
                if (opc == 7'b1110011 || opc == 7'b0001111) begin
                    if (opc == 7'b0001111) c_sys.sample(f3 == 3'b001 ? 5 : 4);
                    else if (f3 != 3'b000) c_sys.sample(6);
                    else case (xe_instr)
                        32'h0000_0073: c_sys.sample(0);
                        32'h0010_0073: c_sys.sample(1);
                        32'h3020_0073: c_sys.sample(2);
                        32'h1050_0073: c_sys.sample(3);
                        default: ;
                    endcase
                end
                // every CSR access attempted, legal or not (an illegal one is the
                // F09 case); counter writes only when legal
                if (xe_csr_en) begin
                    automatic bit [11:0] a = xe_instr[31:20];
                    automatic bit writes = (f3[1:0] == 2'b01) || (xe_instr[19:15] != 5'd0);
                    c_csr.sample(csr_group(a), f3,
                                 (!writes || csr_illegal) ? -1 : (a == 12'hB00) ? 0 : (a == 12'hB02) ? 1 :
                                 (a == 12'hB80) ? 2 : (a == 12'hB82) ? 3 : -1);
                end
                if (xe_branch) c_br.sample(f3, xe_instr[31], xe_pred_taken ^ ex_mispredict);
                if (prev_ok) c_pair.sample(prev_k, k);
                prev_k <= k; prev_ok <= 1'b1;
            end
            // traps
            if (since_trap >= 0) since_trap++;
            if (tr_enter) begin
                c_trap.sample(-1, since_trap);
                if (!tr_is_int && tr_cause[30:0] == 31'd2) begin
                    c_ill.sample(csr_illegal ? 0 : (xe_instr == 32'd0) ? 1 : is_div ? 2 :
                                 (opc inside {7'b0110011, 7'b0010011, 7'b0110111, 7'b0010111, 7'b0000011, 7'b0100011,
                                              7'b1100011, 7'b1101111, 7'b1100111, 7'b1110011, 7'b0001111, 7'b0001011}) ? 4 : 3);
                    if (is_div) c_div.sample({f3[1], f3[0]});
                end
                if (!tr_is_int && id_valid && (id_illegal || id_fault)) c_trap.sample(id_fault ? 1 : 0, -1);   // a faulted fetch also decodes illegal: the fault is what it is
                if (tr_is_int) begin
                    c_irq.sample(0, xe_valid ? int'(klass(xe_instr, xe_dsu_en)) : 6);
                    if (irq_valid && mtip) c_irq.sample(tr_cause[30:0] == 31'd7 ? 3 : 2, 0);
                end else if (take_cond) c_irq.sample(4, 0);
                since_trap = 0;
            end
            if (tr_mret) since_trap = 0;
            if (id_valid && id_fault && (ex_redir || tr_redir)) c_trap.sample(2, -1);
            if (irq_valid && mtip) c_irq.sample(1, 0);
            // load-use consumer (the ID instruction stalled behind the load in EX)
            if (load_use && id_valid) begin
                automatic bit h1 = id_instr[19:15] == xe_rd, h2 = id_instr[24:20] == xe_rd;
                case (id_instr[6:0])
                    7'b0110011: c_lu.sample(h1 && h2 ? 2 : h2 ? 1 : 0);
                    7'b0100011: c_lu.sample(h2 ? 3 : 4);
                    7'b1100011: c_lu.sample(5);
                    7'b1100111: c_lu.sample(6);
                    7'b0000011: c_lu.sample(7);
                    default:    c_lu.sample(0);
                endcase
            end
            // WFI: wake source, MIE, time asleep
            q_q <= quiescent;
            if (quiescent) asleep_n++;
            if (q_q && !quiescent) begin
                c_wfi.sample(mtip && !irq_valid, mie, asleep_n);
                asleep_n = 0;
            end
        end
    end
endmodule

bind garuda_core_top garuda_cov_vplan u_cov_vplan (
    .clk_i(clk_i), .rst_n_i(rst_n_i),
    .xe_valid(xe_valid), .xe_mul_en(xe_mul_en), .xe_dsu_en(xe_dsu_en), .xe_csr_en(xe_csr_en),
    .xe_branch(xe_branch), .xe_jal(xe_jal), .xe_jalr(xe_jalr),
    .xe_pred_taken(xe_predicted_taken), .ex_mispredict(ex_branch_mispredict),
    // the EX operands after forwarding (the values the ALU / multiplier use; xe_rs1/2 can be stale)
    .xe_instr(xe_instr), .xe_rs1(ex_rs1_fwd), .xe_rs2(ex_rs2_fwd), .xe_rd(xe_rd),
    .mem_stall(mem_stall), .dsu_busy(ex_dsu_busy), .load_use(id_load_use),
    .id_valid(id_valid), .id_illegal(id_illegal), .id_fault(id_fault), .id_instr(id_instr),
    .ex_redir(ex_redirect), .tr_redir(tr_redir_v),
    .tr_enter(tr_enter), .tr_is_int(tr_is_int), .tr_mret(tr_mret), .tr_cause(tr_cause),
    .csr_illegal(csr_illegal),
    .irq_valid(clic_irq_valid_i), .mtip(mtip_i), .take_cond(clic_take_cond), .mie(csr_mstatus_mie),
    .quiescent(quiescent)
);
