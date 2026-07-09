`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block I: Processor Core
// trap_ctrl.v - Exception priority, trap entry/exit, interrupt entry (Sec.14)
// Document: AERO-GARUDA-DS-001 Rev 1.1
//
// One unified entry path for synchronous exceptions (Sec.14.1/14.2), CLIC
// interrupts (Sec.14.3) and WFI-wake (Sec.14.5), driving the csr_file trap
// port, pipe_ctrl redirect/squash, and ex_stage DSU trap-flush.
//
// Trap points (in-order pipeline => age is fixed):
//   MEM-point  : load/store access fault (5/7), detected in mem_stage. OLDEST.
//   EX-point   : causes 1,2,3,4,6,11 for the instr in EX (id_ex + ex_stage).
// MEM-point strictly outranks EX-point (older completes / offending+younger
// squashed). Within EX-point, Sec.14.1 order 1 > 2 > 3 > 4 > 6 > 11.
// Exceptions strictly outrank interrupts in the same cycle.
//
// mtval (Sec.14.2): 1->fetch PC, 2->instr word, 3->ebreak PC, 4/6->address,
// 5/7->address (from mem_stage), 11/int->0.
//
// Entry (Sec.14.4): trap_enter pulse -> csr_file latches mepc/mcause/mtval and
// pushes mstatus (MPIE<=MIE, MIE<=0). Interrupt also pushes mintstatus level.
// MRET: mret pulse -> csr pops; redirect to mepc. Entry+exit each 2 bubbles.
//
// WFI (Sec.14.5): drain-stall hold; wake on clic wake_cond (MIE-independent).
// Taking the interrupt on wake reuses this same entry path.
// =============================================================================
module trap_ctrl #(
    parameter ID_W = 12
)(
    input  wire        clk_i,
    input  wire        rst_n_i,

    // ---- EX-point instruction (id_ex + ex_stage) ----
    input  wire [31:0] idex_pc_i,
    input  wire [31:0] idex_instr_i,
    input  wire        idex_fault_i,          // I-access fault bit (cause 1)
    input  wire        idex_illegal_dec_i,    // decode illegal (cause 2)
    input  wire        idex_is_system_i,
    input  wire        ex_dsu_illegal_i,      // cause 2
    input  wire        ex_csr_illegal_i,      // cause 2 (csr_file.illegal_csr)
    input  wire        ex_load_misalign_i,    // cause 4
    input  wire        ex_store_misalign_i,   // cause 6
    input  wire [31:0] ex_addr_i,             // mtval for 4/6 (= ex_result)

    // ---- MEM-point (mem_stage) ----
    input  wire        mem_exc_valid_i,
    input  wire [3:0]  mem_exc_cause_i,       // 5 or 7
    input  wire [31:0] mem_exc_pc_i,
    input  wire [31:0] mem_exc_tval_i,

    // ---- CLIC (clic_ctrl) ----
    input  wire        clic_take_cond_i,
    input  wire        clic_wake_cond_i,
    input  wire [ID_W-1:0] clic_irq_id_i,
    input  wire [7:0]  clic_irq_lvl_i,
    input  wire [31:0] clic_vector_target_i,
    output wire        clic_take_o,           // -> clic_ctrl.take_i (ack pulse)

    // ---- csr_file reads ----
    input  wire [31:0] mtvec_i,
    input  wire [31:0] mepc_i,

    // ---- csr_file trap writes ----
    output wire        trap_enter_o,
    output wire        is_interrupt_o,
    output wire [7:0]  clic_level_o,
    output wire        mret_o,
    output wire [31:0] trap_pc_o,
    output wire [31:0] trap_cause_o,
    output wire [31:0] trap_tval_o,

    // ---- pipe_ctrl ----
    output wire        trap_redirect_valid_o,
    output wire [31:0] trap_redirect_target_o,
    output wire        trap_squash_id_ex_o,
    output wire        trap_squash_ex_mem_o,
    output wire        trap_squash_mem_wb_o,
    output wire        wfi_hold_o,

    // ---- ex_stage (DSU trap-only flush) ----
    output wire        ex_squash_o
);
    // SYSTEM instruction discrimination
    wire is_ecall  = idex_is_system_i & (idex_instr_i==32'h00000073);
    wire is_ebreak = idex_is_system_i & (idex_instr_i==32'h00100073);
    wire is_mret   = idex_is_system_i & (idex_instr_i==32'h30200073);
    wire is_wfi    = idex_is_system_i & (idex_instr_i==32'h10500073);

    // EX-point exception detect (Sec.14.1 priority 1>2>3>4>6>11)
    wire e1  = idex_fault_i;
    wire e2  = idex_illegal_dec_i | ex_dsu_illegal_i | ex_csr_illegal_i;
    wire e3  = is_ebreak;
    wire e4  = ex_load_misalign_i;
    wire e6  = ex_store_misalign_i;
    wire e11 = is_ecall;
    wire ex_exc = e1|e2|e3|e4|e6|e11;
    wire [3:0]  ex_cause = e1?4'd1 : e2?4'd2 : e3?4'd3 : e4?4'd4 : e6?4'd6 : 4'd11;
    wire [31:0] ex_tval  = e1?idex_pc_i : e2?idex_instr_i : e3?idex_pc_i :
                           (e4|e6)?ex_addr_i : 32'd0;

    // WFI drain-stall hold
    reg wfi_active;
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i)                              wfi_active <= 1'b0;
        else if (is_wfi & ~wfi_active)             wfi_active <= 1'b1;
        else if (wfi_active & clic_wake_cond_i)    wfi_active <= 1'b0;
    end
    assign wfi_hold_o = wfi_active & ~clic_wake_cond_i;

    // Arbitration: MEM exc > EX exc > interrupt. (MRET is exit, handled separately.)
    wire exception    = mem_exc_valid_i | ex_exc;
    wire take_int      = clic_take_cond_i & ~exception;  // exceptions win
    wire trap_now     = (exception | take_int) & ~is_mret;

    assign clic_take_o     = take_int;
    assign is_interrupt_o  = take_int;
    assign clic_level_o    = clic_irq_lvl_i;

    assign trap_enter_o    = trap_now;
    assign mret_o          = is_mret;

    // mepc / mcause / mtval selection
    assign trap_pc_o    = mem_exc_valid_i ? mem_exc_pc_i :
                          ex_exc          ? idex_pc_i     :
                                            idex_pc_i;     // interrupt: resume @ EX instr
    assign trap_cause_o = take_int        ? {1'b1, {(31-ID_W){1'b0}}, clic_irq_id_i} :
                          mem_exc_valid_i ? {28'd0, mem_exc_cause_i} :
                                            {28'd0, ex_cause};
    assign trap_tval_o  = take_int        ? 32'd0 :
                          mem_exc_valid_i ? mem_exc_tval_i : ex_tval;

    wire [31:0] mtvec_base = {mtvec_i[31:6], 6'b0};

    // Redirect: trap -> vector/base ; MRET -> mepc
    assign trap_redirect_valid_o  = trap_now | is_mret;
    assign trap_redirect_target_o = is_mret ? mepc_i :
                                    take_int ? clic_vector_target_i : mtvec_base;

    // Squash of the offending instr's own downstream reg (+younger via redirect flush)
    assign trap_squash_mem_wb_o = mem_exc_valid_i;                 // kill MEM fault WB
    assign trap_squash_ex_mem_o = (ex_exc & ~mem_exc_valid_i) | take_int; // kill EX instr
    assign trap_squash_id_ex_o  = trap_now;                        // younger
    assign ex_squash_o          = trap_now;                        // DSU trap-only flush
endmodule
`default_nettype wire
