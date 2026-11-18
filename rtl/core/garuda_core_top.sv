// =============================================================================
// GARUDA SoC - Block I: Processor Core - TOP
// garuda_core_top.v - integrates the full RV32IM core (Sec. 2-14)
// Document: AERO-GARUDA-DS-001 Rev 1.1; boundary per GARUDA-CORE-SPEC-001
//           Rev 3.0 Sec.5 (Rev 4.0 set)
//
// Rev 3.0 boundary (RTL deltas R4, R5, R7, R11):
//   - mtip_i replaces mtime_i/mtimecmp_i and the in-core 64-bit comparator;
//     the compare lives in block 11 (ADR-0010).
// - (D-36, 2026-11-16) one reset input, core_rst_n_i: reset_ctrl also asserts
// it
// for the Debug Module's hartreset ([N-7.33]); the hartreset_n_i input of Rev
// 3.0
//     is gone.
//   - clic_mintthresh_o is gone; the CLIC interface is {valid, id[4:0],
//     level[7:0]}, level-triggered, no acknowledge (CLIC-SPEC Sec.5).
//   - Every core flop runs on a gated clock from core_clk_gate, enabled by
//     ~pipe_ctrl.quiescent ([N-7.28]). CLK_GATE=0 ties the gate open.
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
module garuda_core_top
    import garuda_pkg::*;
#(
    parameter [31:0] RESET_VECTOR = 32'h1000_0000,  // GARUDA_RESET_VECTOR
    parameter integer        CLK_GATE     = 32'd1
)(
    input wire hclk,  // hclk, ungated
    input wire core_rst_n,  // from reset_ctrl
    // ERRATUM RDC-1 (reset-domain review crossing 5; fixed 2026-10-11): a
    // debugger halt (= hartreset, ADR-0012) used to reset the core at any
    // cycle, also in the waited data phase of a store, on a bus that is NOT
    // reset: the store's HWDATA changed under the slave and a presented address
    // was withdrawn. Now the Debug Module first raises halt_req_i: the core
    // starts no new fetch, the instructions already fetched drain (a few,
    // bounded), and halt_safe_o reports that neither port presents an address
    // or owns a data phase. Only then (or after a bounded timeout, flagged
    // sticky) does the Debug Module assert hartreset. Test:
    // tb/core/tb_core_halt.sv.
    input wire halt_req_i,  // from the Debug Module: drain, a reset follows
    // to the Debug Module: a reset now breaks no transfer
    output wire halt_safe_o,
    // ---- I-port AHB-Lite master ----
    output wire [WORD_W-1:0] i_haddr_o,
    output wire [HTRANS_W-1:0] i_htrans_o,
    output wire [HSIZE_W-1:0] i_hsize_o,
    output wire [HBURST_W-1:0] i_hburst_o,
    output wire [HPROT_W-1:0] i_hprot_o,
    output wire i_hwrite_o,
    output wire [WORD_W-1:0] i_hwdata_o,
    input wire [WORD_W-1:0] i_hrdata_i,
    input wire i_hready_i,
    input wire i_hresp_i,
    // ---- D-port AHB-Lite master ----
    output wire [WORD_W-1:0] d_haddr_o,
    output wire [HTRANS_W-1:0] d_htrans_o,
    output wire [HSIZE_W-1:0] d_hsize_o,
    output wire [HBURST_W-1:0] d_hburst_o,
    output wire [HPROT_W-1:0] d_hprot_o,
    output wire d_hwrite_o,
    output wire [WORD_W-1:0] d_hwdata_o,
    input wire [WORD_W-1:0] d_hrdata_i,
    input wire d_hready_i,
    input wire d_hresp_i,
    // ---- CLIC (block 10) ----
    input wire clic_irq_valid_i,
    input wire [CLIC_ID_W-1:0] clic_irq_id_i,
    input wire [CLIC_LVL_W-1:0] clic_irq_level_i,
    // ---- machine timer (block 11) ----
    input wire mtip_i,
    // ---- DSU accumulator debug taps (Sec.15) ----
    output wire [ACC_W-1:0] dbg_acc_0_o,
    output wire [ACC_W-1:0] dbg_acc_1_o,
    output wire [ACC_W-1:0] dbg_acc_2_o,
    output wire dsu_ovf_o,  // sticky DSU overflow (read by the DM)
    // clock gated (observability)
    // RISC-V Formal Interface (plan 5.1): verification builds only
    output wire core_sleep_o `ifdef GARUDA_RVFI,
    output wire rvfi_valid,
    output wire [63:0] rvfi_order,
    output wire [31:0] rvfi_insn,
    output wire rvfi_trap,
    output wire rvfi_halt,
    output wire rvfi_intr,
    output wire [1:0] rvfi_mode,
    output wire [1:0] rvfi_ixl,
    output wire [4:0] rvfi_rs1_addr,
    output wire [4:0] rvfi_rs2_addr,
    output wire [31:0] rvfi_rs1_rdata,
    output wire [31:0] rvfi_rs2_rdata,
    output wire [4:0] rvfi_rd_addr,
    output wire [31:0] rvfi_rd_wdata,
    output wire [31:0] rvfi_pc_rdata,
    output wire [31:0] rvfi_pc_wdata,
    output wire [31:0] rvfi_mem_addr,
    output wire [3:0] rvfi_mem_rmask,
    output wire [3:0] rvfi_mem_wmask,
    output wire [31:0] rvfi_mem_rdata,
    output wire [31:0] rvfi_mem_wdata `endif
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned CSR_CTL_W = 32'd4;
    localparam int unsigned XE_RSI_W = 32'd5;
    localparam int unsigned XE_RSIB_W = 32'd5;
    localparam int unsigned CLIC_IDB_W = 32'd5;
    // =========================================================================
    // reset and clock
    // =========================================================================
    // [N-7.33] (D-36, 2026-11-16): one reset input. reset_ctrl asserts
    // core_rst_n for every system reset and, one hclk after it, for the Debug
    // Module's hartreset grant, and releases it synchronously to hclk. Until
    // 2026-11-16 the core had a second input, hartreset_n_i, ANDed here in
    // front of the asynchronous resets (HAL GLTASR).
    // CORE-4: mgarudactl (BP_DIS, PF_DIS, PREEMPT_DIS, CG_DIS)
    wire [CSR_CTL_W-1:0] csr_ctl;
    wire gclk;
    wire quiescent;

    // =========================================================================
    // inter-stage nets
    // =========================================================================
    // IF -> IF/ID
    wire [WORD_W-1:0] if_instr;
    wire [WORD_W-1:0] if_pc;
    wire if_valid;
    wire if_fault;
    // IF/ID -> ID
    wire [WORD_W-1:0] fd_instr;
    wire [WORD_W-1:0] fd_pc;
    wire fd_valid;
    wire fd_fault;
    // ID outputs
    wire id_reg_write;
    wire id_mem_read;
    wire id_mem_write;
    wire id_alu_src;
    wire id_alu_a_pc;
    wire [ALU_OP_W-1:0] id_alu_op;
    wire id_branch;
    wire id_jal;
    wire id_jalr;
    wire id_mul_en;
    wire id_dsu_en;
    wire id_csr_en;
    wire [CSR_FN_W-1:0] id_csr_op;
    wire id_is_system;
    wire id_illegal;
    wire id_fault;
    wire [WORD_W-1:0] id_rs1_data;
    wire [WORD_W-1:0] id_rs2_data;
    wire [WORD_W-1:0] id_imm;
    wire [WORD_W-1:0] id_pc;
    wire [WORD_W-1:0] id_instr;
    wire [REG_IDX_W-1:0] id_rs1_idx;
    wire [REG_IDX_W-1:0] id_rs2_idx;
    wire [REG_IDX_W-1:0] id_rd;
    wire [FUNCT3_W-1:0] id_funct3_fld;
    wire id_valid;
    wire id_load_use;
    wire id_redir_v;
    wire [WORD_W-1:0] id_redir_t;
    wire id_predict_taken;
    // ID/EX outputs
    wire [WORD_W-1:0] xe_pc;
    wire [WORD_W-1:0] xe_instr;
    wire [WORD_W-1:0] xe_rs1_val;
    wire [WORD_W-1:0] xe_rs2_val;
    wire [WORD_W-1:0] xe_imm;
    wire [XE_RSI_W-1:0] xe_rs1i;
    wire [XE_RSIB_W-1:0] xe_rs2i;
    wire [REG_IDX_W-1:0] xe_rd;
    wire [FUNCT3_W-1:0] xe_funct3_fld;
    wire xe_reg_write;
    wire xe_mem_read;
    wire xe_mem_write;
    wire xe_alu_src;
    wire xe_pc_op_a;
    wire [ALU_OP_W-1:0] xe_alu_op;
    wire xe_branch;
    wire xe_jal;
    wire xe_jalr;
    wire xe_predicted_taken;
    wire xe_mul_en;
    wire xe_dsu_en;
    wire xe_csr_en;
    wire xe_csr_imm;
    wire [CSR_OP_W-1:0] xe_csr_op;
    wire xe_is_system;
    wire xe_illegal;
    wire xe_fault;
    wire xe_valid;
    // forwarding
    wire [FWD_SEL_W-1:0] fwd_a_sel;
    wire [FWD_SEL_W-1:0] fwd_b_sel;
    // EX outputs
    // post-forward operands -> ID/EX (ERRATUM F-1)
    wire [WORD_W-1:0] ex_rs1_fwd;
    wire [WORD_W-1:0] ex_rs2_fwd;
    // the CSR access in EX goes to csr_file straight from ID/EX (F4)
    wire [CSR_ADDR_W-1:0] ex_csr_addr_w = xe_instr[31:20];
    wire [WORD_W-1:0] ex_csr_wdata;
    wire [WORD_W-1:0] ex_result;
    wire [REG_IDX_W-1:0] ex_rd_out;
    wire ex_reg_write_out;
    wire ex_mem_read_out;
    wire ex_mem_write_out;
    wire ex_redirect;
    wire [WORD_W-1:0] ex_redirect_target;
    wire ex_load_mis;
    wire ex_store_mis;
    wire ex_dsu_illegal;
    wire ex_dsu_busy;
    wire ex_dsu_overflow;
    wire ex_dsu_ovf_pending;
    wire ex_fetch_mis;  // cause 0, ERRATUM T-1
    // EX/MEM outputs
    wire [WORD_W-1:0] em_result;
    wire [WORD_W-1:0] em_store;
    wire [WORD_W-1:0] em_pc;
    wire [FUNCT3_W-1:0] em_funct3_fld;
    wire [REG_IDX_W-1:0] em_rd;
    wire em_mem_read;
    wire em_mem_write;
    wire em_reg_write;
    wire em_valid;
    // MEM outputs
    wire [WORD_W-1:0] mem_wb_data;
    wire mem_reg_write;
    wire mem_retire;
    wire [REG_IDX_W-1:0] mem_rd;
    wire mem_stall;
    wire mem_exc_v;
    wire [WORD_W-1:0] mem_exc_pc;
    wire [WORD_W-1:0] mem_exc_tval;
    wire [EXC_CAUSE_W-1:0] mem_exc_cause;
    // MEM/WB outputs
    wire [WORD_W-1:0] mw_data;
    wire [REG_IDX_W-1:0] mw_rd;
    wire mw_reg_write;
    wire mw_retire;
    // WB -> regfile write / ID bypass
    wire rf_we;
    wire [REG_IDX_W-1:0] rf_rd;
    wire [WORD_W-1:0] rf_wdata;
    // CSR
    wire [WORD_W-1:0] csr_rdata;
    wire csr_illegal;
    wire csr_clear_ovf;
    wire csr_mstatus_mie;
    wire [WORD_W-1:0] csr_mtvec;
    wire [WORD_W-1:0] csr_mepc;
    wire [BYTE_W-1:0] csr_mintthresh;
    wire [BYTE_W-1:0] csr_mil;
    // CLIC
    wire clic_take_cond;
    wire clic_wake_cond;
    wire [CLIC_IDB_W-1:0] clic_id;
    wire [BYTE_W-1:0] clic_lvl;
    wire [WORD_W-1:0] clic_vec_target;
    // trap
    wire tr_enter;
    wire tr_is_int;
    wire tr_mret;
    wire [CLIC_LVL_W-1:0] tr_level;
    wire [WORD_W-1:0] tr_pc;
    wire [TRAP_CODE_W-1:0] tr_cause;
    wire [WORD_W-1:0] tr_tval;
    wire tr_redir_v;
    wire [WORD_W-1:0] tr_redir_t;
    wire tr_sq_ide;
    wire tr_sq_exm;
    wire tr_sq_mwb;
    wire tr_wfi_hold;
    // pipe_ctrl
    wire pc_if_stall;
    wire pc_if_redir;
    wire [WORD_W-1:0] pc_if_redir_pc;
    wire ex_parked;
    wire ex_commit;
    wire pc_ifid_s;
    wire pc_ifid_f;
    wire pc_idex_s;
    wire pc_idex_f;
    wire pc_exmem_s;
    wire pc_exmem_f;
    wire pc_mwb_f;

    // WFI hold is composed inside pipe_ctrl (Sec.14.5) - no top-level override.
    wire mtip = mtip_i;
    wire csr_mti_pending;

    // =========================================================================
    // Root clock gate (R11). Everything below this point is clocked by gclk.
    // =========================================================================
    // The gate's enable: the core not quiescent, or gating off (CLK_GATE = 0,
    // or
    // CORE-4's CG_DIS = mgarudactl[3]), or scan. scan_en is tied off until scan
    // is inserted (G7; the stated DFT open item).
    wire scan_en = 1'b0;
    wire cg_en   = ~quiescent | (CLK_GATE == 0) | csr_ctl[3] | scan_en;

    core_clk_gate u_cg (
        .hclk(hclk), .en_i(cg_en), .gclk_o(gclk)
    );
    assign core_sleep_o = quiescent;

    // Bus activity for quiescent: a port is busy while it presents a transfer
    // or owns an unfinished data phase.
    reg i_dph_q;
    reg d_dph_q;
    reg wfi_q1;
    reg wfi_q2;
    always_ff @(posedge gclk or negedge core_rst_n) begin : p_i_dph
        if (!core_rst_n) begin
            i_dph_q <= 1'b0;
            d_dph_q <= 1'b0;
            wfi_q1 <= 1'b0;
            wfi_q2 <= 1'b0;
        end else begin
            if (i_hready_i) begin
                i_dph_q <= i_htrans_o[1];
            end
            if (d_hready_i) begin
                d_dph_q <= d_htrans_o[1];
            end
            wfi_q1 <= tr_wfi_hold;
            wfi_q2 <= wfi_q1;
        end
    end
    // ERRATUM P-8 (2026-10-04, found by t_hold_flush_matrix under +IRQ_EVERY
    // with D-port waits): "idle" also means MEM and WB are empty. wfi_q2 allows
    // two cycles for the back end to drain, which is enough only when the last
    // instruction before the WFI takes no bus wait. A load or store stretched
    // by wait states finished its data phase, moved into MEM/WB, and the gate
    // closed on it in that same cycle - so it sat in MEM/WB, unretired and with
    // a load's register write not yet done, for the whole sleep.
    // neither port presents an address or owns a data phase
    wire ports_idle = ~i_htrans_o[1] & ~d_htrans_o[1] & ~i_dph_q & ~d_dph_q;
    wire bus_idle   = ports_idle & ~em_valid & ~mw_retire & ~mw_reg_write;
    // RDC-1: no address presented and no data phase owned on either port, now
    // or in the next clock. The hart reset falls one hclk after the Debug
    // Module's grant (D-36), so a load or store in EX or MEM, which would
    // present its D-port address in that clock, makes the point unsafe (until
    // 2026-11-16 the reset fell in the grant's own clock and the port part
    // alone was enough; JasperGold a_d_addr_stable). The I-port presents
    // nothing new: fetch is stopped by halt_req_i, held through the grant.
    assign halt_safe_o = ports_idle &
                         ~(xe_valid & (xe_mem_read | xe_mem_write)) &
                         ~(em_valid & (em_mem_read | em_mem_write));

    // =========================================================================
    // IF stage
    // =========================================================================
    if_stage_top #(.RESET_VECTOR(RESET_VECTOR)) u_if (
        .gclk(gclk), .core_rst_n(core_rst_n),
        .i_haddr_o(i_haddr_o), .i_htrans_o(i_htrans_o), .i_hsize_o(i_hsize_o),
        .i_hburst_o(i_hburst_o), .i_hprot_o(i_hprot_o), .i_hwrite_o(i_hwrite_o),
            .i_hwdata_o(i_hwdata_o),
        .i_hrdata_i(i_hrdata_i), .i_hready_i(i_hready_i), .i_hresp_i(i_hresp_i),
        .instr_o(if_instr), .instr_pc_o(if_pc), .instr_valid_o(if_valid),
            .instr_fault_o(if_fault),
        .stall_i(pc_if_stall), .redirect_i(pc_if_redir),
            .redirect_pc_i(pc_if_redir_pc),
        .fetch_stop_i(halt_req_i),  // RDC-1
        .pf_dis_i(csr_ctl[1])  // CORE-4: PF_DIS
    );
    if_id u_ifid (
        .gclk(gclk), .core_rst_n(core_rst_n), .stall_i(pc_ifid_s),
            .flush_i(pc_ifid_f),
        .instr_i(if_instr), .pc_i(if_pc), .valid_i(if_valid),
            .fault_i(if_fault),
        .instr_o(fd_instr), .pc_o(fd_pc), .valid_o(fd_valid), .fault_o(fd_fault)
    );

    // =========================================================================
    // ID stage (regfile internal)
    // =========================================================================
    id_stage u_id (
        .gclk(gclk),
        .if_id_instr_i(fd_instr), .if_id_pc_i(fd_pc), .if_id_fault_i(fd_fault),
            .if_id_valid_i(fd_valid),
        .wb_reg_write_i(rf_we), .wb_rd_i(rf_rd), .wb_data_i(rf_wdata),
        .ex_mem_read_i(xe_mem_read), .ex_rd_i(xe_rd),
        .reg_write_o(id_reg_write), .mem_read_o(id_mem_read),
            .mem_write_o(id_mem_write), .alu_src_o(id_alu_src),
            .alu_a_pc_o(id_alu_a_pc),
        .alu_op_o(id_alu_op), .branch_o(id_branch), .jal_o(id_jal),
            .jalr_o(id_jalr),
        .mul_en_o(id_mul_en), .dsu_en_o(id_dsu_en), .csr_en_o(id_csr_en),
            .csr_op_o(id_csr_op),
        .is_system_o(id_is_system), .illegal_instr_dec_o(id_illegal),
        .rs1_data_o(id_rs1_data), .rs2_data_o(id_rs2_data), .imm_o(id_imm),
            .pc_o(id_pc),
        .rs1_idx_o(id_rs1_idx), .rs2_idx_o(id_rs2_idx), .rd_o(id_rd),
            .funct3_o(id_funct3_fld),
        .instr_o(id_instr), .fault_o(id_fault),
        .load_use_stall_o(id_load_use),
        .id_redirect_valid_o(id_redir_v), .id_redirect_target_o(id_redir_t),
        .predict_taken_o(id_predict_taken), .valid_o(id_valid),
        .bp_dis_i(csr_ctl[0])  // CORE-4: BP_DIS
    );
    id_ex u_idex (
        .gclk(gclk), .core_rst_n(core_rst_n), .stall_i(pc_idex_s),
            .flush_i(pc_idex_f),
        .pc_i(id_pc), .instr_i(id_instr), .rs1_data_i(id_rs1_data),
            .rs2_data_i(id_rs2_data),
        // ERRATUM F-1 operand capture
        .rs1_fwd_i(ex_rs1_fwd), .rs2_fwd_i(ex_rs2_fwd),
        .imm_i(id_imm), .rs1_idx_i(id_rs1_idx), .rs2_idx_i(id_rs2_idx),
            .rd_i(id_rd), .funct3_i(id_funct3_fld),
        .reg_write_i(id_reg_write), .mem_read_i(id_mem_read),
            .mem_write_i(id_mem_write), .alu_src_i(id_alu_src),
            .pc_op_a_i(id_alu_a_pc),
        .alu_op_i(id_alu_op), .branch_i(id_branch), .jal_i(id_jal),
            .jalr_i(id_jalr),
        .predicted_taken_i(id_predict_taken), .mul_en_i(id_mul_en),
            .dsu_en_i(id_dsu_en),
        .csr_en_i(id_csr_en), .csr_imm_i(id_csr_op[2]),
            .csr_op_i(id_csr_op[1:0]),
        .is_system_i(id_is_system), .illegal_instr_dec_i(id_illegal),
            .fault_i(id_fault), .valid_i(id_valid),
        .pc_o(xe_pc), .instr_o(xe_instr), .rs1_data_o(xe_rs1_val),
            .rs2_data_o(xe_rs2_val), .imm_o(xe_imm),
        .rs1_idx_o(xe_rs1i), .rs2_idx_o(xe_rs2i), .rd_o(xe_rd),
            .funct3_o(xe_funct3_fld),
        .reg_write_o(xe_reg_write), .mem_read_o(xe_mem_read),
            .mem_write_o(xe_mem_write), .alu_src_o(xe_alu_src),
            .pc_op_a_o(xe_pc_op_a),
        .alu_op_o(xe_alu_op), .branch_o(xe_branch), .jal_o(xe_jal),
            .jalr_o(xe_jalr),
        .predicted_taken_o(xe_predicted_taken), .mul_en_o(xe_mul_en),
            .dsu_en_o(xe_dsu_en),
        .csr_en_o(xe_csr_en), .csr_imm_o(xe_csr_imm), .csr_op_o(xe_csr_op),
        .is_system_o(xe_is_system), .illegal_instr_dec_o(xe_illegal),
            .fault_o(xe_fault), .valid_o(xe_valid)
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
    // the DSU is enabled for the instruction in EX unless it is parked
    wire ex_dsu_go = xe_dsu_en & ~ex_parked;

    ex_stage u_ex (
        .gclk(gclk), .core_rst_n(core_rst_n),
        .pc(xe_pc), .instr(xe_instr), .rs1_data(xe_rs1_val),
            .rs2_data(xe_rs2_val), .imm(xe_imm),
        .rd(xe_rd), .funct3_fld(xe_funct3_fld), .reg_write(xe_reg_write),
            .mem_read(xe_mem_read),
        .mem_write(xe_mem_write),
            .alu_src(xe_alu_src),
        .pc_op_a(xe_pc_op_a), .alu_op(xe_alu_op), .is_branch(xe_branch),
            .jal(xe_jal), .jalr(xe_jalr),
        .predicted_taken(xe_predicted_taken), .mul_en(xe_mul_en),
            .dsu_en(ex_dsu_go),
        .csr_en(xe_csr_en), .csr_imm(xe_csr_imm),
        .fwd_a_sel(fwd_a_sel), .fwd_b_sel(fwd_b_sel),
        .exmem_fwd_data(em_result), .memwb_fwd_data(mw_data),
        .csr_rdata(csr_rdata), .csr_clear_overflow(csr_clear_ovf),
            .ex_squash(tr_sq_ide),  // trap_now: the DSU's trap-only flush
        .csr_wdata(ex_csr_wdata),
        .ex_result(ex_result),
        .rs1_fwd_o(ex_rs1_fwd), .rs2_fwd_o(ex_rs2_fwd),
            .fetch_misaligned(ex_fetch_mis), .rd_out(ex_rd_out),
        .reg_write_out(ex_reg_write_out), .mem_read_out(ex_mem_read_out),
        .mem_write_out(ex_mem_write_out),
        .ex_redirect(ex_redirect), .ex_redirect_target(ex_redirect_target),
        .load_misaligned(ex_load_mis),
        .store_misaligned(ex_store_mis), .dsu_illegal_instr(ex_dsu_illegal),
        .dsu_busy(ex_dsu_busy), .dsu_overflow(ex_dsu_overflow),
            .dsu_ovf_pending(ex_dsu_ovf_pending),
        .dbg_acc_fx(dbg_acc_0_o), .dbg_acc_fy(dbg_acc_1_o),
            .dbg_acc_mag(dbg_acc_2_o)
    );
    ex_mem u_exmem (
        .gclk(gclk), .core_rst_n(core_rst_n), .stall_i(pc_exmem_s),
            .flush_i(pc_exmem_f),
        .ex_result_i(ex_result), .store_data_i(ex_rs2_fwd),
            .funct3_i(xe_funct3_fld),
        .rd_i(ex_rd_out), .pc_i(xe_pc), .mem_read_i(ex_mem_read_out),
            .mem_write_i(ex_mem_write_out), .reg_write_i(ex_reg_write_out),
            .valid_i(xe_valid),
        .ex_result_o(em_result), .store_data_o(em_store),
            .funct3_o(em_funct3_fld), .rd_o(em_rd),
        .pc_o(em_pc), .mem_read_o(em_mem_read), .mem_write_o(em_mem_write),
            .reg_write_o(em_reg_write),
            .valid_o(em_valid)
    );

    // =========================================================================
    // MEM + WB
    // =========================================================================
    mem_stage u_mem (
        .gclk(gclk), .core_rst_n(core_rst_n),
        .ex_result_i(em_result), .rs2_data_i(em_store),
            .funct3_i(em_funct3_fld), .rd_i(em_rd),
        .pc_i(em_pc), .mem_read_i(em_mem_read), .mem_write_i(em_mem_write),
            .reg_write_i(em_reg_write),
            .valid_i(em_valid),
        .d_haddr_o(d_haddr_o), .d_htrans_o(d_htrans_o), .d_hsize_o(d_hsize_o),
        .d_hburst_o(d_hburst_o), .d_hprot_o(d_hprot_o), .d_hwrite_o(d_hwrite_o),
            .d_hwdata_o(d_hwdata_o),
        .d_hrdata_i(d_hrdata_i), .d_hready_i(d_hready_i), .d_hresp_i(d_hresp_i),
        .wb_data_o(mem_wb_data), .reg_write_o(mem_reg_write), .rd_o(mem_rd),
            .retire_o(mem_retire),
        .mem_stall_o(mem_stall),
        .mem_exception_valid_o(mem_exc_v), .mem_exception_pc_o(mem_exc_pc),
        .mem_exception_cause_o(mem_exc_cause),
            .mem_exception_mtval_o(mem_exc_tval)
    );
    mem_wb_reg u_memwb (
        .gclk(gclk), .core_rst_n(core_rst_n), .flush_i(pc_mwb_f),
        .wb_data_i(mem_wb_data), .rd_i(mem_rd), .reg_write_i(mem_reg_write),
            .retire_i(mem_retire),
        .wb_data_o(mw_data), .rd_o(mw_rd), .reg_write_o(mw_reg_write),
            .retire_o(mw_retire)
    );
    wb_stage u_wb (
        .wb_data_i(mw_data), .rd_i(mw_rd), .reg_write_i(mw_reg_write),
        .rf_we_o(rf_we), .rf_rd_o(rf_rd), .rf_wdata_o(rf_wdata)
    );

    // =========================================================================
    // CONTROL / CSR / TRAP / CLIC
    // =========================================================================
    // ERRATA P-6, P-7 (2026-10-04): an instruction can sit in EX for many
    // cycles
    // - held behind a load or store (H2) or parked behind a WFI (H5) - and its
    // side effects must happen once. The CSR write and the DSU operation used
    // to run on every one of those cycles (a MAC accumulated once per held
    // cycle). ex_parked withholds the DSU's enable until the instruction can
    // move; ex_commit is the one cycle a CSR write is allowed, and also
    // excludes the cycle the instruction is squashed by a trap. dsu_busy is not
    // in either: it is the DSU's own interlock and the DSU already honours it.
    assign ex_parked = mem_stall | tr_wfi_hold;
    // ERRATUM DSU-14 (ruling D-32, 2026-11-04): an accumulate folds into its
    // accumulator, and its overflow into the sticky flag, one cycle after the
    // MAC leaves EX. A CSR access to dsu_ovf in that cycle read the old flag
    // (and its read-to-clear raced the set). It is now held one cycle in EX,
    // through the DSU hold path (PC, IF/ID, ID/EX held, a bubble into EX/MEM),
    // and does not commit.
    wire ovf_rd_hold = xe_valid &xe_csr_en &(ex_csr_addr_w == 12'hBC0)
        &ex_dsu_ovf_pending;
    assign ex_commit = ~ex_parked & ~tr_sq_ide & ~ovf_rd_hold;

    csr_file u_csr (
        .gclk(gclk), .core_rst_n(core_rst_n),
        .csr_en_i(xe_csr_en), .commit_i(ex_commit),
            .csr_addr_i(ex_csr_addr_w), .csr_wdata_i(ex_csr_wdata),
        .csr_op_i(xe_csr_op), .csr_rdata_o(csr_rdata),
            .illegal_csr_o(csr_illegal),
        .instret_i(mw_retire),  // true architectural retire
        .ret_mem_i(mem_retire),  // C-17: counted on a read of minstret
        .dsu_overflow_i(ex_dsu_overflow), .csr_clear_overflow_o(csr_clear_ovf),
        .trap_enter_i(tr_enter), .mret_i(tr_mret), .is_interrupt_i(tr_is_int),
        .clic_level_i(tr_level), .trap_pc_i(tr_pc), .trap_cause_i(tr_cause),
            .trap_tval_i(tr_tval),
        .mtip_i(mtip),
        .mstatus_mie_o(csr_mstatus_mie), .mtvec_o(csr_mtvec),
        .mepc_o(csr_mepc), .mintthresh_o(csr_mintthresh),
            .mintstatus_mil_o(csr_mil),
        .mti_pending_o(csr_mti_pending),
        .mgarudactl_o(csr_ctl)  // CORE-4
    );
    clic_ctrl #(.ID_W(5)) u_clic (
        .clic_irq_valid_i(clic_irq_valid_i), .clic_irq_id_i(clic_irq_id_i),
        .clic_irq_level_i(clic_irq_level_i),
        .mstatus_mie_i(csr_mstatus_mie), .mintthresh_i(csr_mintthresh),
            .mintstatus_mil_i(csr_mil),
        .preempt_dis_i(csr_ctl[2]),  // CORE-4: PREEMPT_DIS
        .mtvec_i(csr_mtvec),
        .take_cond_o(clic_take_cond), .wake_cond_o(clic_wake_cond),
            .irq_id_o(clic_id),
        .irq_lvl_o(clic_lvl), .vector_target_o(clic_vec_target)
    );
    assign dsu_ovf_o = ex_dsu_overflow;
    trap_ctrl #(.ID_W(5)) u_trap (
        .gclk(gclk), .core_rst_n(core_rst_n),
        .idex_pc_i(xe_pc), .idex_instr_i(xe_instr), .idex_fault_i(xe_fault),
        .idex_illegal_dec_i(xe_illegal), .idex_is_system_i(xe_is_system),
        .idex_valid_i(xe_valid),  // ERRATUM T-4
        .ex_dsu_illegal_i(ex_dsu_illegal), .ex_csr_illegal_i(csr_illegal),
        .ex_load_misalign_i(ex_load_mis), .ex_store_misalign_i(ex_store_mis),
            .ex_addr_i(ex_result),
        .ex_fetch_misalign_i(ex_fetch_mis),
            .ex_fetch_target_i(ex_redirect_target),
        .mem_stall_i(mem_stall),  // ERRATUM T-9
        .mem_exc_valid_i(mem_exc_v), .mem_exc_cause_i(mem_exc_cause),
        .mem_exc_pc_i(mem_exc_pc), .mem_exc_tval_i(mem_exc_tval),
        .clic_take_cond_i(clic_take_cond), .clic_wake_cond_i(clic_wake_cond),
        .clic_irq_id_i(clic_id), .clic_irq_lvl_i(clic_lvl),
            .clic_vector_target_i(clic_vec_target),
            .mti_pending_i(csr_mti_pending),
        .mtvec_i(csr_mtvec), .mepc_i(csr_mepc), .mstatus_mie_i(csr_mstatus_mie),
        .trap_enter_o(tr_enter), .is_interrupt_o(tr_is_int),
            .clic_level_o(tr_level), .mret_o(tr_mret),
        .trap_pc_o(tr_pc), .trap_cause_o(tr_cause), .trap_tval_o(tr_tval),
        .trap_redirect_valid_o(tr_redir_v), .trap_redirect_target_o(tr_redir_t),
        .trap_squash_ex_mem_o(tr_sq_exm),
        .trap_squash_mem_wb_o(tr_sq_mwb), .wfi_hold_o(tr_wfi_hold)
    );
    // ERRATUM C-15 (2026-10-04, found by t_hold_flush_matrix bit 6 with
    // +DWAIT): FENCE.I redirects from ID, so its refetch went out on the I-port
    // while an older store was still in EX or waiting on the D-port. With a
    // wait state on the store the fetch won the race and the core executed the
    // word the store was replacing - the one thing Zifencei exists to prevent.
    // FENCE.I now waits in ID, exactly as a load-use does (PC and IF/ID held, a
    // bubble into EX, its redirect withheld by pipe_ctrl), until no older store
    // is in EX or still on the bus.
    wire id_is_fencei = id_valid &(id_instr[6:0] == 7'b0001111)
        &(id_instr[14:12] == 3'b001);
    wire fencei_wait  = id_is_fencei & ((xe_valid & xe_mem_write) |
                                        (em_valid & em_mem_write & mem_stall));

    // IF/ID flush = any redirect: pipe_ctrl's if_redirect_o
    assign pc_ifid_f = pc_if_redir;
    // a trap squashes ID/EX (trap_ctrl's trap_squash_id_ex_o, its alias, went
    // in F4)
    assign tr_sq_ide = tr_enter;
    assign pc_ifid_s = pc_if_stall;

    // the stall sources pipe_ctrl sees (named: HAL EXPIPC)
    wire pipe_busy = ex_dsu_busy | ovf_rd_hold;
    wire pipe_hold = id_load_use | fencei_wait;

    pipe_ctrl u_pipe (
        .mem_stall_i(mem_stall), .dsu_busy_i(pipe_busy),
            .load_use_stall_i(pipe_hold),
            .wfi_hold_i(tr_wfi_hold),
        .id_redirect_valid_i(id_redir_v), .id_redirect_target_i(id_redir_t),
        .ex_redirect_i(ex_redirect), .ex_redirect_target_i(ex_redirect_target),
        .bus_idle_i(bus_idle), .wfi_settled_i(wfi_q2), .quiescent_o(quiescent),
        .trap_redirect_valid_i(tr_redir_v), .trap_redirect_target_i(tr_redir_t),
        .trap_squash_id_ex_i(tr_sq_ide), .trap_squash_ex_mem_i(tr_sq_exm),
            .trap_squash_mem_wb_i(tr_sq_mwb),
        .if_stall_o(pc_if_stall), .if_redirect_o(pc_if_redir),
            .if_redirect_pc_o(pc_if_redir_pc),
        .id_ex_stall_o(pc_idex_s), .id_ex_flush_o(pc_idex_f),
        .ex_mem_stall_o(pc_exmem_s), .ex_mem_flush_o(pc_exmem_f),
            .mem_wb_flush_o(pc_mwb_f)
    );

`ifdef GARUDA_RVFI
    // =========================================================================
    // RVFI (plan 5.1): records follow ex_mem / mem_wb hold and flush exactly
    // =========================================================================
    garuda_rvfi u_rvfi (
        .gclk(gclk), .hclk(hclk), .core_rst_n(core_rst_n),
        .xe_valid_i(xe_valid), .xe_pc_i(xe_pc), .xe_instr_i(xe_instr),
            .xe_imm_i(xe_imm),
        .xe_rs1_i(xe_rs1i), .xe_rs2_i(xe_rs2i), .xe_funct3_i(xe_funct3_fld),
        .xe_branch_i(xe_branch), .xe_jal_i(xe_jal),
            .xe_pred_taken_i(xe_predicted_taken),
        .xe_mem_read_i(xe_mem_read), .xe_mem_write_i(xe_mem_write),
        .ex_rs1_val_i(ex_rs1_fwd), .ex_rs2_val_i(ex_rs2_fwd),
            .ex_result_i(ex_result),
        .ex_redirect_i(ex_redirect), .ex_redirect_target_i(ex_redirect_target),
        .exmem_stall_i(pc_exmem_s), .exmem_flush_i(pc_exmem_f),
            .memwb_flush_i(pc_mwb_f),
        .em_valid_i(em_valid),
        .mw_retire_i(mw_retire), .mw_reg_write_i(mw_reg_write), .mw_rd_i(mw_rd),
            .mw_data_i(mw_data),
        .d_hrdata_i(d_hrdata_i), .mem_exc_v_i(mem_exc_v),
        .tr_enter_i(tr_enter), .tr_is_int_i(tr_is_int), .tr_mret_i(tr_mret),
            .tr_redir_t_i(tr_redir_t),
        .rvfi_valid(rvfi_valid), .rvfi_order(rvfi_order), .rvfi_insn(rvfi_insn),
            .rvfi_trap(rvfi_trap),
        .rvfi_halt(rvfi_halt), .rvfi_intr(rvfi_intr), .rvfi_mode(rvfi_mode),
            .rvfi_ixl(rvfi_ixl),
        .rvfi_rs1_addr(rvfi_rs1_addr), .rvfi_rs2_addr(rvfi_rs2_addr),
        .rvfi_rs1_rdata(rvfi_rs1_rdata), .rvfi_rs2_rdata(rvfi_rs2_rdata),
        .rvfi_rd_addr(rvfi_rd_addr), .rvfi_rd_wdata(rvfi_rd_wdata),
        .rvfi_pc_rdata(rvfi_pc_rdata), .rvfi_pc_wdata(rvfi_pc_wdata),
        .rvfi_mem_addr(rvfi_mem_addr), .rvfi_mem_rmask(rvfi_mem_rmask),
            .rvfi_mem_wmask(rvfi_mem_wmask),
        .rvfi_mem_rdata(rvfi_mem_rdata), .rvfi_mem_wdata(rvfi_mem_wdata)
    );
`endif
endmodule
