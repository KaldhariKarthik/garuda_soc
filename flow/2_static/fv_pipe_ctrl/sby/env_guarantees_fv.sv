// =============================================================================
// env_guarantees_fv.sv -- the two guarantees pipe_ctrl_fv.sv assumes
//
// pipe_ctrl_fv.sv proves pipe_ctrl's properties with its inputs free except
// for one assumption, A1: no ID/EX trap squash while a D-port transfer holds
// the pipeline (H2). A1 is not taken on trust; it follows from these two
// properties of the modules that drive those inputs, each proved here with
// its own inputs free:
//
//   G1 d_port_ahb_master: err_pulse_o and mem_stall_o are never high together
//      (an ERROR completes a data phase, which is exactly when the stall
//      drops). In the core, mem_exc_valid = err_pulse & (load | store).
//   G2 trap_ctrl: trap_squash_id_ex_o under mem_stall_i only for a MEM-point
//      exception (EX-point traps, interrupts and MRET wait for H2 to clear -
//      ERRATUM T-9).
//
// G2 says a squash under H2 needs mem_exc_valid; G1 says mem_exc_valid never
// comes with H2. Together: A1.
// =============================================================================
module g1_dport (
    input wire        clk_i,
    input wire        rst_n_i,
    input wire        start_i,
    input wire        hwrite_i,
    input wire [31:0] addr_i,
    input wire [2:0]  hsize_i,
    input wire [31:0] hwdata_i,
    input wire        d_hready_i,
    input wire        d_hresp_i
);
    wire [31:0] haddr, hwdata;
    wire [1:0]  htrans;
    wire [2:0]  hsize;
    wire        hwrite, mem_stall, ok_done, err_pulse;

    d_port_ahb_master u_dport (
        .clk_i(clk_i), .rst_n_i(rst_n_i), .start_i(start_i), .hwrite_i(hwrite_i),
        .addr_i(addr_i), .hsize_i(hsize_i), .hwdata_i(hwdata_i),
        .d_haddr_o(haddr), .d_htrans_o(htrans), .d_hsize_o(hsize),
        .d_hwrite_o(hwrite), .d_hwdata_o(hwdata),
        .d_hready_i(d_hready_i), .d_hresp_i(d_hresp_i),
        .mem_stall_o(mem_stall), .ok_done_o(ok_done), .err_pulse_o(err_pulse));

    initial assume (!rst_n_i);
    always @(posedge clk_i) begin
        g1_err_never_under_h2: assert (!(err_pulse && mem_stall));
        g1_err_reachable:      cover  (err_pulse);
        g1_h2_reachable:       cover  (mem_stall);
    end
endmodule

module g2_trap (
    input wire        clk_i,
    input wire        rst_n_i,
    input wire [31:0] idex_pc_i,
    input wire [31:0] idex_instr_i,
    input wire        idex_fault_i,
    input wire        idex_illegal_dec_i,
    input wire        idex_is_system_i,
    input wire        idex_valid_i,
    input wire        ex_dsu_illegal_i,
    input wire        ex_csr_illegal_i,
    input wire        ex_load_misalign_i,
    input wire        ex_store_misalign_i,
    input wire [31:0] ex_addr_i,
    input wire        ex_fetch_misalign_i,
    input wire [31:0] ex_fetch_target_i,
    input wire        mem_stall_i,
    input wire        mem_exc_valid_i,
    input wire [3:0]  mem_exc_cause_i,
    input wire [31:0] mem_exc_pc_i,
    input wire [31:0] mem_exc_tval_i,
    input wire        clic_take_cond_i,
    input wire        clic_wake_cond_i,
    input wire [4:0]  clic_irq_id_i,
    input wire [7:0]  clic_irq_lvl_i,
    input wire [31:0] clic_vector_target_i,
    input wire        mti_pending_i,
    input wire [31:0] mtvec_i,
    input wire [31:0] mepc_i,
    input wire        mstatus_mie_i
);
    wire        clic_take, trap_enter, is_int, mret, redir_v, sq_id_ex, sq_ex_mem, sq_mem_wb;
    wire        wfi_hold, ex_squash;
    wire [7:0]  clic_level;
    wire [31:0] trap_pc, trap_cause, trap_tval, redir_t;

    trap_ctrl u_trap (
        .clk_i(clk_i), .rst_n_i(rst_n_i),
        .idex_pc_i(idex_pc_i), .idex_instr_i(idex_instr_i), .idex_fault_i(idex_fault_i),
        .idex_illegal_dec_i(idex_illegal_dec_i), .idex_is_system_i(idex_is_system_i),
        .idex_valid_i(idex_valid_i), .ex_dsu_illegal_i(ex_dsu_illegal_i),
        .ex_csr_illegal_i(ex_csr_illegal_i), .ex_load_misalign_i(ex_load_misalign_i),
        .ex_store_misalign_i(ex_store_misalign_i), .ex_addr_i(ex_addr_i),
        .ex_fetch_misalign_i(ex_fetch_misalign_i), .ex_fetch_target_i(ex_fetch_target_i),
        .mem_stall_i(mem_stall_i), .mem_exc_valid_i(mem_exc_valid_i),
        .mem_exc_cause_i(mem_exc_cause_i), .mem_exc_pc_i(mem_exc_pc_i),
        .mem_exc_tval_i(mem_exc_tval_i),
        .clic_take_cond_i(clic_take_cond_i), .clic_wake_cond_i(clic_wake_cond_i),
        .clic_irq_id_i(clic_irq_id_i), .clic_irq_lvl_i(clic_irq_lvl_i),
        .clic_vector_target_i(clic_vector_target_i), .clic_take_o(clic_take),
        .mti_pending_i(mti_pending_i), .mtvec_i(mtvec_i), .mepc_i(mepc_i),
        .mstatus_mie_i(mstatus_mie_i),
        .trap_enter_o(trap_enter), .is_interrupt_o(is_int), .clic_level_o(clic_level),
        .mret_o(mret), .trap_pc_o(trap_pc), .trap_cause_o(trap_cause), .trap_tval_o(trap_tval),
        .trap_redirect_valid_o(redir_v), .trap_redirect_target_o(redir_t),
        .trap_squash_id_ex_o(sq_id_ex), .trap_squash_ex_mem_o(sq_ex_mem),
        .trap_squash_mem_wb_o(sq_mem_wb), .wfi_hold_o(wfi_hold), .ex_squash_o(ex_squash));

    initial assume (!rst_n_i);
    always @(posedge clk_i) begin
        g2_squash_under_h2_is_mem_exc: assert (!(sq_id_ex && mem_stall_i) || mem_exc_valid_i);
        g2_squash_under_h2_reachable:  cover  (sq_id_ex && mem_stall_i);
    end
endmodule
