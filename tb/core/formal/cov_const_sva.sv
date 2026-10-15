// =============================================================================
// cov_const_sva.sv -- formal evidence for coverage exclusions (Track A
// coverage closure, 2026-10-11; H5 waiver rule).
//
// Every toggle / line / expression point that tb/core/cov/core_waivers.toml
// excludes as "constant" or "unreachable" in a REGISTER or a DERIVED signal is
// asserted here and proven on the whole core (tb/core/formal/cov_unreach.toml,
// free bus responses, instructions and interrupts). A literal constant in the
// RTL (assign x = 1'b0, {.., 2'b00}) needs no proof: its waiver cites the line.
// If a property here FAILS, the point is reachable: it gets a test, never a
// waiver.
// Portable SVA subset (H4): boolean asserts, no |->.
// =============================================================================
`timescale 1ns/1ps

`ifdef FORMAL
  `define GARUDA_COVCONST_SVA
`elsif SYNTHESIS
`else
  `define GARUDA_COVCONST_SVA
`endif

`ifdef GARUDA_COVCONST_SVA
// ---- core top: every fetch-path and pipeline PC is word-aligned ----------------
// Before the BUS-E fix a JAL / predicted branch to a 2-mod-4 target could put
// that address on the I-port and into the pipeline as bubbles (formal traces,
// 2026-10-11). With BUS-E fixed no misaligned fetch is issued, so no slot ever
// carries a misaligned PC: bits [1:0] of all these copies are constant 0. Only
// pc_gen's fetch_pc and the redirect targets can hold bit 1 (they toggle, the
// fetch is just not issued). The trap redirect target is word-aligned.
module cov_const_top (
    input wire        clk, rst_n,
    input wire [31:0] i_haddr, if_pc, fd_pc, id_pc, xe_pc, em_pc, mem_exc_pc, tr_pc, csr_mepc,
    input wire [31:0] redir_pc, id_redir_t, tr_redir_t, tr_cause,
    input wire [3:0]  mem_exc_cause
);
    a_pc_aligned: assert property (@(posedge clk) disable iff (!rst_n)
        ((i_haddr | if_pc | fd_pc | id_pc | xe_pc | em_pc | mem_exc_pc | tr_pc) & 32'h3) == 32'd0);
    a_mepc_aligned:       assert property (@(posedge clk) disable iff (!rst_n) csr_mepc[1:0] == 2'b00);
    a_redir_pc_bit0:      assert property (@(posedge clk) disable iff (!rst_n) (redir_pc[0] | id_redir_t[0]) == 1'b0);
    a_trap_redir_aligned: assert property (@(posedge clk) disable iff (!rst_n) tr_redir_t[1:0] == 2'b00);
    a_cause_field:        assert property (@(posedge clk) disable iff (!rst_n) tr_cause[30:5] == 26'd0);
    a_mexc_cause_bit3:    assert property (@(posedge clk) disable iff (!rst_n) mem_exc_cause[3] == 1'b0);
endmodule

// ---- reachability of functional-coverage holes (covers: COVERED = a test is
// owed, the trace shows how; UNREACHED at depth is only a hint, never a waiver)
module cov_reach_top (
    input wire       clk, rst_n,
    input wire       ifid_s, ifid_f, idex_s, idex_f, mem_stall, dsu_busy,
    input wire [1:0] fwd_a_sel,
    input wire       irq_valid, mie,
    input wire [7:0] irq_level, mil, thresh,
    input wire [1:0] i_htrans,
    input wire [31:0] i_haddr
);
    // a fetch address phase with HADDR bit 1 set was REACHABLE before the BUS-E
    // fix (cover reached at step 12, logs/core/evidence/BUS-E_before.txt); after
    // it, rtl/core/core_ctl_sva.sv a_ihaddr_aligned is PROVEN (fv_trap)
    c_irq_blocked_level: cover property (@(posedge clk) disable iff (!rst_n)
                             irq_valid && mie && irq_level > thresh && irq_level <= mil);
    // hold+flush in one cycle (IF/ID, ID/EX) and an EX/MEM forward during a
    // D-port wait never occur in the integrated core: no cover reached them
    // (depth 30) and these negations are PROVEN unbounded (2026-10-11); the
    // matching coverage bins are waived on this evidence
    a_no_ifid_hold_flush: assert property (@(posedge clk) disable iff (!rst_n) !(ifid_s && ifid_f));
    a_no_idex_hold_flush: assert property (@(posedge clk) disable iff (!rst_n) !(idex_s && idex_f));
    a_no_fwd_exmem_stall: assert property (@(posedge clk) disable iff (!rst_n) !(fwd_a_sel == 2'b01 && mem_stall));
endmodule

// ---- prefetch buffer: its users never overflow or underflow it ---------------
module cov_const_pfb (
    input wire       clk, rst_n,
    input wire [2:0] occupancy,
    input wire       wr_en, rd_en
);
    a_pfb_no_overflow:  assert property (@(posedge clk) disable iff (!rst_n) !(occupancy == 3'd4 && wr_en && !rd_en));
    a_pfb_no_underflow: assert property (@(posedge clk) disable iff (!rst_n) !(occupancy == 3'd0 && rd_en));
    // write+read at full never occurs in the core either (PROVEN; bin waived)
    a_pfb_no_full_rw:   assert property (@(posedge clk) disable iff (!rst_n) !(occupancy == 3'd4 && wr_en && rd_en));
endmodule

// ---- csr_file: WARL storage never holds an illegal bit -----------------------
module cov_const_csr (
    input wire        clk, rst_n,
    input wire [31:0] mie_r, mepc_r
);
    a_mie_only_mtie:  assert property (@(posedge clk) disable iff (!rst_n) (mie_r & ~32'h0000_0080) == 32'd0);
    a_mepc_r_aligned: assert property (@(posedge clk) disable iff (!rst_n) mepc_r[1:0] == 2'b00);
endmodule

// ---- D-port FSM: two states in a 2-bit register ------------------------------
module cov_const_dport (
    input wire       clk, rst_n,
    input wire [1:0] state
);
    a_dport_state_legal: assert property (@(posedge clk) disable iff (!rst_n) state[1] == 1'b0);
endmodule

// ---- I-port: in-flight and occupancy arithmetic stays small ------------------
module cov_const_iport (
    input wire        clk, rst_n,
    input wire [3:0]  inflight, occ_after_pop, occ_plus_landing, projected_occ,
    input wire [31:0] addr_pc, outstanding_pc
);
    a_iport_pc_aligned: assert property (@(posedge clk) disable iff (!rst_n) ((addr_pc | outstanding_pc) & 32'h3) == 32'd0);
    a_inflight_le2:     assert property (@(posedge clk) disable iff (!rst_n) inflight <= 4'd2);
    a_occ_pop_lt8:      assert property (@(posedge clk) disable iff (!rst_n) occ_after_pop < 4'd8);
    a_occ_land_lt8:     assert property (@(posedge clk) disable iff (!rst_n) occ_plus_landing < 4'd8);
    a_proj_occ_lt8:     assert property (@(posedge clk) disable iff (!rst_n) projected_occ < 4'd8);
endmodule

bind garuda_core_top cov_const_top u_cov_const_top (
    .clk(clk_i), .rst_n(rst_n_i),
    .i_haddr(i_haddr_o), .if_pc(if_pc), .fd_pc(fd_pc), .id_pc(id_pc), .xe_pc(xe_pc), .em_pc(em_pc),
    .mem_exc_pc(mem_exc_pc), .tr_pc(tr_pc), .csr_mepc(csr_mepc),
    .redir_pc(pc_if_redir_pc), .id_redir_t(id_redir_t), .tr_redir_t(tr_redir_t),
    .tr_cause(tr_cause), .mem_exc_cause(mem_exc_cause)
);
bind garuda_core_top cov_reach_top u_cov_reach_top (
    .clk(clk_i), .rst_n(rst_n_i),
    .ifid_s(pc_ifid_s), .ifid_f(pc_ifid_f), .idex_s(pc_idex_s), .idex_f(pc_idex_f),
    .mem_stall(mem_stall), .dsu_busy(ex_dsu_busy), .fwd_a_sel(fwd_a_sel),
    .irq_valid(clic_irq_valid_i), .mie(csr_mstatus_mie),
    .irq_level(clic_irq_level_i), .mil(csr_mil), .thresh(csr_mintthresh),
    .i_htrans(i_htrans_o), .i_haddr(i_haddr_o)
);
bind garuda_prefetch_buffer cov_const_pfb u_cov_const_pfb (
    .clk(clk_i), .rst_n(rst_n_i), .occupancy(occupancy), .wr_en(wr_en_i), .rd_en(rd_en_i)
);
bind csr_file cov_const_csr u_cov_const_csr (
    .clk(clk_i), .rst_n(rst_n_i), .mie_r(mie_r), .mepc_r(mepc_r)
);
bind d_port_ahb_master cov_const_dport u_cov_const_dport (
    .clk(clk_i), .rst_n(rst_n_i), .state(state)
);
bind garuda_iport_ahb_master cov_const_iport u_cov_const_iport (
    .clk(clk_i), .rst_n(rst_n_i),
    .inflight(inflight), .occ_after_pop(occ_after_pop), .occ_plus_landing(occ_plus_landing),
    .projected_occ(projected_occ), .addr_pc(addr_pc), .outstanding_pc(outstanding_pc)
);
`endif
