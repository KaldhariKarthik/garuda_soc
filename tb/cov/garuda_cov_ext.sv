// =============================================================================
// garuda_cov_ext.sv -- core design-behaviour functional coverage, part 2
// (Track A plan E8). Bound into garuda_core_top next to garuda_cov.sv, which
// keeps decode / alu / ldst / hazard / trap / ahb / dsu. This file adds what
// the core plan's coverage list names and garuda_cov.sv does not model:
//
//   cg_pipe      hold / flush per pipeline register (incl. flush-beats-hold),
//                hold-source overlaps, redirect-source overlaps
//   cg_branch    predictor outcome (predicted x actual), JAL / JALR, BP_DIS
//   cg_csr       every implemented CSR by address, the read-zero groups, every
//                CSR op, illegal CSR accesses
//   cg_irq_take  interrupts taken: kind (CLIC / MTI), level band, nested or not
//   cg_irq_gate  every reason a pending CLIC request is or is not taken
//   cg_trap_ctx  exception inside an interrupt handler, MRET restoring a level
//   cg_sleep     WFI sleep, wake source, WFI with the clock gate disabled
//   cg_bus_err   load / store / fetch bus errors, load / store wait states
//   cg_halt      debug halt request while draining and when safe (RDC-1)
//   cg_ctl       each mgarudactl knob active while its feature is in use
//
// Portable subset on purpose (Verilator 5.052 and irun 15.2): explicit bins,
// no `intersect` cross selects (Verilator ignores them, H5), combinations as
// coverpoints on a concatenated value. Bound, never instantiated: a renamed
// signal fails the build instead of silently covering nothing.
// =============================================================================
`timescale 1ns/1ps

module garuda_cov_ext (
    input wire        clk_i,
    input wire        rst_n_i,
    // pipeline control (pipe_ctrl outputs and hold / redirect sources)
    input wire        ifid_s, ifid_f, idex_s, idex_f, exmem_s, exmem_f, mwb_f,
    input wire        mem_stall, dsu_busy, load_use, wfi_hold,
    input wire        id_redir, ex_redir, tr_redir,
    // EX stage
    input wire        xe_valid, xe_branch, xe_jal, xe_jalr, xe_pred_taken, ex_mispredict,
    input wire        xe_csr_en,
    input wire [31:0] xe_instr,
    input wire        csr_illegal,
    input wire [3:0]  ctl,                      // mgarudactl
    // traps and interrupts
    input wire        tr_enter, tr_is_int, tr_mret,
    input wire [31:0] tr_cause,
    input wire [7:0]  tr_level, mil, thresh,
    input wire        mie,
    input wire        irq_valid,
    input wire [7:0]  irq_level,
    input wire        take_cond, mtip,
    // buses
    input wire [1:0]  i_htrans, d_htrans,
    input wire        i_hready, d_hready, i_hresp, d_hresp, d_hwrite,
    // sleep, halt
    input wire        quiescent, halt_req, halt_safe
);
    // ---- derived: D-port data phase direction (AHB: the address phase that
    // completed with HREADY high owns the next data phase) -------------------
    reg d_dph, d_dph_wr, i_dph;
    always @(posedge clk_i or negedge rst_n_i)
        if (!rst_n_i) begin
            d_dph <= 1'b0; d_dph_wr <= 1'b0; i_dph <= 1'b0;
        end else begin
            if (d_hready) begin d_dph <= d_htrans[1]; d_dph_wr <= d_htrans[1] & d_hwrite; end
            if (i_hready) i_dph <= i_htrans[1];
        end

    // ---- derived: why a pending CLIC request is or is not taken -----------
    // priority order of the take condition (clic_ctrl): MIE, threshold, level,
    // then the PREEMPT_DIS knob; 0 = taken
    localparam [2:0] G_TAKEN = 3'd0, G_MIE = 3'd1, G_THRESH = 3'd2, G_LEVEL = 3'd3,
                     G_PDIS = 3'd4, G_OTHER = 3'd5;
    wire [2:0] gate = take_cond                         ? G_TAKEN  :
                      !mie                              ? G_MIE    :
                      (irq_level <= thresh)             ? G_THRESH :
                      (irq_level <= mil)                ? G_LEVEL  :
                      (ctl[2] && mil != 8'd0)           ? G_PDIS   : G_OTHER;

    // ---- derived: wake from WFI (falling edge of quiescent) ---------------
    reg quiescent_q;
    always @(posedge clk_i or negedge rst_n_i)
        if (!rst_n_i) quiescent_q <= 1'b0; else quiescent_q <= quiescent;
    wire wake = quiescent_q & ~quiescent;

    wire [11:0] csr_addr = xe_instr[31:20];
    wire [2:0]  csr_op   = xe_instr[14:12];
    wire        is_mti   = tr_is_int && (tr_cause[11:0] == 12'd7);

    // =====================================================================
    covergroup cg_pipe @(posedge clk_i iff rst_n_i);
        option.per_instance = 1;
        // per register: held, flushed, and held+flushed in the same cycle
        // (the flush must win, pipe_ctrl rule; the cell where that is visible)
        cp_ifid:  coverpoint {ifid_s, ifid_f}   { bins hold = {2'b10}; bins flush = {2'b01}; bins hold_flush = {2'b11}; }
        cp_idex:  coverpoint {idex_s, idex_f}   { bins hold = {2'b10}; bins flush = {2'b01}; bins hold_flush = {2'b11}; }
        cp_exmem: coverpoint {exmem_s, exmem_f} { bins hold = {2'b10}; bins flush = {2'b01}; }
        cp_mwb:   coverpoint mwb_f              { bins flush = {1'b1}; }
        // hold sources alone and the overlaps the hold table orders
        cp_hold:  coverpoint {mem_stall, dsu_busy, load_use, wfi_hold} {
            bins mem_wait = {4'b1000}; bins dsu_busy = {4'b0100};
            bins load_use = {4'b0010}; bins wfi      = {4'b0001};
            bins mem_and_load_use = {4'b1010};
        }
        // redirect sources alone and together (priority trap > EX > ID)
        cp_redir: coverpoint {tr_redir, ex_redir, id_redir} {
            bins id = {3'b001}; bins ex = {3'b010}; bins trap = {3'b100};
            bins ex_over_id = {3'b011}; bins trap_over_id = {3'b101}; bins trap_over_ex = {3'b110};
        }
        // a redirect frozen by a D-port wait (applied the cycle it clears)
        cp_redir_waited: coverpoint ((id_redir | ex_redir | tr_redir) & mem_stall) { bins yes = {1'b1}; }
    endgroup

    // =====================================================================
    covergroup cg_branch @(posedge clk_i iff (rst_n_i && xe_valid && !mem_stall));
        option.per_instance = 1;
        cp_outcome: coverpoint {xe_pred_taken, ex_mispredict} iff (xe_branch) {
            bins pred_nt_right = {2'b00}; bins pred_nt_wrong = {2'b01};
            bins pred_t_right  = {2'b10}; bins pred_t_wrong  = {2'b11};
        }
        cp_jump:    coverpoint {xe_jal, xe_jalr} { bins jal = {2'b10}; bins jalr = {2'b01}; }
        cp_bp_dis:  coverpoint {ctl[0], ex_mispredict} iff (xe_branch) {
            bins dis_right = {2'b10}; bins dis_wrong = {2'b11};
        }
    endgroup

    // =====================================================================
    covergroup cg_csr @(posedge clk_i iff (rst_n_i && xe_valid && xe_csr_en && !mem_stall));
        option.per_instance = 1;
        cp_addr: coverpoint csr_addr {
            bins mstatus = {12'h300}; bins misa = {12'h301}; bins mie = {12'h304};
            bins mtvec = {12'h305}; bins mscratch = {12'h340}; bins mepc = {12'h341};
            bins mcause = {12'h342}; bins mtval = {12'h343}; bins mip = {12'h344};
            bins mnxti = {12'h345}; bins mintstatus = {12'h346}; bins mintthresh = {12'h347};
            bins mgarudactl = {12'h7C0};
            bins mcycle = {12'hB00}; bins minstret = {12'hB02};
            bins mcycleh = {12'hB80}; bins minstreth = {12'hB82};
            bins dsu_ovf = {12'hBC0};
            bins cycle = {12'hC00}; bins instret = {12'hC02};
            bins cycleh = {12'hC80}; bins instreth = {12'hC82};
            bins mvendorid = {12'hF11}; bins marchid = {12'hF12}; bins mimpid = {12'hF13};
            bins mhartid = {12'hF14}; bins mintstatus_std = {12'hFB1};
            // C-16 read-zero groups
            bins rz_mstatush = {12'h310}; bins rz_mconfigptr = {12'hF15};
            bins rz_mhpmcounter = {[12'hB03:12'hB1F]}; bins rz_mhpmcounterh = {[12'hB83:12'hB9F]};
            bins rz_mhpmevent = {[12'h323:12'h33F]};
        }
        cp_op: coverpoint csr_op {
            bins rw = {3'd1}; bins rs = {3'd2}; bins rc = {3'd3};
            bins rwi = {3'd5}; bins rsi = {3'd6}; bins rci = {3'd7};
        }
        cp_illegal: coverpoint csr_illegal { bins illegal = {1'b1}; }
    endgroup

    // =====================================================================
    covergroup cg_irq_take @(posedge clk_i iff (rst_n_i && tr_enter && tr_is_int));
        option.per_instance = 1;
        cp_kind:  coverpoint is_mti { bins clic = {1'b0}; bins mti = {1'b1}; }
        cp_level: coverpoint tr_level iff (!is_mti) {
            bins l1_63 = {[8'd1:8'd63]}; bins l64_127 = {[8'd64:8'd127]};
            bins l128_191 = {[8'd128:8'd191]}; bins l192_255 = {[8'd192:8'd255]};
        }
        // taken at level 0 or preempting a running handler (nesting)
        cp_nest:  coverpoint {is_mti, (mil != 8'd0)} {
            bins clic_at_level0 = {2'b00}; bins clic_preempts = {2'b01};
            bins mti_at_level0 = {2'b10}; bins mti_in_handler = {2'b11};
        }
    endgroup

    covergroup cg_irq_gate @(posedge clk_i iff (rst_n_i && irq_valid));
        option.per_instance = 1;
        cp_gate: coverpoint gate {
            bins taken = {G_TAKEN}; bins blocked_mie = {G_MIE}; bins blocked_threshold = {G_THRESH};
            bins blocked_level = {G_LEVEL}; bins blocked_preempt_dis = {G_PDIS};
        }
        cp_equal: coverpoint {(irq_level == thresh), (irq_level == mil)} iff (mie) {
            bins eq_threshold = {2'b10}; bins eq_level = {2'b01};
        }
    endgroup

    // =====================================================================
    covergroup cg_trap_ctx @(posedge clk_i iff (rst_n_i && (tr_enter || tr_mret)));
        option.per_instance = 1;
        // an exception taken inside an interrupt handler keeps the level (T-12 R1)
        cp_exc_in_handler: coverpoint {tr_enter && !tr_is_int, (mil != 8'd0)} {
            bins exc_at_level0 = {2'b10}; bins exc_in_handler = {2'b11};
        }
        // MRET returning into a handler (level restored != 0) or to level 0
        cp_mret: coverpoint {tr_mret, (mil != 8'd0)} {
            bins mret_from_level0 = {2'b10}; bins mret_from_handler = {2'b11};
        }
    endgroup

    // =====================================================================
    covergroup cg_sleep @(posedge clk_i iff rst_n_i);
        option.per_instance = 1;
        cp_asleep: coverpoint quiescent { bins asleep = {1'b1}; }
        cp_wake:   coverpoint {wake, irq_valid, mtip} {
            bins wake_clic = {3'b110}; bins wake_mti = {3'b101};
        }
        // WFI with CG_DIS: the core holds but the clock keeps running
        cp_wfi_nogate: coverpoint {wfi_hold, ctl[3]} { bins wfi_cg_dis = {2'b11}; bins wfi_cg_on = {2'b10}; }
    endgroup

    // =====================================================================
    covergroup cg_bus_err @(posedge clk_i iff rst_n_i);
        option.per_instance = 1;
        // first ERROR cycle (HREADY low, HRESP high) by kind of transfer
        cp_d_err:  coverpoint {d_dph, d_dph_wr, d_hresp, d_hready} {
            bins load_error = {4'b1010}; bins store_error = {4'b1110};
        }
        cp_d_wait: coverpoint {d_dph, d_dph_wr, d_hresp, d_hready} {
            bins load_wait = {4'b1000}; bins store_wait = {4'b1100};
        }
        cp_i_err:  coverpoint {i_dph, i_hresp, i_hready} { bins fetch_error = {3'b110}; }
    endgroup

    // =====================================================================
    covergroup cg_halt @(posedge clk_i iff (rst_n_i && halt_req));
        option.per_instance = 1;
        cp_halt: coverpoint {halt_safe, (d_dph | d_htrans[1]), (i_dph | i_htrans[1])} {
            bins draining_dport = {3'b010}; bins draining_iport = {3'b001};
            bins draining_both = {3'b011}; bins safe = {3'b100};
        }
    endgroup

    // =====================================================================
    covergroup cg_ctl @(posedge clk_i iff rst_n_i);
        option.per_instance = 1;
        cp_bp_dis:      coverpoint (ctl[0] & xe_valid & xe_branch) { bins active = {1'b1}; }
        cp_pf_dis:      coverpoint (ctl[1] & i_htrans[1])          { bins active = {1'b1}; }
        cp_preempt_dis: coverpoint (ctl[2] & irq_valid & (mil != 8'd0) & (irq_level > mil) & (irq_level > thresh) & mie)
                                                                    { bins active = {1'b1}; }
        cp_cg_dis:      coverpoint (ctl[3] & wfi_hold)              { bins active = {1'b1}; }
    endgroup

    cg_pipe     u_cg_pipe     = new();
    cg_branch   u_cg_branch   = new();
    cg_csr      u_cg_csr      = new();
    cg_irq_take u_cg_irq_take = new();
    cg_irq_gate u_cg_irq_gate = new();
    cg_trap_ctx u_cg_trap_ctx = new();
    cg_sleep    u_cg_sleep    = new();
    cg_bus_err  u_cg_bus_err  = new();
    cg_halt     u_cg_halt     = new();
    cg_ctl      u_cg_ctl      = new();
endmodule

// Attach to the core without touching the RTL.
bind garuda_core_top garuda_cov_ext u_cov_ext_a (
    .clk_i(clk_i), .rst_n_i(rst_n_i),
    .ifid_s(pc_ifid_s), .ifid_f(pc_ifid_f), .idex_s(pc_idex_s), .idex_f(pc_idex_f),
    .exmem_s(pc_exmem_s), .exmem_f(pc_exmem_f), .mwb_f(pc_mwb_f),
    .mem_stall(mem_stall), .dsu_busy(ex_dsu_busy), .load_use(id_load_use), .wfi_hold(tr_wfi_hold),
    .id_redir(id_redir_v), .ex_redir(ex_redirect), .tr_redir(tr_redir_v),
    .xe_valid(xe_valid), .xe_branch(xe_branch), .xe_jal(xe_jal), .xe_jalr(xe_jalr),
    .xe_pred_taken(xe_predicted_taken), .ex_mispredict(ex_branch_mispredict),
    .xe_csr_en(xe_csr_en), .xe_instr(xe_instr), .csr_illegal(csr_illegal), .ctl(csr_ctl),
    .tr_enter(tr_enter), .tr_is_int(tr_is_int), .tr_mret(tr_mret), .tr_cause(tr_cause),
    .tr_level(tr_level), .mil(csr_mil), .thresh(csr_mintthresh), .mie(csr_mstatus_mie),
    .irq_valid(clic_irq_valid_i), .irq_level(clic_irq_level_i), .take_cond(clic_take_cond),
    .mtip(mtip_i),
    .i_htrans(i_htrans_o), .d_htrans(d_htrans_o), .i_hready(i_hready_i), .d_hready(d_hready_i),
    .i_hresp(i_hresp_i), .d_hresp(d_hresp_i), .d_hwrite(d_hwrite_o),
    .quiescent(quiescent), .halt_req(halt_req_i), .halt_safe(halt_safe_o)
);
