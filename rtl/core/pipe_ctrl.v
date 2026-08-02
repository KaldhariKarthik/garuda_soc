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
    input  wire        wfi_hold_i,           // WFI drain-stall (trap_ctrl.wfi_hold_o)

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
    // ERRATUM P-2 (found by riscv-tests rv32mi/ma_addr)
    // -----------------------------------------------
    // An ID-stage (predicted-taken) redirect is only meaningful if the branch
    // in ID actually ISSUES into ID/EX this cycle. The redirect flushes IF/ID
    // on the assumption that the branch has moved on and only its wrongly
    // fetched shadow is left behind. When ID is held - load-use, DSU busy or
    // WFI - that assumption is false: the branch is still sitting in IF/ID, and
    // if_id_flush_o then DESTROYS THE BRANCH ITSELF. It never reaches EX, so it
    // is never resolved and never retires, and the predicted target stands as
    // if it had been confirmed.
    //
    // Seen in ma_addr as `lb t0,0(t0); beqz t0,fail`: the load-use interlock
    // holds the beqz in ID, the predictor redirects to `fail` in the same
    // cycle, the beqz is flushed away, and the core lands in `fail` having
    // never compared anything. It is timing-sensitive - injecting AHB wait
    // states shifts the coincidence apart and the test passes - which is
    // exactly the sort of bug that survives to silicon and reproduces once a
    // month.
    //
    // mem_stall is already handled by the ~mem_stall_i term below; these are
    // the remaining hold sources that keep ID from issuing.
    wire id_redir_ok = id_redirect_valid_i &
                       ~load_use_stall_i & ~dsu_busy_i & ~wfi_hold_i;

    // Redirect selection (priority trap > ex > id), gated by ~mem_stall.
    wire redir_raw   = trap_redirect_valid_i | ex_redirect_i | id_redir_ok;
    wire redirect    = redir_raw & ~mem_stall_i;
    wire redir_2b    = (trap_redirect_valid_i | ex_redirect_i) & ~mem_stall_i; // 2-bubble

    assign if_redirect_o    = redirect;
    assign if_redirect_pc_o = trap_redirect_valid_i ? trap_redirect_target_i :
                              ex_redirect_i          ? ex_redirect_target_i    :
                                                       id_redirect_target_i;

    // Holds (raw). Flushes override holds per-register below.
    // WFI (Sec. 14.5) is a drain-precise hold, not a fetch-only stall: it holds
    // PC, IF/ID *and* ID/EX. The WFI itself parks in EX (id_ex held, so is_wfi
    // stays asserted and trap_ctrl's wfi_active latch keeps holding), the
    // younger instruction stays parked in ID, and everything OLDER than the WFI
    // drains through EX/MEM/WB unimpeded because EX/MEM is not held. Holding
    // only PC/IF-ID (the earlier approximation) let the instruction behind the
    // WFI advance into EX and execute during the sleep.
    // WFI writes no architectural state (reg_write=0), so re-presenting it in
    // EX every held cycle is harmless.
    wire hold_pc_ifid = mem_stall_i | dsu_busy_i | load_use_stall_i | wfi_hold_i;
    wire hold_id_ex   = mem_stall_i | dsu_busy_i | wfi_hold_i;  // load-use flushes id_ex
    wire hold_ex_mem  = mem_stall_i;

    // PC
    assign if_stall_o    = hold_pc_ifid & ~redirect;

    // IF/ID : any redirect flushes the wrongly-fetched slot
    assign if_id_flush_o = redirect;
    assign if_id_stall_o = hold_pc_ifid & ~if_id_flush_o;

    // ID/EX : 2-bubble redirect OR load-use OR trap-squash bubbles it
    //
    // ERRATUM P-1 (found by riscv-tests ld_st)
    // ---------------------------------------
    // load_use_stall_i MUST be gated by ~mem_stall_i, for exactly the reason
    // redirects already are above. The load-use interlock bubbles ID/EX so a
    // gap opens behind a load that has ALREADY advanced into EX/MEM. During a
    // D-port wait that premise is false: EX/MEM is held (hold_ex_mem), so the
    // instruction in ID/EX cannot advance - and flushing ID/EX then does not
    // insert a bubble behind the load, it DESTROYS the load still sitting
    // there. Flush outranks stall inside id_ex.v, so the hold does not save it.
    //
    // Observed in ld_st as: sb / lb / sb / lb back to back. The sb stalls MEM
    // for its two-phase AHB access; in that same cycle the third instruction
    // in ID raises load-use against the lb parked in ID/EX, the lb is flushed
    // out of existence, and its destination register is never written - so
    // every later reader of it returned X.
    //
    // Latent until ERRATUM D-1: with the old one-cycle D-port there was no
    // multi-cycle MEM stall, so load-use and mem_stall could never overlap.
    assign id_ex_flush_o = redir_2b | (load_use_stall_i & ~mem_stall_i) |
                           trap_squash_id_ex_i;
    assign id_ex_stall_o = hold_id_ex & ~id_ex_flush_o;

    // EX/MEM : holds on D-port wait; flush only on trap-squash of the faulting
    //          instr (NOT on ordinary EX redirect - the JALR must retire).
    // ERRATUM P-3 (found by Core Sanity rows 13/20: t_dsu, t_wfi)
    // -----------------------------------------------------------
    // A stall at ID/EX must insert BUBBLES into EX/MEM. dsu_busy and wfi_hold
    // hold ID/EX but hold_ex_mem covers only mem_stall, so EX/MEM kept latching
    // the EX outputs of the very instruction that was parked - re-committing it
    // once per held cycle.
    //
    // The existing note above ("WFI writes no architectural state, so
    // re-presenting it in EX every held cycle is harmless") is true only if the
    // WFI itself is what is parked. It is not: wfi_active is a REGISTERED latch
    // in trap_ctrl, so by the time wfi_hold rises the WFI has already advanced
    // to EX/MEM and the instruction BEHIND it is sitting in ID/EX. t_wfi caught
    // that instruction executing 381 times instead of once.
    //
    // Same defect on the DSU side: a MACRD_LO parked by dsu_busy writes its
    // destination register every cycle it is held.
    //
    // mem_stall is excluded because there EX/MEM is genuinely HELD
    // (hold_ex_mem) rather than advancing, so nothing is re-committed.
    assign ex_mem_flush_o = (trap_squash_ex_mem_i | dsu_busy_i | wfi_hold_i)
                            & ~mem_stall_i;
    assign ex_mem_stall_o = hold_ex_mem & ~ex_mem_flush_o;

    // MEM/WB : bubble into WB during a D-port wait, or trap-squash of a MEM fault
    assign mem_wb_flush_o = mem_stall_i | trap_squash_mem_wb_i;
endmodule
`default_nettype wire
