`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - core : functional coverage the pipeline groups of garuda_cov.sv
// do not take: CSR accesses, CLIC interrupt entry, WFI sleep, register write-back
// garuda_core_cov_ext.sv
//
// From GARUDA-CORE-SPEC (section 6 CSRs, 7.15 to 7.33 interrupts, WFI and the
// clock gate, 7.4 the register file). Bound to garuda_core_top next to
// garuda_cov, so it samples in every core, sanity and chip run.
// Covers the decisions of csr_file, clic_ctrl, core_clk_gate, regfile and wb_stage.
// Not for synthesis, not under Icarus or Verilator.
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
`ifndef VERILATOR
module garuda_core_cov_ext (
    input wire        clk_i, rst_n_i,
    // CSR
    input wire        csr_en, csr_commit, csr_illegal,
    input wire [11:0] csr_addr,
    input wire [1:0]  csr_op,
    input wire [31:0] csr_wdata,
    // interrupts and traps
    input wire        tr_enter, tr_is_int, tr_mret, clic_take_cond, clic_wake_cond,
    input wire [4:0]  clic_id,
    input wire [7:0]  clic_lvl, mil, mintthresh,
    input wire        mie, mti_pending,
    // sleep
    input wire        quiescent,
    // write-back and the register file
    input wire        rf_we,
    input wire [4:0]  rf_rd, rs1_idx, rs2_idx
);
    // ---- CSR ------------------------------------------------------------------
    typedef enum {MSTATUS, MISA, MIE, MTVEC, MSCRATCH, MEPC, MCAUSE, MTVAL, MIP, MNXTI, MINTSTATUS,
                  MINTTHRESH, MINTSTATUS_STD, COUNTERS_M, COUNTERS_U, IDS, DSU_OVF, UNIMPL} csr_e;
    csr_e which;
    always @(*) case (csr_addr)
        12'h300: which = MSTATUS; 12'h301: which = MISA; 12'h304: which = MIE; 12'h305: which = MTVEC;
        12'h340: which = MSCRATCH; 12'h341: which = MEPC; 12'h342: which = MCAUSE; 12'h343: which = MTVAL;
        12'h344: which = MIP; 12'h345: which = MNXTI; 12'h346: which = MINTSTATUS; 12'h347: which = MINTTHRESH;
        12'hFB1: which = MINTSTATUS_STD; 12'hB00, 12'hB80, 12'hB02, 12'hB82: which = COUNTERS_M;
        12'hC00, 12'hC80, 12'hC02, 12'hC82: which = COUNTERS_U; 12'hF11, 12'hF12, 12'hF13, 12'hF14: which = IDS;
        12'hBC0: which = DSU_OVF; default: which = UNIMPL; endcase
    covergroup cg_csr @(posedge clk_i iff (rst_n_i && csr_en && csr_commit && csr_op != 2'b00));
        option.per_instance = 1;
        cp_csr: coverpoint which;
        cp_op: coverpoint csr_op { bins rw = {2'b01}; bins rs = {2'b10}; bins rc = {2'b11}; }
        cp_zero_src: coverpoint (csr_wdata == 32'd0) { bins nonzero = {0}; bins zero_is_read_only = {1}; }
        cp_illegal: coverpoint csr_illegal;
        // every CSR read and written each way; the read-only ones refused when written
        x_csr_op: cross cp_csr, cp_op;
        x_csr_illegal: cross cp_csr, cp_illegal;
    endgroup

    // ---- interrupts -------------------------------------------------------------
    covergroup cg_irq @(posedge clk_i iff (rst_n_i && tr_enter && tr_is_int));
        option.per_instance = 1;
        cp_id: coverpoint clic_id { bins dma_done[] = {[1:6]}; bins dma_err = {[8:13]}; bins spis = {14};
                                    bins periph = {[15:22]}; bins timer_mti = {0}; }
        cp_level: coverpoint clic_lvl { bins lowest = {[1:63]}; bins low = {[64:127]}; bins high = {[128:254]}; bins top = {255}; }
        // [N-14.3] preemption: taken while another interrupt is already active
        cp_nesting: coverpoint (mil != 8'd0) { bins first = {0}; bins nested = {1}; }
        cp_threshold: coverpoint (mintthresh != 8'd0) { bins off = {0}; bins set = {1}; }
        x_level_nesting: cross cp_level, cp_nesting;
    endgroup
    covergroup cg_irq_state @(posedge clk_i iff rst_n_i);
        option.per_instance = 1;
        // an interrupt that is pending but not taken: masked by MIE, below threshold or level
        cp_pending_masked: coverpoint {clic_wake_cond, clic_take_cond, mie} {
            bins taken = {3'b111}; bins masked_by_mie = {3'b100}; bins below_level = {3'b101}; }
        cp_mret: coverpoint tr_mret;
        cp_mtip_pending: coverpoint mti_pending;
    endgroup

    // ---- WFI and the clock gate ---------------------------------------------------
    reg q_d = 1'b0; integer sleep_len = 0;
    always @(posedge clk_i) begin q_d <= quiescent; sleep_len <= quiescent ? ((sleep_len < 255) ? sleep_len + 1 : sleep_len) : 0; end
    covergroup cg_sleep @(posedge clk_i iff (rst_n_i && q_d && !quiescent));
        option.per_instance = 1;
        // how long the core slept before it woke, and what woke it
        cp_len: coverpoint sleep_len { bins one = {1}; bins short_ = {[2:15]}; bins long_ = {[16:255]}; }
        cp_woken_by: coverpoint {clic_wake_cond, mti_pending} { bins clic = {2'b10}; bins timer = {2'b01}; bins both = {2'b11}; bins other = {2'b00}; }
    endgroup

    // ---- write-back and the register file ---------------------------------------------
    covergroup cg_rf @(posedge clk_i iff (rst_n_i && rf_we));
        option.per_instance = 1;
        cp_rd: coverpoint rf_rd { bins x0_discarded = {0}; bins r[] = {[1:31]}; }
        // [N-7.4] the WB to ID bypass: written in the cycle it is read
        cp_bypass: coverpoint {rf_rd != 5'd0 && rf_rd == rs1_idx, rf_rd != 5'd0 && rf_rd == rs2_idx} {
            bins none = {2'b00}; bins rs1 = {2'b10}; bins rs2 = {2'b01}; bins both = {2'b11}; }
    endgroup
    cg_csr cc = new(); cg_irq ci = new(); cg_irq_state cs = new(); cg_sleep cl = new(); cg_rf cr = new();
endmodule

bind garuda_core_top garuda_core_cov_ext u_cov_ext (
    .clk_i(clk_i), .rst_n_i(rst_n_i),
    .csr_en(ex_csr_en_out), .csr_commit(ex_commit), .csr_illegal(csr_illegal),
    .csr_addr(ex_csr_addr_w), .csr_op(ex_csr_op_out), .csr_wdata(ex_csr_wdata),
    .tr_enter(tr_enter), .tr_is_int(tr_is_int), .tr_mret(tr_mret),
    .clic_take_cond(clic_take_cond), .clic_wake_cond(clic_wake_cond),
    .clic_id(clic_id), .clic_lvl(clic_lvl), .mil(csr_mil), .mintthresh(csr_mintthresh),
    .mie(csr_mstatus_mie), .mti_pending(csr_mti_pending),
    .quiescent(quiescent),
    .rf_we(rf_we), .rf_rd(rf_rd), .rs1_idx(u_id.rs1_idx_w), .rs2_idx(u_id.rs2_idx_w));
`endif
`endif
`endif
