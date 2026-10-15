`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 1 : properties for mgarudactl (ERRATUM CORE-4, DN-CTL)
// core_ctl_sva.sv
//
// Each feature-disable bit really disables its feature (the timing-only side of
// t_core_ctl.S, which checks that architectural results never change):
//   a_ctl_bp       BP_DIS: no branch is predicted taken in ID
//   a_ctl_pf       PF_DIS: a new fetch starts only with nothing buffered or in flight
//   a_ctl_preempt  PREEMPT_DIS: no CLIC take while an interrupt level is active
//   a_ctl_cg       CG_DIS: the core clock gate never closes
// Portable subset, one cover per antecedent (Docs/handbook/H4_coding.md).
// Proven at whole-core level by tb/core/formal/core_trap.toml (fv_trap).
// =============================================================================
`ifdef FORMAL
  `define GARUDA_CTL_SVA
`elsif SYNTHESIS
`elsif __ICARUS__   // Icarus has no bind / assert property (same rule as the *_sva.sv files on main)
`else
  `define GARUDA_CTL_SVA
`endif

`ifdef GARUDA_CTL_SVA
module core_ctl_sva (
    input wire       clk,
    input wire       rst_n,
    input wire [3:0] ctl,
    input wire       predict_taken,
    input wire       clic_take_cond,
    input wire       clic_valid,
    input wire [7:0] mil,
    input wire       cg_en,
    input wire       quiescent
);
    a_ctl_bp: assert property (@(posedge clk) disable iff (!rst_n)
        !ctl[0] || !predict_taken)
        else $error("[SVA-FAIL] CORE-4: BP_DIS set but a branch was predicted taken");
    a_ctl_preempt: assert property (@(posedge clk) disable iff (!rst_n)
        !(ctl[2] && mil != 8'd0) || !clic_take_cond)
        else $error("[SVA-FAIL] CORE-4: PREEMPT_DIS set but a CLIC interrupt preempted level %0d", mil);
    a_ctl_cg: assert property (@(posedge clk) disable iff (!rst_n)
        !ctl[3] || cg_en)
        else $error("[SVA-FAIL] CORE-4: CG_DIS set but the core clock gate closed");

    c_ctl_bp:      cover property (@(posedge clk) disable iff (!rst_n) ctl[0]);
    c_ctl_preempt: cover property (@(posedge clk) disable iff (!rst_n) ctl[2] && mil != 8'd0 && clic_valid);
    c_ctl_cg:      cover property (@(posedge clk) disable iff (!rst_n) ctl[3] && quiescent);
endmodule

module iport_ctl_sva (
    input wire        clk,
    input wire        rst_n,
    input wire        pf_dis,
    input wire        fetch_issue,
    input wire [3:0]  projected_occ,
    input wire [1:0]  htrans,
    input wire [31:0] haddr
);
    // BUS-E: every fetch address phase is word-aligned (AHB-Lite: HADDR aligned
    // to HSIZE, and the I-port always fetches words)
    a_ihaddr_aligned: assert property (@(posedge clk) disable iff (!rst_n)
        !htrans[1] || (haddr[1:0] == 2'b00))
        else $error("[SVA-FAIL] BUS-E: I-port address phase at a misaligned HADDR %08x", haddr);
    a_ctl_pf: assert property (@(posedge clk) disable iff (!rst_n)
        !(pf_dis && fetch_issue) || (projected_occ == 4'd0))
        else $error("[SVA-FAIL] CORE-4: PF_DIS set but a fetch started with %0d buffered or in flight", projected_occ);
    c_ctl_pf: cover property (@(posedge clk) disable iff (!rst_n) pf_dis && fetch_issue);
endmodule

bind garuda_core_top core_ctl_sva u_ctl_sva (
    .clk           (clk_i),
    .rst_n         (rst_n_i),
    .ctl           (csr_ctl),
    .predict_taken (id_predict_taken),
    .clic_take_cond(clic_take_cond),
    .clic_valid    (clic_irq_valid_i),
    .mil           (csr_mil),
    .cg_en         (u_cg.en_i),
    .quiescent     (quiescent)
);
bind garuda_iport_ahb_master iport_ctl_sva u_ctl_sva (
    .clk          (clk_i),
    .rst_n        (rst_n_i),
    .pf_dis       (pf_dis_i),
    .fetch_issue  (fetch_issue_o),
    .projected_occ(projected_occ),
    .htrans       (i_htrans_o),
    .haddr        (i_haddr_o)
);
`endif
