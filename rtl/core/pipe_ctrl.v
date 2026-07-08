`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block I: Processor Core
// pipe_ctrl.v - Pipeline Stall / Flush Composition + Redirect Mux
//               (CONTROL block, Sec. 11.4 / Sec. 12 / Sec. 14.4)
// Document: AERO-GARUDA-DS-001 Rev 1.1
//
// The "handle": composes all hold sources onto the PC/IF-ID/ID-EX/EX-MEM hold
// lines and generates per-register flushes, and selects the fetch redirect.
//
// Redirect priority (Sec. 12 / 14.4): trap/MRET > EX (JALR / mispredict) > ID
//   (JAL / predicted-taken).  Penalties: ID-only redirect flushes IF (1 bubble);
//   EX and trap redirects flush IF+ID (2 bubbles). The redirecting EX instr
//   (e.g. JALR writing its link) is NOT squashed - only younger slots are.
//
// Hold table (Sec. 11.4), highest-priority first:
//   D-port wait : hold PC, IF/ID, ID/EX, EX/MEM ; bubble into WB.
//   DSU busy    : hold PC, IF/ID, ID/EX          (id_ex retains the DSU op).
//   Load-use    : hold PC, IF/ID ; FLUSH ID/EX   (one bubble).
// Rule: a flush (redirect / load-use / trap-squash) strictly wins over a hold
// on the same register (the held op is being discarded anyway).
//
// Redirects are gated by ~mem_stall: while a D-port transfer is mid-wait the
// pipeline is frozen and no redirect is applied; the redirect source stays
// asserted (its instr is held in place) and fires the cycle the wait clears.
//
// trap_* inputs come from trap_ctrl; tie to 0 for bring-up (no traps) and the
// block reduces to hazard + branch/jump control only.
// =============================================================================
module pipe_ctrl (
    // ---- hazard / wait sources ----
    input  wire        mem_stall_i,          // D-port wait  (mem_stage.mem_stall_o)
    input  wire        dsu_busy_i,           // DSU same-acc hold (ex_stage.dsu_busy)
    input  wire        load_use_stall_i,     // load-use (id_stage.load_use_stall_o)

    // ---- redirect sources ----
    input  wire        id_redirect_valid_i,  // JAL / predicted-taken (id_stage)
    input  wire [31:0] id_redirect_target_i,
    input  wire        ex_redirect_i,        // JALR / mispredict (ex_stage)
    input  wire [31:0] ex_redirect_target_i,
    input  wire        trap_redirect_valid_i,// trap / MRET (trap_ctrl); 0 in bring-up
    input  wire [31:0] trap_redirect_target_i,

    // ---- trap-squash of the faulting instr's own downstream reg (trap_ctrl) ----
    input  wire        trap_squash_id_ex_i,  // 0 in bring-up
    input  wire        trap_squash_ex_mem_i,
    input  wire        trap_squash_mem_wb_i,

    // ---- to fetch front-end (if_stage_top) ----
    output wire        if_stall_o,
    output wire        if_redirect_o,
    output wire [31:0] if_redirect_pc_o,

    // ---- to pipeline registers ----
    output wire        if_id_stall_o,
    output wire        if_id_flush_o,
    output wire        id_ex_stall_o,
    output wire        id_ex_flush_o,
    output wire        ex_mem_stall_o,
    output wire        ex_mem_flush_o,
    output wire        mem_wb_flush_o        // mem_wb has flush only (terminal-side)
);
    // Redirect selection (priority trap > ex > id), gated by ~mem_stall.
    wire redir_raw   = trap_redirect_valid_i | ex_redirect_i | id_redirect_valid_i;
    wire redirect    = redir_raw & ~mem_stall_i;
    wire redir_2b    = (trap_redirect_valid_i | ex_redirect_i) & ~mem_stall_i; // 2-bubble

    assign if_redirect_o    = redirect;
    assign if_redirect_pc_o = trap_redirect_valid_i ? trap_redirect_target_i :
                              ex_redirect_i          ? ex_redirect_target_i    :
                                                       id_redirect_target_i;

    // Holds (raw). Flushes override holds per-register below.
    wire hold_pc_ifid = mem_stall_i | dsu_busy_i | load_use_stall_i;
    wire hold_id_ex   = mem_stall_i | dsu_busy_i;           // load-use flushes id_ex
    wire hold_ex_mem  = mem_stall_i;

    // PC
    assign if_stall_o    = hold_pc_ifid & ~redirect;

    // IF/ID : any redirect flushes the wrongly-fetched slot
    assign if_id_flush_o = redirect;
    assign if_id_stall_o = hold_pc_ifid & ~if_id_flush_o;

    // ID/EX : 2-bubble redirect OR load-use OR trap-squash bubbles it
    assign id_ex_flush_o = redir_2b | load_use_stall_i | trap_squash_id_ex_i;
    assign id_ex_stall_o = hold_id_ex & ~id_ex_flush_o;

    // EX/MEM : holds on D-port wait; flush only on trap-squash of the faulting
    //          instr (NOT on ordinary EX redirect - the JALR must retire).
    assign ex_mem_flush_o = trap_squash_ex_mem_i & ~mem_stall_i;
    assign ex_mem_stall_o = hold_ex_mem & ~ex_mem_flush_o;

    // MEM/WB : bubble into WB during a D-port wait, or trap-squash of a MEM fault
    assign mem_wb_flush_o = mem_stall_i | trap_squash_mem_wb_i;
endmodule
`default_nettype wire
