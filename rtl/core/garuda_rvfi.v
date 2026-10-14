`timescale 1ns/1ps
`ifdef GARUDA_RVFI
`default_nettype none
// =============================================================================
// garuda_rvfi.v -- RISC-V Formal Interface (RVFI) for the GARUDA core
// (Karthik's plan task 5.1; Track A). Instantiated in garuda_core_top only
// under `ifdef GARUDA_RVFI; never part of the shipped netlist.
//
// One record per retired instruction (NRET = 1), in program order, plus one
// record with rvfi_trap = 1 for every instruction that raises an exception
// (EX point or MEM point) instead of retiring. The first instruction of a
// trap handler carries rvfi_intr = 1. Memory fields use the aligned convention
// (RISCV_FORMAL_ALIGNED_MEM): mem_addr is word-aligned, masks and data are in
// byte lanes.
//
// How it stays in step with the pipeline: the EX-stage view of an instruction
// (instruction, PC, the operands it really used after forwarding, next PC,
// memory address / mask / store data) is captured with the SAME hold and flush
// as ex_mem; it moves on with the same flush as mem_wb; a record is emitted at
// the real retirement (mw_retire) with rd / rd_wdata from WB and the load data
// taken from the bus when the data phase completed. Nothing here feeds back
// into the core.
// =============================================================================
module garuda_rvfi (
    input  wire        clk_i,          // the core's (gated) clock: the record pipeline
    input  wire        clk_free_i,     // ungated clock: the emission stage
    input  wire        rst_n_i,
    // ---- EX stage (ID/EX outputs and EX results) --------------------------------
    input  wire        xe_valid_i,
    input  wire [31:0] xe_pc_i,
    input  wire [31:0] xe_instr_i,
    input  wire [31:0] xe_imm_i,
    input  wire [4:0]  xe_rs1_i, xe_rs2_i,
    input  wire [2:0]  xe_funct3_i,
    input  wire        xe_branch_i, xe_jal_i, xe_pred_taken_i,
    input  wire        xe_mem_read_i, xe_mem_write_i,
    input  wire [31:0] ex_rs1_val_i, ex_rs2_val_i,   // post-forward operands
    input  wire [31:0] ex_result_i,                 // effective address for loads / stores
    input  wire        ex_redirect_i,
    input  wire [31:0] ex_redirect_target_i,
    // ---- pipeline control -----------------------------------------------------------
    input  wire        exmem_stall_i, exmem_flush_i, memwb_flush_i,
    input  wire        em_valid_i,
    // ---- MEM / WB ------------------------------------------------------------------
    input  wire        mw_retire_i,
    input  wire        mw_reg_write_i,
    input  wire [4:0]  mw_rd_i,
    input  wire [31:0] mw_data_i,
    input  wire [31:0] d_hrdata_i,
    input  wire        mem_exc_v_i,
    // ---- traps -------------------------------------------------------------------------
    input  wire        tr_enter_i,
    input  wire        tr_is_int_i,
    input  wire        tr_mret_i,
    input  wire [31:0] tr_redir_t_i,
    // ---- RVFI ----------------------------------------------------------------------------
    output reg         rvfi_valid,
    output reg  [63:0] rvfi_order,
    output reg  [31:0] rvfi_insn,
    output reg         rvfi_trap,
    output wire        rvfi_halt,
    output reg         rvfi_intr,
    output wire [1:0]  rvfi_mode,
    output wire [1:0]  rvfi_ixl,
    output reg  [4:0]  rvfi_rs1_addr,
    output reg  [4:0]  rvfi_rs2_addr,
    output reg  [31:0] rvfi_rs1_rdata,
    output reg  [31:0] rvfi_rs2_rdata,
    output reg  [4:0]  rvfi_rd_addr,
    output reg  [31:0] rvfi_rd_wdata,
    output reg  [31:0] rvfi_pc_rdata,
    output reg  [31:0] rvfi_pc_wdata,
    output reg  [31:0] rvfi_mem_addr,
    output reg  [3:0]  rvfi_mem_rmask,
    output reg  [3:0]  rvfi_mem_wmask,
    output reg  [31:0] rvfi_mem_rdata,
    output reg  [31:0] rvfi_mem_wdata
);
    assign rvfi_halt = 1'b0;
    assign rvfi_mode = 2'd3;          // M-mode only
    assign rvfi_ixl  = 2'd1;          // XLEN 32

    // ---- the EX-stage view of the instruction in EX -------------------------------
    wire [1:0]  lane   = ex_result_i[1:0];
    wire [3:0]  bytes  = (xe_funct3_i[1:0] == 2'd0) ? 4'b0001 :
                         (xe_funct3_i[1:0] == 2'd1) ? 4'b0011 : 4'b1111;
    wire [3:0]  mask   = bytes << lane;
    wire [31:0] npc    = tr_mret_i                         ? tr_redir_t_i :
                         ex_redirect_i                     ? ex_redirect_target_i :
                         (xe_jal_i | (xe_branch_i & xe_pred_taken_i)) ? (xe_pc_i + xe_imm_i) :
                                                              (xe_pc_i + 32'd4);
    // an EX-point exception: the instruction in EX traps instead of moving on
    wire ex_trap = tr_enter_i & ~tr_is_int_i & ~mem_exc_v_i;

    // ---- position "EX/MEM" (mirrors ex_mem: same stall; validity is em_valid) -------
    reg [31:0] e_insn, e_pc, e_npc, e_rs1v, e_rs2v, e_addr, e_wdata;
    reg [4:0]  e_rs1, e_rs2;
    reg [3:0]  e_rmask, e_wmask;
    reg        e_intr;
    reg        e_trap_v;                                 // a trap record sits here
    // ---- position "MEM/WB" --------------------------------------------------------------
    reg [31:0] w_insn, w_pc, w_npc, w_rs1v, w_rs2v, w_addr, w_wdata, w_rdata;
    reg [4:0]  w_rs1, w_rs2;
    reg [3:0]  w_rmask, w_wmask;
    reg        w_intr;
    reg        w_trap_v;
    reg        intr_next;                                 // next captured instruction opens a handler

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            e_trap_v <= 1'b0; w_trap_v <= 1'b0; intr_next <= 1'b0; e_intr <= 1'b0; w_intr <= 1'b0;
            e_insn <= 32'd0; e_pc <= 32'd0; e_npc <= 32'd0; e_rs1v <= 32'd0; e_rs2v <= 32'd0;
            e_addr <= 32'd0; e_wdata <= 32'd0; e_rs1 <= 5'd0; e_rs2 <= 5'd0; e_rmask <= 4'd0; e_wmask <= 4'd0;
            w_insn <= 32'd0; w_pc <= 32'd0; w_npc <= 32'd0; w_rs1v <= 32'd0; w_rs2v <= 32'd0;
            w_addr <= 32'd0; w_wdata <= 32'd0; w_rdata <= 32'd0; w_rs1 <= 5'd0; w_rs2 <= 5'd0;
            w_rmask <= 4'd0; w_wmask <= 4'd0;
        end else begin
            // -- MEM/WB position: a copy of EX/MEM every cycle (mem_wb has no hold);
            //    the load data is the bus data of the completing data phase
            if (memwb_flush_i && !mem_exc_v_i) begin
                w_trap_v <= 1'b0;
            end else begin
                // a MEM-point fault goes to the trap handler, not to pc + 4
                w_insn <= e_insn; w_pc <= e_pc; w_npc <= mem_exc_v_i ? tr_redir_t_i : e_npc;
                w_rs1v <= e_rs1v; w_rs2v <= e_rs2v;
                w_rs1 <= e_rs1; w_rs2 <= e_rs2; w_addr <= e_addr; w_wdata <= e_wdata;
                w_rmask <= e_rmask; w_wmask <= e_wmask; w_intr <= e_intr;
                w_rdata <= d_hrdata_i & {{8{e_rmask[3]}}, {8{e_rmask[2]}}, {8{e_rmask[1]}}, {8{e_rmask[0]}}};
                // an EX-point trap record moves on; a MEM-point fault turns the
                // instruction in MEM into a trap record
                w_trap_v <= e_trap_v | mem_exc_v_i;
            end
            // -- EX/MEM position
            if (ex_trap) begin
                // the faulting instruction becomes a trap record where the real
                // pipeline carries a bubble
                e_trap_v <= 1'b1;
                // the real operands: a checker recomputes the trap decision
                // (e.g. a misaligned address) from them
                e_insn <= xe_instr_i; e_pc <= xe_pc_i; e_npc <= tr_redir_t_i;
                e_rs1 <= xe_rs1_i; e_rs2 <= xe_rs2_i; e_rs1v <= ex_rs1_val_i; e_rs2v <= ex_rs2_val_i;
                e_addr <= 32'd0; e_wdata <= 32'd0; e_rmask <= 4'd0; e_wmask <= 4'd0;
                e_intr <= intr_next;
            end else if (!exmem_stall_i) begin
                e_trap_v <= 1'b0;
                e_insn <= xe_instr_i; e_pc <= xe_pc_i; e_npc <= npc;
                e_rs1 <= xe_rs1_i; e_rs2 <= xe_rs2_i; e_rs1v <= ex_rs1_val_i; e_rs2v <= ex_rs2_val_i;
                e_addr  <= (xe_mem_read_i | xe_mem_write_i) ? {ex_result_i[31:2], 2'b00} : 32'd0;
                e_rmask <= xe_mem_read_i  ? mask : 4'd0;
                e_wmask <= xe_mem_write_i ? mask : 4'd0;
                e_wdata <= xe_mem_write_i ? ((ex_rs2_val_i << {lane, 3'b000}) &
                                             {{8{mask[3]}}, {8{mask[2]}}, {8{mask[1]}}, {8{mask[0]}}}) : 32'd0;
                e_intr  <= intr_next;
            end
            // -- the first instruction captured after a trap entry opens the handler
            if (tr_enter_i)
                intr_next <= 1'b1;
            else if (!exmem_stall_i && !exmem_flush_i && xe_valid_i)
                intr_next <= 1'b0;
            if (ex_trap)
                intr_next <= 1'b1;
        end
    end

    // ---- emission at WB --------------------------------------------------------------------
    // On the UNGATED clock: when WFI gates the core clock right after a
    // retirement, a gated rvfi_valid would stay 1 for the whole sleep and every
    // consumer on the free clock would see the record again. mw_retire is 0
    // while the core sleeps, so this stage falls to 0. (Same edges as the core
    // clock whenever that runs; the formal model passes the clock through.)
    always @(posedge clk_free_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            rvfi_valid <= 1'b0; rvfi_order <= 64'd0; rvfi_trap <= 1'b0; rvfi_intr <= 1'b0;
            rvfi_insn <= 32'd0; rvfi_rs1_addr <= 5'd0; rvfi_rs2_addr <= 5'd0;
            rvfi_rs1_rdata <= 32'd0; rvfi_rs2_rdata <= 32'd0; rvfi_rd_addr <= 5'd0; rvfi_rd_wdata <= 32'd0;
            rvfi_pc_rdata <= 32'd0; rvfi_pc_wdata <= 32'd0; rvfi_mem_addr <= 32'd0;
            rvfi_mem_rmask <= 4'd0; rvfi_mem_wmask <= 4'd0; rvfi_mem_rdata <= 32'd0; rvfi_mem_wdata <= 32'd0;
        end else begin
            rvfi_valid <= mw_retire_i | w_trap_v;
            if (mw_retire_i | w_trap_v) begin
                rvfi_order     <= rvfi_order + 64'd1;
                rvfi_insn      <= w_insn;
                rvfi_trap      <= w_trap_v;
                rvfi_intr      <= w_intr;
                rvfi_pc_rdata  <= w_pc;
                rvfi_pc_wdata  <= w_npc;
                rvfi_rs1_addr  <= w_rs1;  rvfi_rs1_rdata <= (w_rs1 == 5'd0) ? 32'd0 : w_rs1v;
                rvfi_rs2_addr  <= w_rs2;  rvfi_rs2_rdata <= (w_rs2 == 5'd0) ? 32'd0 : w_rs2v;
                rvfi_rd_addr   <= (!w_trap_v && mw_reg_write_i) ? mw_rd_i : 5'd0;
                rvfi_rd_wdata  <= (!w_trap_v && mw_reg_write_i && mw_rd_i != 5'd0) ? mw_data_i : 32'd0;
                rvfi_mem_addr  <= w_trap_v ? 32'd0 : w_addr;
                rvfi_mem_rmask <= w_trap_v ? 4'd0 : w_rmask;
                rvfi_mem_wmask <= w_trap_v ? 4'd0 : w_wmask;
                rvfi_mem_rdata <= w_trap_v ? 32'd0 : w_rdata;
                rvfi_mem_wdata <= w_trap_v ? 32'd0 : w_wdata;
            end
        end
    end
endmodule
`default_nettype wire
`endif
