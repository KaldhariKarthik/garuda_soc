`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 1 : simulation/formal properties for trap_ctrl
// trap_ctrl_sva.sv
//
// Bound into every trap_ctrl instance, so every simulation that contains the
// core (ISA, sanity, directed, chip) evaluates them, and the same file is
// proven by SymbiYosys at whole-core level (tb/core/formal/core_trap.toml).
//
// Written in the portable subset (Docs/handbook/H4_coding.md): every property
// is a boolean `!(a) || (b)` sampled on the clock, and anything that spans a
// cycle uses a small helper flop. yosys-slang (the SBY front end) rejects
// `|->`, so this form is what lets one file run in Verilator, SBY and Xcelium.
// Every assert has a cover on its antecedent (VACUOUS is a finding, H6).
//
// Properties
//   T-13  a MEM-stage access fault is always entered, even with an MRET in EX:
//         a_mem_fault_entered, a_mem_fault_no_mret, a_mem_fault_vectors
//   T-14  the WFI sleep latch is never armed while a D-port transfer is
//         outstanding (H2), so an older fault can never be entered with the
//         core asleep: a_no_wfi_arm_in_h2, a_no_fault_trap_while_asleep
//   T-12  the level encoding csr_file relies on: a CLIC interrupt arrives with
//         its level (>= 1), the machine timer with 0: a_clic_level_nonzero,
//         a_mti_level_zero
//   TC-1  no interrupt is taken while the WFI hold is active (audit F-01)
//   TC-3  ID/EX is never squashed while H2 holds (ERRATUM T-9 rule, audit F-01)
//   T-17  an EX-point exception needs an instruction in EX: a_ex_exc_needs_instr
//   T-18  an instruction-address-misaligned trap reports the misaligned
//         target, never an aligned address: a_misfetch_tval_misaligned
// =============================================================================

// Guard: simulation (no SYNTHESIS) and formal. Yosys defines SYNTHESIS when it
// reads a design, so a plain `ifndef SYNTHESIS would silently drop every
// property from the formal model (seen 2026-10-11: a "pass" with 0 asserts).
// The formal flow passes -DFORMAL (tools/run/garuda_fv.py).
`ifdef FORMAL
  `define GARUDA_TRAP_SVA
`elsif SYNTHESIS
`else
  `define GARUDA_TRAP_SVA
`endif

`ifdef GARUDA_TRAP_SVA
module trap_ctrl_sva (
    input wire        clk,
    input wire        rst_n,
    input wire        mem_exc_valid,      // MEM-point access fault this cycle
    input wire        h2,                 // D-port transfer outstanding
    input wire        idex_is_system,
    input wire [31:0] idex_instr,
    input wire        wfi_active,         // sleep latch
    input wire        wfi_hold,
    input wire        trap_enter,
    input wire        is_interrupt,
    input wire        mret,
    input wire        redirect_valid,
    input wire [31:0] redirect_target,
    input wire [31:0] mtvec,
    input wire        squash_id_ex,
    input wire        clic_take,
    input wire [7:0]  clic_level,
    input wire        idex_valid,         // EX holds a real instruction
    input wire [31:0] trap_cause,
    input wire [31:0] trap_tval
);
    wire is_mret = idex_is_system & (idex_instr == 32'h30200073);
    wire is_wfi  = idex_is_system & (idex_instr == 32'h10500073);

    // ---- T-13 -------------------------------------------------------------
    a_mem_fault_entered: assert property (@(posedge clk) disable iff (!rst_n)
        !mem_exc_valid || trap_enter)
        else $error("[SVA-FAIL] T-13: MEM-stage access fault not entered");
    a_mem_fault_no_mret: assert property (@(posedge clk) disable iff (!rst_n)
        !mem_exc_valid || !mret)
        else $error("[SVA-FAIL] T-13: MRET popped in the cycle of an older access fault");
    a_mem_fault_vectors: assert property (@(posedge clk) disable iff (!rst_n)
        !mem_exc_valid || (redirect_valid && redirect_target == {mtvec[31:2], 2'b00}))
        else $error("[SVA-FAIL] T-13: access fault did not redirect to mtvec");

    // ---- T-14 -------------------------------------------------------------
    // at an edge where H2 holds and the latch is clear, the latch must still
    // be clear after that edge
    reg h2_unarmed_q;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) h2_unarmed_q <= 1'b0;
        else        h2_unarmed_q <= h2 & ~wfi_active;
    a_no_wfi_arm_in_h2: assert property (@(posedge clk) disable iff (!rst_n)
        !(h2_unarmed_q && wfi_active))
        else $error("[SVA-FAIL] T-14: WFI sleep armed while a D-port transfer was outstanding");
    a_no_fault_trap_while_asleep: assert property (@(posedge clk) disable iff (!rst_n)
        !(mem_exc_valid && trap_enter && wfi_active))
        else $error("[SVA-FAIL] T-14: access fault entered with the WFI sleep latch set");

    // ---- TC-1 / TC-3 (audit F-01 contract, proven unbounded on b90b481) ----
    a_tc1_no_int_while_held: assert property (@(posedge clk) disable iff (!rst_n)
        !(is_interrupt && wfi_hold))
        else $error("[SVA-FAIL] TC-1: interrupt taken while the WFI hold is active");
    a_tc3_no_squash_in_h2: assert property (@(posedge clk) disable iff (!rst_n)
        !(squash_id_ex && h2))
        else $error("[SVA-FAIL] TC-3: ID/EX squashed while a D-port transfer is outstanding");

    // ---- T-12 encoding ------------------------------------------------------
    a_clic_level_nonzero: assert property (@(posedge clk) disable iff (!rst_n)
        !clic_take || (clic_level != 8'd0))
        else $error("[SVA-FAIL] T-12: a CLIC interrupt was taken at level 0");
    a_mti_level_zero: assert property (@(posedge clk) disable iff (!rst_n)
        !(is_interrupt && !clic_take) || (clic_level == 8'd0))
        else $error("[SVA-FAIL] T-12: the machine-timer interrupt carried a CLIC level");

    // ---- T-17 (and T-4): an EX-point exception needs an instruction in EX -------
    // A bubble carries no exception. Before the fix a fetch-fault bit left on a
    // bubble raised cause 1 again after every redirect (endless trap loop).
    a_ex_exc_needs_instr: assert property (@(posedge clk) disable iff (!rst_n)
        !(trap_enter && !is_interrupt && !mem_exc_valid) || idex_valid)
        else $error("[SVA-FAIL] T-17: an EX-point exception was taken from a bubble");

    // ---- T-18: cause 0 reports the misaligned target -------------------------
    // IALIGN = 32 (no C), so the target of a cause-0 trap has bits [1:0] != 0.
    // Before the fix a JAL's mtval was pc+4 (aligned) whenever its bit fields,
    // read as a branch compare, said "not taken".
    a_misfetch_tval_misaligned: assert property (@(posedge clk) disable iff (!rst_n)
        !(trap_enter && !is_interrupt && trap_cause == 32'd0) || (trap_tval[1:0] != 2'b00))
        else $error("[SVA-FAIL] T-18: instruction-address-misaligned trap with an aligned mtval %08x", trap_tval);

    // ---- antecedent covers --------------------------------------------------
    c_fetch_fault:        cover property (@(posedge clk) disable iff (!rst_n)
                              trap_enter && !is_interrupt && trap_cause[3:0] == 4'd1);
    c_misfetch:           cover property (@(posedge clk) disable iff (!rst_n)
                              trap_enter && !is_interrupt && trap_cause == 32'd0);
    c_mem_fault:          cover property (@(posedge clk) disable iff (!rst_n) mem_exc_valid);
    c_mem_fault_with_mret: cover property (@(posedge clk) disable iff (!rst_n) mem_exc_valid && is_mret);
    c_h2_with_wfi_in_ex:  cover property (@(posedge clk) disable iff (!rst_n) h2 && is_wfi && !wfi_active);
    c_wfi_armed:          cover property (@(posedge clk) disable iff (!rst_n) wfi_active);
    c_int_taken:          cover property (@(posedge clk) disable iff (!rst_n) is_interrupt);
    c_squash_id_ex:       cover property (@(posedge clk) disable iff (!rst_n) squash_id_ex);
endmodule

bind trap_ctrl trap_ctrl_sva u_trap_sva (
    .clk            (clk_i),
    .rst_n          (rst_n_i),
    .mem_exc_valid  (mem_exc_valid_i),
    .h2             (mem_stall_i),
    .idex_is_system (idex_is_system_i),
    .idex_instr     (idex_instr_i),
    .wfi_active     (wfi_active),
    .wfi_hold       (wfi_hold_o),
    .trap_enter     (trap_enter_o),
    .is_interrupt   (is_interrupt_o),
    .mret           (mret_o),
    .redirect_valid (trap_redirect_valid_o),
    .redirect_target(trap_redirect_target_o),
    .mtvec          (mtvec_i),
    .squash_id_ex   (trap_squash_id_ex_o),
    .clic_take      (clic_take_o),
    .clic_level     (clic_level_o),
    .idex_valid     (idex_valid_i),
    .trap_cause     (trap_cause_o),
    .trap_tval      (trap_tval_o)
);
`endif
