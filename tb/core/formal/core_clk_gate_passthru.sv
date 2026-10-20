// core_clk_gate_passthru.sv -- FORMAL-ONLY abstraction of rtl/core/core_clk_gate.v.
// SymbiYosys (single-clock mode) cannot model the latch ICG's derived clock
// (gclk = clk & en_l). This behaves like the design's own CLK_GATE == 0 build
// (garuda_core_top.v:154 enables the gate permanently): the core keeps clocking
// while quiescent and is held by its WFI hold instead. Properties are sampled on
// the ungated clk_i every cycle, so no violation BEFORE the first sleep can be
// hidden; a counterexample after a sleep must be replayed in simulation.
`timescale 1ns/1ps
module core_clk_gate (
    input  wire clk_i,
    input  wire en_i,
    input  wire test_en_i,
    output wire gclk_o
);
    assign gclk_o = clk_i;
endmodule
