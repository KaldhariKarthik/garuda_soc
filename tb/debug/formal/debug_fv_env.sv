// =============================================================================
// debug_fv_env.sv -- formal environment of debug_top for the baseline proof (Track A
// plan 6A.5 step G0). SymbiYosys `multiclock on`: tck and hclk are free inputs, so they
// toggle independently (any ratio, any phase, either may stop). This baseline matches
// Karthik's JasperGold setup (flow/formal/debug/debug_fpv.tcl):
//   FD-1 reset: por_n and dm_rst_n low for the first RST_TICKS global steps (both clocks
//        driven, 7 rising edges each), then high; the clocks are free from then on.
//   The slave assumptions are debug_sva's own (assume_slave_error2, _okay_idle).
// The CDC proof (classes A-D of the plan) uses its own environment, with resets free.
// =============================================================================
`timescale 1ns/1ps
(* blackbox *) module debug_fv_env #(parameter integer RST_TICKS = 14) (
    input wire por_n_i, dm_rst_n_i, tck_i, hclk_i);
endmodule
bind debug_top debug_fv_env u_fv_env (.por_n_i(por_n_i), .dm_rst_n_i(dm_rst_n_i), .tck_i(tck_i), .hclk_i(hclk_i));
