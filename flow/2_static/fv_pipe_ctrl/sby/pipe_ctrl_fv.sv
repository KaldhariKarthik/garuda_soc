// =============================================================================
// pipe_ctrl_fv.sv -- open-source formal (SymbiYosys) for pipe_ctrl
//
// The properties of rtl/core/pipe_ctrl_sva.sv, restated as immediate
// assertions and covers, because open-source Yosys cannot parse clocked
// concurrent SVA (`assert property (@(posedge clk) ...)`). The names match
// that file one for one; a change to one must be made to the other.
//
// pipe_ctrl is purely combinational and every property is stated over its
// own ports, so here EVERY input is free: the solver proves each claim for
// all 2^n input combinations, not only those the rest of the core produces.
// That is stronger than the bound-at-the-core IFV run in ../prove.tcl for the
// assertions, and weaker for the covers: a cover reached here says the cell
// is reachable for SOME inputs to pipe_ctrl, not that the core ever drives
// them so (that question - AUD-8, four hold-vs-flush cells never hit in
// simulation - still needs the whole-core run).
//
// Vacuity (the "passes because its condition never happens" problem): each
// implication a |-> b also gets a cover on a, prefixed v_. A v_ cover that is
// unreachable means its assertion can never fire and proves nothing.
//
// Run: sby -f flow/2_static/fv_pipe_ctrl/sby/pipe_ctrl.sby   (from the repo root)
// =============================================================================
module pipe_ctrl_fv (
    input wire        clk,
    input wire        mem_stall,
    input wire        dsu_busy,
    input wire        load_use,
    input wire        wfi_hold,
    input wire        id_redir_v,
    input wire [31:0] id_redir_t,
    input wire        ex_redir,
    input wire [31:0] ex_redir_t,
    input wire        trap_redir_v,
    input wire [31:0] trap_redir_t,
    input wire        trap_sq_id_ex,
    input wire        trap_sq_ex_mem,
    input wire        trap_sq_mem_wb,
    input wire        bus_idle,
    input wire        wfi_settled
);
    wire        if_stall, if_redirect, if_id_stall, if_id_flush;
    wire        id_ex_stall, id_ex_flush, ex_mem_stall, ex_mem_flush, mem_wb_flush;
    wire        quiescent;
    wire [31:0] if_redirect_pc;

    pipe_ctrl u_pipe (
        .mem_stall_i(mem_stall), .dsu_busy_i(dsu_busy), .load_use_stall_i(load_use),
        .wfi_hold_i(wfi_hold),
        .id_redirect_valid_i(id_redir_v), .id_redirect_target_i(id_redir_t),
        .ex_redirect_i(ex_redir), .ex_redirect_target_i(ex_redir_t),
        .trap_redirect_valid_i(trap_redir_v), .trap_redirect_target_i(trap_redir_t),
        .trap_squash_id_ex_i(trap_sq_id_ex), .trap_squash_ex_mem_i(trap_sq_ex_mem),
        .trap_squash_mem_wb_i(trap_sq_mem_wb),
        .if_stall_o(if_stall), .if_redirect_o(if_redirect), .if_redirect_pc_o(if_redirect_pc),
        .if_id_stall_o(if_id_stall), .if_id_flush_o(if_id_flush),
        .id_ex_stall_o(id_ex_stall), .id_ex_flush_o(id_ex_flush),
        .ex_mem_stall_o(ex_mem_stall), .ex_mem_flush_o(ex_mem_flush),
        .mem_wb_flush_o(mem_wb_flush),
        .bus_idle_i(bus_idle), .wfi_settled_i(wfi_settled), .quiescent_o(quiescent));

    // ---- the one environment assumption ----
    // A1: no ID/EX trap squash while H2 holds. trap_squash_id_ex_i flushes
    // ID/EX without looking at mem_stall_i, so a_h2_defers_flush_loaduse
    // depends on it. Discharged by G1 and G2 in env_guarantees_fv.sv (tasks
    // g1_dport and g2_trap), not taken on trust.
    always @* a1_no_trap_squash_under_h2: assume (!(trap_sq_id_ex && mem_stall));

    always @(posedge clk) begin
        // ---- assertions, as in pipe_ctrl_sva.sv ----
        a_flush_beats_hold_if_id:  assert (!(if_id_flush  && if_id_stall));
        a_flush_beats_hold_id_ex:  assert (!(id_ex_flush  && id_ex_stall));
        a_flush_beats_hold_ex_mem: assert (!(ex_mem_flush && ex_mem_stall));
        a_h2_defers_flush:         assert (!mem_stall || !if_redirect);
        a_h2_defers_flush_loaduse: assert (!(mem_stall && load_use) || !id_ex_flush);
        a_trap_beats_branch:       assert (!(trap_redir_v && !mem_stall) ||
                                           (if_redirect && if_redirect_pc == trap_redir_t));
        a_no_gate_with_bus:        assert (!quiescent || bus_idle);
        a_no_gate_mid_work:        assert (!quiescent || (!dsu_busy && !mem_stall));
`ifdef PIPE_CTRL_FV_CONTEXT
        // NOT a pipe_ctrl property. quiescent_o does not look at redirects or
        // flush sources, and with free inputs each of the five disjuncts below
        // fails on its own (2026-10-11): it holds only if trap_ctrl, the ID and
        // EX stages and the CLIC never raise a redirect or flush while H5 has
        // settled. That is a whole-core claim - prove it with the core bound
        // (../prove.tcl, IFV/JasperGold), not here.
        a_no_gate_with_flush:      assert (!quiescent || !(if_redirect || trap_redir_v ||
                                           if_id_flush || id_ex_flush || mem_wb_flush));
`endif

        // ---- vacuity: every implication's antecedent is reachable ----
        v_h2_defers_flush:         cover (mem_stall);
        v_h2_defers_flush_loaduse: cover (mem_stall && load_use);
        v_trap_beats_branch:       cover (trap_redir_v && !mem_stall);
        v_no_gate:                 cover (quiescent);

        // ---- the hold x register matrix, as in pipe_ctrl_sva.sv ----
        c_h1_ifid:        cover (load_use  && if_id_stall);
        c_h1_idex:        cover (load_use  && id_ex_flush);
        c_h2_ifid:        cover (mem_stall && if_id_stall);
        c_h2_idex:        cover (mem_stall && id_ex_stall);
        c_h2_exmem:       cover (mem_stall && ex_mem_stall);
        c_h4_ifid:        cover (dsu_busy  && if_id_stall);
        c_h4_idex:        cover (dsu_busy  && id_ex_stall);
        c_h5_ifid:        cover (wfi_hold  && if_id_stall);
        c_h5_idex:        cover (wfi_hold  && id_ex_stall);
        c_h1_vs_redirect: cover (load_use  && if_redirect);
        c_h2_vs_redirect: cover (mem_stall && (trap_redir_v || ex_redir));
        c_h4_vs_redirect: cover (dsu_busy  && if_redirect);
        c_h5_vs_trap:     cover (wfi_hold  && trap_redir_v);
    end
endmodule
