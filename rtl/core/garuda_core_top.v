`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block I: Processor Core - TOP
// garuda_core_top.v - integrates the full RV32IM core (Sec. 2-14)
// Document: AERO-GARUDA-DS-001 Rev 1.1
//
// SoC-facing boundary (emerged from wiring, not pre-declared):
//   clk/reset, I-port AHB-Lite master, D-port AHB-Lite master, CLIC core
//   interface (Sec.14.3), machine-timer inputs (Sec.14.6), DSU accumulator
//   debug taps (Sec.15). DSU and register file are core-internal.
//
// Rev 1.1 follow-ups now closed:
//   - minstret is driven by a real retire tag threaded id_stage -> id_ex ->
//     ex_mem -> mem_stage -> mem_wb (was mem_wb.reg_write, which missed stores
//     and branches and miscounted a MEM-faulting instruction).
//   - WFI is a drain-precise hold inside pipe_ctrl (PC/IF-ID/ID-EX), not a
//     fetch-only stall at this level (Sec.14.5).
//   - The machine timer has a real interrupt path: mtip -> mip.MTIP, gated by
//     mie.MTIE and mstatus.MIE, entering via trap_ctrl with cause 0x80000007
//     (was only OR'd into the CLIC pending summary and never takeable).
// =============================================================================
module garuda_core_top #(
    parameter [31:0] RESET_VECTOR = 32'h1000_0000
)(
    input  wire        clk_i,
    input  wire        rst_n_i,

    // ---- I-port AHB-Lite master ----
    output wire [31:0] i_haddr_o,
    output wire [1:0]  i_htrans_o,
    output wire [2:0]  i_hsize_o,
    output wire [2:0]  i_hburst_o,
    output wire [3:0]  i_hprot_o,
    output wire        i_hwrite_o,
    output wire [31:0] i_hwdata_o,
    input  wire [31:0] i_hrdata_i,
    input  wire        i_hready_i,
    input  wire        i_hresp_i,

    // ---- D-port AHB-Lite master ----
    output wire [31:0] d_haddr_o,
    output wire [1:0]  d_htrans_o,
    output wire [2:0]  d_hsize_o,
    output wire [2:0]  d_hburst_o,
    output wire [3:0]  d_hprot_o,
    output wire        d_hwrite_o,
    output wire [31:0] d_hwdata_o,
    input  wire [31:0] d_hrdata_i,
    input  wire        d_hready_i,
    input  wire        d_hresp_i,

    // ---- CLIC core interface (Sec.14.3) ----
    input  wire        clic_irq_i,
    input  wire [11:0] clic_irq_id_i,
    input  wire [7:0]  clic_irq_lvl_i,
    input  wire        clic_irq_shv_i,
    output wire        clic_irq_ack_o,
    output wire [11:0] clic_irq_id_ack_o,
    output wire [7:0]  clic_mintthresh_o,

    // ---- machine timer (Sec.14.6) ----
    input  wire [63:0] mtime_i,
    input  wire [63:0] mtimecmp_i,

    // ---- DSU accumulator debug taps (Sec.15) ----
    output wire [47:0] dbg_acc_0_o,
    output wire [47:0] dbg_acc_1_o,
    output wire [47:0] dbg_acc_2_o
);
    // =========================================================================
    // inter-stage nets
    // =========================================================================
    // IF -> IF/ID
    wire [31:0] if_instr, if_pc;  wire if_valid, if_fault;
    // IF/ID -> ID
    wire [31:0] fd_instr, fd_pc;  wire fd_valid, fd_fault;
    // ID outputs
    wire id_reg_write, id_mem_read, id_mem_write, id_mem_to_reg, id_alu_src, id_alu_a_pc;
    wire [3:0] id_alu_op; wire id_branch, id_jal, id_jalr, id_mul_en, id_dsu_en, id_csr_en;
    wire [2:0] id_csr_op; wire id_is_system, id_illegal, id_fault;
    wire [31:0] id_rs1_data, id_rs2_data, id_imm, id_pc, id_instr;
    wire [4:0] id_rs1_idx, id_rs2_idx, id_rd; wire [2:0] id_funct3;
    wire id_valid; wire id_load_use, id_redir_v; wire [31:0] id_redir_t; wire id_predict_taken;
    // ID/EX outputs
    wire [31:0] xe_pc, xe_instr, xe_rs1, xe_rs2, xe_imm; wire [4:0] xe_rs1i, xe_rs2i, xe_rd;
    wire [2:0] xe_funct3; wire xe_reg_write, xe_mem_read, xe_mem_write, xe_mem_to_reg;
    wire xe_alu_src, xe_pc_op_a; wire [3:0] xe_alu_op; wire xe_branch, xe_jal, xe_jalr;
    wire xe_predicted_taken, xe_mul_en, xe_dsu_en, xe_csr_en, xe_csr_imm; wire [1:0] xe_csr_op;
    wire xe_is_system, xe_illegal, xe_fault, xe_valid;
    // forwarding
    wire [1:0] fwd_a_sel, fwd_b_sel;
    // EX outputs
    wire [31:0] ex_rs1_fwd, ex_rs2_fwd;   // post-forward operands -> ID/EX (ERRATUM F-1)
    wire [11:0] ex_csr_addr_w; wire [31:0] ex_csr_wdata; wire [1:0] ex_csr_op_out; wire ex_csr_en_out;
    wire [31:0] ex_result, ex_store_data; wire [4:0] ex_rd_out;
    wire ex_reg_write_out, ex_mem_read_out, ex_mem_write_out, ex_mem_to_reg_out;
    wire ex_redirect; wire [31:0] ex_redirect_target; wire ex_branch_mispredict;
    wire ex_load_mis, ex_store_mis, ex_dsu_illegal, ex_dsu_busy, ex_dsu_overflow;
    wire ex_fetch_mis;                    // cause 0, ERRATUM T-1
    // EX/MEM outputs
    wire [31:0] em_result, em_store, em_pc; wire [2:0] em_funct3; wire [4:0] em_rd;
    wire em_mem_read, em_mem_write, em_mem_to_reg, em_reg_write, em_valid;
    // MEM outputs
    wire [31:0] mem_wb_data; wire mem_reg_write, mem_retire; wire [4:0] mem_rd; wire mem_stall;
    wire mem_exc_v; wire [31:0] mem_exc_pc, mem_exc_tval; wire [3:0] mem_exc_cause;
    // MEM/WB outputs
    wire [31:0] mw_data; wire [4:0] mw_rd; wire mw_reg_write, mw_retire;
    // WB -> regfile write / ID bypass
    wire rf_we; wire [4:0] rf_rd; wire [31:0] rf_wdata;
    // CSR
    wire [31:0] csr_rdata; wire csr_illegal, csr_clear_ovf;
    wire csr_mstatus_mie; wire [31:0] csr_mtvec, csr_mtvt, csr_mepc; wire [7:0] csr_mintthresh, csr_mil;
    // CLIC
    wire clic_take_cond, clic_wake_cond; wire [11:0] clic_id; wire [7:0] clic_lvl;
    wire [31:0] clic_vec_target; wire clic_take;
    // trap
    wire tr_enter, tr_is_int, tr_mret; wire [7:0] tr_level; wire [31:0] tr_pc, tr_cause, tr_tval;
    wire tr_redir_v; wire [31:0] tr_redir_t; wire tr_sq_ide, tr_sq_exm, tr_sq_mwb, tr_wfi_hold, tr_ex_squash;
    // pipe_ctrl
    wire pc_if_stall, pc_if_redir; wire [31:0] pc_if_redir_pc;
    wire pc_ifid_s, pc_ifid_f, pc_idex_s, pc_idex_f, pc_exmem_s, pc_exmem_f, pc_mwb_f;

    // WFI hold is composed inside pipe_ctrl (Sec.14.5) - no top-level override.
    // machine timer pending (Sec.14.6) -> csr_file mip.MTIP
    wire mtip = (mtime_i >= mtimecmp_i);
    wire csr_mti_pending;

    // =========================================================================
    // IF stage
    // =========================================================================
    garuda_if_stage_top u_if (
        .clk_i(clk_i), .rst_n_i(rst_n_i),
        .i_haddr_o(i_haddr_o), .i_htrans_o(i_htrans_o), .i_hsize_o(i_hsize_o),
        .i_hburst_o(i_hburst_o), .i_hprot_o(i_hprot_o), .i_hwrite_o(i_hwrite_o), .i_hwdata_o(i_hwdata_o),
        .i_hrdata_i(i_hrdata_i), .i_hready_i(i_hready_i), .i_hresp_i(i_hresp_i),
        .instr_o(if_instr), .instr_pc_o(if_pc), .instr_valid_o(if_valid), .instr_fault_o(if_fault),
        .stall_i(pc_if_stall), .redirect_i(pc_if_redir), .redirect_pc_i(pc_if_redir_pc)
    );
    if_id u_ifid (
        .clk_i(clk_i), .rst_n_i(rst_n_i), .stall_i(pc_ifid_s), .flush_i(pc_ifid_f),
        .instr_i(if_instr), .pc_i(if_pc), .valid_i(if_valid), .fault_i(if_fault),
        .instr_o(fd_instr), .pc_o(fd_pc), .valid_o(fd_valid), .fault_o(fd_fault)
    );

    // =========================================================================
    // ID stage (regfile internal)
    // =========================================================================
    id_stage u_id (
        .clk_i(clk_i), .rst_n_i(rst_n_i),
        .if_id_instr_i(fd_instr), .if_id_pc_i(fd_pc), .if_id_fault_i(fd_fault), .if_id_valid_i(fd_valid),
        .wb_reg_write_i(rf_we), .wb_rd_i(rf_rd), .wb_data_i(rf_wdata),
        .ex_mem_read_i(xe_mem_read), .ex_rd_i(xe_rd),
        .reg_write_o(id_reg_write), .mem_read_o(id_mem_read), .mem_write_o(id_mem_write),
        .mem_to_reg_o(id_mem_to_reg), .alu_src_o(id_alu_src), .alu_a_pc_o(id_alu_a_pc),
        .alu_op_o(id_alu_op), .branch_o(id_branch), .jal_o(id_jal), .jalr_o(id_jalr),
        .mul_en_o(id_mul_en), .dsu_en_o(id_dsu_en), .csr_en_o(id_csr_en), .csr_op_o(id_csr_op),
        .is_system_o(id_is_system), .illegal_instr_dec_o(id_illegal),
        .rs1_data_o(id_rs1_data), .rs2_data_o(id_rs2_data), .imm_o(id_imm), .pc_o(id_pc),
        .rs1_idx_o(id_rs1_idx), .rs2_idx_o(id_rs2_idx), .rd_o(id_rd), .funct3_o(id_funct3),
        .instr_o(id_instr), .fault_o(id_fault),
        .load_use_stall_o(id_load_use),
        .id_redirect_valid_o(id_redir_v), .id_redirect_target_o(id_redir_t),
        .predict_taken_o(id_predict_taken), .valid_o(id_valid)
    );
    id_ex u_idex (
        .clk_i(clk_i), .rst_n_i(rst_n_i), .stall_i(pc_idex_s), .flush_i(pc_idex_f),
        .pc_i(id_pc), .instr_i(id_instr), .rs1_data_i(id_rs1_data), .rs2_data_i(id_rs2_data),
        .rs1_fwd_i(ex_rs1_fwd), .rs2_fwd_i(ex_rs2_fwd),   // ERRATUM F-1 operand capture
        .imm_i(id_imm), .rs1_idx_i(id_rs1_idx), .rs2_idx_i(id_rs2_idx), .rd_i(id_rd), .funct3_i(id_funct3),
        .reg_write_i(id_reg_write), .mem_read_i(id_mem_read), .mem_write_i(id_mem_write),
        .mem_to_reg_i(id_mem_to_reg), .alu_src_i(id_alu_src), .pc_op_a_i(id_alu_a_pc),
        .alu_op_i(id_alu_op), .branch_i(id_branch), .jal_i(id_jal), .jalr_i(id_jalr),
        .predicted_taken_i(id_predict_taken), .mul_en_i(id_mul_en), .dsu_en_i(id_dsu_en),
        .csr_en_i(id_csr_en), .csr_imm_i(id_csr_op[2]), .csr_op_i(id_csr_op[1:0]),
        .is_system_i(id_is_system), .illegal_instr_dec_i(id_illegal), .fault_i(id_fault), .valid_i(id_valid),
        .pc_o(xe_pc), .instr_o(xe_instr), .rs1_data_o(xe_rs1), .rs2_data_o(xe_rs2), .imm_o(xe_imm),
        .rs1_idx_o(xe_rs1i), .rs2_idx_o(xe_rs2i), .rd_o(xe_rd), .funct3_o(xe_funct3),
        .reg_write_o(xe_reg_write), .mem_read_o(xe_mem_read), .mem_write_o(xe_mem_write),
        .mem_to_reg_o(xe_mem_to_reg), .alu_src_o(xe_alu_src), .pc_op_a_o(xe_pc_op_a),
        .alu_op_o(xe_alu_op), .branch_o(xe_branch), .jal_o(xe_jal), .jalr_o(xe_jalr),
        .predicted_taken_o(xe_predicted_taken), .mul_en_o(xe_mul_en), .dsu_en_o(xe_dsu_en),
        .csr_en_o(xe_csr_en), .csr_imm_o(xe_csr_imm), .csr_op_o(xe_csr_op),
        .is_system_o(xe_is_system), .illegal_instr_dec_o(xe_illegal), .fault_o(xe_fault), .valid_o(xe_valid)
    );

    // =========================================================================
    // EX stage (DSU internal) + forwarding
    // =========================================================================
    forward_unit u_fwd (
        .id_ex_rs1_idx_i(xe_rs1i), .id_ex_rs2_idx_i(xe_rs2i),
        .exmem_rd_i(em_rd), .exmem_reg_write_i(em_reg_write),
        .memwb_rd_i(mw_rd), .memwb_reg_write_i(mw_reg_write),
        .fwd_a_sel_o(fwd_a_sel), .fwd_b_sel_o(fwd_b_sel)
    );
    ex_stage u_ex (
        .clk(clk_i), .rst_n(rst_n_i),
        .pc(xe_pc), .instr(xe_instr), .rs1_data(xe_rs1), .rs2_data(xe_rs2), .imm(xe_imm),
        .rd(xe_rd), .funct3(xe_funct3), .reg_write(xe_reg_write), .mem_read(xe_mem_read),
        .mem_write(xe_mem_write), .mem_to_reg(xe_mem_to_reg), .alu_src(xe_alu_src),
        .pc_op_a(xe_pc_op_a), .alu_op(xe_alu_op), .branch(xe_branch), .jal(xe_jal), .jalr(xe_jalr),
        .predicted_taken(xe_predicted_taken), .mul_en(xe_mul_en), .dsu_en(xe_dsu_en),
        .csr_en(xe_csr_en), .csr_imm(xe_csr_imm), .csr_op(xe_csr_op),
        .fwd_a_sel(fwd_a_sel), .fwd_b_sel(fwd_b_sel),
        .exmem_fwd_data(em_result), .memwb_fwd_data(mw_data),
        .csr_rdata(csr_rdata), .csr_clear_overflow(csr_clear_ovf), .ex_squash(tr_ex_squash),
        .csr_addr(ex_csr_addr_w), .csr_wdata(ex_csr_wdata), .csr_op_out(ex_csr_op_out), .csr_en_out(ex_csr_en_out),
        .ex_result(ex_result), .store_data(ex_store_data),
        .rs1_fwd_o(ex_rs1_fwd), .rs2_fwd_o(ex_rs2_fwd), .fetch_misaligned(ex_fetch_mis), .rd_out(ex_rd_out),
        .reg_write_out(ex_reg_write_out), .mem_read_out(ex_mem_read_out),
        .mem_write_out(ex_mem_write_out), .mem_to_reg_out(ex_mem_to_reg_out),
        .ex_redirect(ex_redirect), .ex_redirect_target(ex_redirect_target),
        .branch_mispredict(ex_branch_mispredict), .load_misaligned(ex_load_mis),
        .store_misaligned(ex_store_mis), .dsu_illegal_instr(ex_dsu_illegal),
        .dsu_busy(ex_dsu_busy), .dsu_overflow(ex_dsu_overflow),
        .dbg_acc_0(dbg_acc_0_o), .dbg_acc_1(dbg_acc_1_o), .dbg_acc_2(dbg_acc_2_o)
    );
    ex_mem u_exmem (
        .clk_i(clk_i), .rst_n_i(rst_n_i), .stall_i(pc_exmem_s), .flush_i(pc_exmem_f),
        .ex_result_i(ex_result), .store_data_i(ex_store_data), .funct3_i(xe_funct3),
        .rd_i(ex_rd_out), .pc_i(xe_pc), .mem_read_i(ex_mem_read_out), .mem_write_i(ex_mem_write_out),
        .mem_to_reg_i(ex_mem_to_reg_out), .reg_write_i(ex_reg_write_out), .valid_i(xe_valid),
        .ex_result_o(em_result), .store_data_o(em_store), .funct3_o(em_funct3), .rd_o(em_rd),
        .pc_o(em_pc), .mem_read_o(em_mem_read), .mem_write_o(em_mem_write),
        .mem_to_reg_o(em_mem_to_reg), .reg_write_o(em_reg_write), .valid_o(em_valid)
    );

    // =========================================================================
    // MEM + WB
    // =========================================================================
    mem_stage u_mem (
        .clk_i(clk_i), .rst_n_i(rst_n_i),
        .ex_result_i(em_result), .rs2_data_i(em_store), .funct3_i(em_funct3), .rd_i(em_rd),
        .pc_i(em_pc), .mem_read_i(em_mem_read), .mem_write_i(em_mem_write),
        .mem_to_reg_i(em_mem_to_reg), .reg_write_i(em_reg_write), .valid_i(em_valid),
        .d_haddr_o(d_haddr_o), .d_htrans_o(d_htrans_o), .d_hsize_o(d_hsize_o),
        .d_hburst_o(d_hburst_o), .d_hprot_o(d_hprot_o), .d_hwrite_o(d_hwrite_o), .d_hwdata_o(d_hwdata_o),
        .d_hrdata_i(d_hrdata_i), .d_hready_i(d_hready_i), .d_hresp_i(d_hresp_i),
        .wb_data_o(mem_wb_data), .reg_write_o(mem_reg_write), .rd_o(mem_rd), .retire_o(mem_retire),
        .mem_stall_o(mem_stall),
        .mem_exception_valid_o(mem_exc_v), .mem_exception_pc_o(mem_exc_pc),
        .mem_exception_cause_o(mem_exc_cause), .mem_exception_mtval_o(mem_exc_tval)
    );
    mem_wb_reg u_memwb (
        .clk_i(clk_i), .rst_n_i(rst_n_i), .flush_i(pc_mwb_f),
        .wb_data_i(mem_wb_data), .rd_i(mem_rd), .reg_write_i(mem_reg_write), .retire_i(mem_retire),
        .wb_data_o(mw_data), .rd_o(mw_rd), .reg_write_o(mw_reg_write), .retire_o(mw_retire)
    );
    wb_stage u_wb (
        .wb_data_i(mw_data), .rd_i(mw_rd), .reg_write_i(mw_reg_write),
        .rf_we_o(rf_we), .rf_rd_o(rf_rd), .rf_wdata_o(rf_wdata)
    );

    // =========================================================================
    // CONTROL / CSR / TRAP / CLIC
    // =========================================================================
    csr_file u_csr (
        .clk_i(clk_i), .rst_n_i(rst_n_i),
        .csr_en_i(ex_csr_en_out), .csr_addr_i(ex_csr_addr_w), .csr_wdata_i(ex_csr_wdata),
        .csr_op_i(ex_csr_op_out), .csr_rdata_o(csr_rdata), .illegal_csr_o(csr_illegal),
        .instret_i(mw_retire),                        // true architectural retire
        .dsu_overflow_i(ex_dsu_overflow), .csr_clear_overflow_o(csr_clear_ovf),
        .trap_enter_i(tr_enter), .mret_i(tr_mret), .is_interrupt_i(tr_is_int),
        .clic_level_i(tr_level), .trap_pc_i(tr_pc), .trap_cause_i(tr_cause), .trap_tval_i(tr_tval),
        .clic_mip_i(clic_irq_i), .mtip_i(mtip),
        .mstatus_mie_o(csr_mstatus_mie), .mtvec_o(csr_mtvec), .mtvt_o(csr_mtvt),
        .mepc_o(csr_mepc), .mintthresh_o(csr_mintthresh), .mintstatus_mil_o(csr_mil),
        .mti_pending_o(csr_mti_pending)
    );
    assign clic_mintthresh_o = csr_mintthresh;

    clic_ctrl #(.ID_W(12)) u_clic (
        .clic_irq_i(clic_irq_i), .clic_irq_id_i(clic_irq_id_i), .clic_irq_lvl_i(clic_irq_lvl_i),
        .clic_irq_shv_i(clic_irq_shv_i), .clic_irq_ack_o(clic_irq_ack_o), .clic_irq_id_ack_o(clic_irq_id_ack_o),
        .mstatus_mie_i(csr_mstatus_mie), .mintthresh_i(csr_mintthresh), .mintstatus_mil_i(csr_mil),
        .mtvec_i(csr_mtvec), .mtvt_i(csr_mtvt),
        .take_cond_o(clic_take_cond), .wake_cond_o(clic_wake_cond), .irq_id_o(clic_id),
        .irq_lvl_o(clic_lvl), .vector_target_o(clic_vec_target), .take_i(clic_take)
    );
    trap_ctrl #(.ID_W(12)) u_trap (
        .clk_i(clk_i), .rst_n_i(rst_n_i),
        .idex_pc_i(xe_pc), .idex_instr_i(xe_instr), .idex_fault_i(xe_fault),
        .idex_illegal_dec_i(xe_illegal), .idex_is_system_i(xe_is_system),
        .ex_dsu_illegal_i(ex_dsu_illegal), .ex_csr_illegal_i(csr_illegal),
        .ex_load_misalign_i(ex_load_mis), .ex_store_misalign_i(ex_store_mis), .ex_addr_i(ex_result),
        .ex_fetch_misalign_i(ex_fetch_mis), .ex_fetch_target_i(ex_redirect_target),
        .mem_exc_valid_i(mem_exc_v), .mem_exc_cause_i(mem_exc_cause),
        .mem_exc_pc_i(mem_exc_pc), .mem_exc_tval_i(mem_exc_tval),
        .clic_take_cond_i(clic_take_cond), .clic_wake_cond_i(clic_wake_cond),
        .clic_irq_id_i(clic_id), .clic_irq_lvl_i(clic_lvl), .clic_vector_target_i(clic_vec_target),
        .clic_take_o(clic_take), .mti_pending_i(csr_mti_pending),
        .mtvec_i(csr_mtvec), .mepc_i(csr_mepc), .mstatus_mie_i(csr_mstatus_mie),
        .trap_enter_o(tr_enter), .is_interrupt_o(tr_is_int), .clic_level_o(tr_level), .mret_o(tr_mret),
        .trap_pc_o(tr_pc), .trap_cause_o(tr_cause), .trap_tval_o(tr_tval),
        .trap_redirect_valid_o(tr_redir_v), .trap_redirect_target_o(tr_redir_t),
        .trap_squash_id_ex_o(tr_sq_ide), .trap_squash_ex_mem_o(tr_sq_exm),
        .trap_squash_mem_wb_o(tr_sq_mwb), .wfi_hold_o(tr_wfi_hold), .ex_squash_o(tr_ex_squash)
    );
    pipe_ctrl u_pipe (
        .mem_stall_i(mem_stall), .dsu_busy_i(ex_dsu_busy), .load_use_stall_i(id_load_use), .wfi_hold_i(tr_wfi_hold),
        .id_redirect_valid_i(id_redir_v), .id_redirect_target_i(id_redir_t),
        .ex_redirect_i(ex_redirect), .ex_redirect_target_i(ex_redirect_target),
        .trap_redirect_valid_i(tr_redir_v), .trap_redirect_target_i(tr_redir_t),
        .trap_squash_id_ex_i(tr_sq_ide), .trap_squash_ex_mem_i(tr_sq_exm), .trap_squash_mem_wb_i(tr_sq_mwb),
        .if_stall_o(pc_if_stall), .if_redirect_o(pc_if_redir), .if_redirect_pc_o(pc_if_redir_pc),
        .if_id_stall_o(pc_ifid_s), .if_id_flush_o(pc_ifid_f),
        .id_ex_stall_o(pc_idex_s), .id_ex_flush_o(pc_idex_f),
        .ex_mem_stall_o(pc_exmem_s), .ex_mem_flush_o(pc_exmem_f), .mem_wb_flush_o(pc_mwb_f)
    );
endmodule
`default_nettype wire
