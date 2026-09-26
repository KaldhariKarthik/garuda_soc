`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 1 : formal/simulation properties for pipe_ctrl
// pipe_ctrl_sva.sv
//
// Spec: GARUDA-CORE-SPEC-001 [N-11.3], which names these five properties and
// says: "If there is time for formal on exactly one block, it is this one."
// They did not exist until now (Docs/BUGS.md AUD-8).
//
// -----------------------------------------------------------------------------
// WHY A BIND FILE AND NOT ASSERTIONS INSIDE pipe_ctrl.v
// -----------------------------------------------------------------------------
// Two reasons. `pipe_ctrl` is purely combinational - every output is a
// continuous assignment and the module has no clock port - so there is nothing
// inside it to sample a concurrent assertion on. And the synthesised source
// stays free of simulation constructs.
//
// The bind is at garuda_core_top, on `clk_i`, the UNGATED clock. That matters
// for the two clock-gating properties: bound to `gclk` they would stop being
// evaluated at exactly the moment the gate closes, which is the moment they
// exist to check.
//
// Because this is bound at the core, it is evaluated by EVERY simulation that
// instantiates the core - the whole ISA regression, the sanity suite and all
// seven chip tests - not only by a dedicated unit test. That is deliberate:
// the hold/flush cross product is a composition property, and composition is
// exercised far better by real instruction streams than by a bench.
//
// [N-7.21] the rule: a flush strictly beats a hold on the same register.
// [N-7.24] the one exception: H2 (D-port wait) defers the flush instead,
//          because AHB-Lite cannot abort a transfer whose address phase has
//          been accepted.
// =============================================================================

`ifndef SYNTHESIS
module pipe_ctrl_sva (
    input wire clk,
    input wire rst_n,

    // hold sources (H1 load-use, H2 D-port, H4 dsu_busy, H5 WFI)
    input wire mem_stall,
    input wire dsu_busy,
    input wire load_use,
    input wire wfi_hold,

    // redirects
    input wire        trap_redir_v,
    input wire [31:0] trap_redir_t,
    input wire        ex_redir,
    input wire        if_redirect,
    input wire [31:0] if_redirect_pc,

    // per-register stall / flush
    input wire if_id_stall,  input wire if_id_flush,
    input wire id_ex_stall,  input wire id_ex_flush,
    input wire ex_mem_stall, input wire ex_mem_flush,
    input wire mem_wb_flush,

    // clock gating
    input wire bus_idle,
    input wire quiescent
);

    // -------------------------------------------------------------------------
    // [N-7.21] a_flush_beats_hold
    // A register is never told to hold and to flush in the same cycle. The
    // flush wins, so the stall output must be withdrawn - not merely ignored
    // downstream. Stated per register because each composes its own sources.
    // -------------------------------------------------------------------------
    a_flush_beats_hold_if_id: assert property (@(posedge clk) disable iff (!rst_n)
        !(if_id_flush && if_id_stall));

    a_flush_beats_hold_id_ex: assert property (@(posedge clk) disable iff (!rst_n)
        !(id_ex_flush && id_ex_stall));

    a_flush_beats_hold_ex_mem: assert property (@(posedge clk) disable iff (!rst_n)
        !(ex_mem_flush && ex_mem_stall));

    // -------------------------------------------------------------------------
    // [N-7.24] a_h2_defers_flush
    // H2 is the exception: while a D-port data phase is outstanding the flush
    // is DEFERRED, not applied. Two consequences, both of which were once
    // errata in this file:
    //   - no redirect may be applied (the redirect source stays asserted and
    //     fires the cycle the wait clears);
    //   - load-use must not bubble ID/EX, because EX/MEM is held and the
    //     "gap behind a load that has already advanced" premise is false.
    //     That is ERRATUM P-1, which destroyed the load still sitting there.
    // -------------------------------------------------------------------------
    a_h2_defers_flush: assert property (@(posedge clk) disable iff (!rst_n)
        mem_stall |-> !if_redirect);

    a_h2_defers_flush_loaduse: assert property (@(posedge clk) disable iff (!rst_n)
        (mem_stall && load_use) |-> !id_ex_flush);

    // -------------------------------------------------------------------------
    // a_trap_beats_branch
    // Redirect priority is trap/MRET > EX > ID. When a trap redirect is live
    // and not deferred by H2, the fetch target is the trap's, whatever the
    // branch units are asking for at the same moment.
    // -------------------------------------------------------------------------
    a_trap_beats_branch: assert property (@(posedge clk) disable iff (!rst_n)
        (trap_redir_v && !mem_stall) |-> (if_redirect && (if_redirect_pc == trap_redir_t)));

    // -------------------------------------------------------------------------
    // a_no_gate_with_bus  [N-7.28]
    // The clock gate must never close over an outstanding bus transfer. AHB
    // cannot be paused mid-data-phase, so gating there would hang the fabric,
    // not merely lose time.
    // -------------------------------------------------------------------------
    a_no_gate_with_bus: assert property (@(posedge clk) disable iff (!rst_n)
        quiescent |-> bus_idle);

    // and the two hold sources that must also be clear before gating, so a
    // gate can never freeze a DSU accumulate or a D-port data phase part-way
    a_no_gate_mid_work: assert property (@(posedge clk) disable iff (!rst_n)
        quiescent |-> (!dsu_busy && !mem_stall));

    // -------------------------------------------------------------------------
    // a_no_gate_with_flush
    // A flush in flight is work the pipeline still owes. Stopping the clock
    // with one pending would leave the squashed slot latched and the redirect
    // unapplied - the core would wake up having silently executed it.
    // -------------------------------------------------------------------------
    a_no_gate_with_flush: assert property (@(posedge clk) disable iff (!rst_n)
        quiescent |-> !(if_id_flush || id_ex_flush || ex_mem_flush || mem_wb_flush));

    // -------------------------------------------------------------------------
    // Coverage of the [N-11.2] matrix: 5 hold sources x 4 pipeline registers.
    // H3 (I-port empty) is not visible at this interface - it is absorbed by
    // the fetch front end - so 4 sources x 4 registers are observable here.
    // These cover points are what makes the claim "the matrix was exercised"
    // checkable rather than asserted.
    // -------------------------------------------------------------------------
    c_h1_ifid: cover property (@(posedge clk) disable iff (!rst_n) load_use  && if_id_stall);
    c_h1_idex: cover property (@(posedge clk) disable iff (!rst_n) load_use  && id_ex_flush);
    c_h2_ifid: cover property (@(posedge clk) disable iff (!rst_n) mem_stall && if_id_stall);
    c_h2_idex: cover property (@(posedge clk) disable iff (!rst_n) mem_stall && id_ex_stall);
    c_h2_exmem:cover property (@(posedge clk) disable iff (!rst_n) mem_stall && ex_mem_stall);
    c_h4_ifid: cover property (@(posedge clk) disable iff (!rst_n) dsu_busy  && if_id_stall);
    c_h4_idex: cover property (@(posedge clk) disable iff (!rst_n) dsu_busy  && id_ex_stall);
    c_h5_ifid: cover property (@(posedge clk) disable iff (!rst_n) wfi_hold  && if_id_stall);
    c_h5_idex: cover property (@(posedge clk) disable iff (!rst_n) wfi_hold  && id_ex_stall);

    // the interesting cells: a hold and a flush colliding on one register
    c_h1_vs_redirect: cover property (@(posedge clk) disable iff (!rst_n)
        load_use && if_redirect);
    c_h2_vs_redirect: cover property (@(posedge clk) disable iff (!rst_n)
        mem_stall && (trap_redir_v || ex_redir));
    c_h4_vs_redirect: cover property (@(posedge clk) disable iff (!rst_n)
        dsu_busy && if_redirect);
    c_h5_vs_trap: cover property (@(posedge clk) disable iff (!rst_n)
        wfi_hold && trap_redir_v);

    // -------------------------------------------------------------------------
    // The same matrix as counters, so a simulation can PRINT which cells it
    // reached. `cover property` is the right form for formal; this is the form
    // a regression can report, and [N-11.2]'s claim that the cross product was
    // exercised is only checkable if someone can see the cells.
    // GARUDA_PIPE_MATRIX=1 prints it at the end of the run.
    // -------------------------------------------------------------------------
    int m_h1_ifid=0, m_h1_idex=0, m_h2_ifid=0, m_h2_idex=0, m_h2_exmem=0;
    int m_h4_ifid=0, m_h4_idex=0, m_h5_ifid=0, m_h5_idex=0;
    int m_h1_redir=0, m_h2_redir=0, m_h4_redir=0, m_h5_trap=0;

    always @(posedge clk) if (rst_n) begin
        if (load_use  && if_id_stall)   m_h1_ifid++;
        if (load_use  && id_ex_flush)   m_h1_idex++;
        if (mem_stall && if_id_stall)   m_h2_ifid++;
        if (mem_stall && id_ex_stall)   m_h2_idex++;
        if (mem_stall && ex_mem_stall)  m_h2_exmem++;
        if (dsu_busy  && if_id_stall)   m_h4_ifid++;
        if (dsu_busy  && id_ex_stall)   m_h4_idex++;
        if (wfi_hold  && if_id_stall)   m_h5_ifid++;
        if (wfi_hold  && id_ex_stall)   m_h5_idex++;
        if (load_use  && if_redirect)                   m_h1_redir++;
        if (mem_stall && (trap_redir_v || ex_redir))    m_h2_redir++;
        if (dsu_busy  && if_redirect)                   m_h4_redir++;
        if (wfi_hold  && trap_redir_v)                  m_h5_trap++;
    end

    final begin
        if ($test$plusargs("GARUDA_PIPE_MATRIX")) begin
            $display("[PIPE-MATRIX] hold x register, times reached");
            $display("[PIPE-MATRIX]   H1 load-use : if_id=%0d id_ex_flush=%0d  vs-redirect=%0d",
                     m_h1_ifid, m_h1_idex, m_h1_redir);
            $display("[PIPE-MATRIX]   H2 D-port   : if_id=%0d id_ex=%0d ex_mem=%0d  vs-redirect=%0d",
                     m_h2_ifid, m_h2_idex, m_h2_exmem, m_h2_redir);
            $display("[PIPE-MATRIX]   H4 dsu_busy : if_id=%0d id_ex=%0d  vs-redirect=%0d",
                     m_h4_ifid, m_h4_idex, m_h4_redir);
            $display("[PIPE-MATRIX]   H5 WFI      : if_id=%0d id_ex=%0d  vs-trap=%0d",
                     m_h5_ifid, m_h5_idex, m_h5_trap);
        end
    end

endmodule

// Bound at the core, on the UNGATED clock - see the header.
bind garuda_core_top pipe_ctrl_sva u_pipe_sva (
    .clk           (clk_i),
    .rst_n         (rst_n_i),
    .mem_stall     (u_pipe.mem_stall_i),
    .dsu_busy      (u_pipe.dsu_busy_i),
    .load_use      (u_pipe.load_use_stall_i),
    .wfi_hold      (u_pipe.wfi_hold_i),
    .trap_redir_v  (u_pipe.trap_redirect_valid_i),
    .trap_redir_t  (u_pipe.trap_redirect_target_i),
    .ex_redir      (u_pipe.ex_redirect_i),
    .if_redirect   (u_pipe.if_redirect_o),
    .if_redirect_pc(u_pipe.if_redirect_pc_o),
    .if_id_stall   (u_pipe.if_id_stall_o),
    .if_id_flush   (u_pipe.if_id_flush_o),
    .id_ex_stall   (u_pipe.id_ex_stall_o),
    .id_ex_flush   (u_pipe.id_ex_flush_o),
    .ex_mem_stall  (u_pipe.ex_mem_stall_o),
    .ex_mem_flush  (u_pipe.ex_mem_flush_o),
    .mem_wb_flush  (u_pipe.mem_wb_flush_o),
    .bus_idle      (u_pipe.bus_idle_i),
    .quiescent     (u_pipe.quiescent_o)
);
`endif
