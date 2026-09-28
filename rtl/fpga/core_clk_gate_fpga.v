`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA core root clock gate - FPGA substitute (KV260 prototype ONLY)
// rtl/fpga/core_clk_gate_fpga.v
//
// SAME MODULE NAME AND PORTS as rtl/core/core_clk_gate.v. Compiled instead of
// it by fpga/kv260/filelist_fpga.f.
//
// The ASIC model is a latch plus an AND gate. On an FPGA that is a gated
// clock built in LUTs: it glitches and has uncontrolled skew. BUFGCE with
// CE_TYPE "SYNC" is the device's glitch-free clock enable, which is the
// standard ICG replacement in ASIC prototyping. The enable is sampled against
// the rising edge of clk_i, and the gated clock stays on global routing.
//
// Fallback if the gate is ever suspected: build with CORE_CLK_GATE=0. The core
// then forces en_i high (garuda_core_top), and this becomes a free-running
// BUFG.
// =============================================================================
module core_clk_gate (
    input  wire clk_i,
    input  wire en_i,
    input  wire test_en_i,
    output wire gclk_o
);
    BUFGCE #(.CE_TYPE("SYNC")) u_bufgce (
        .I(clk_i), .CE(en_i | test_en_i), .O(gclk_o));
endmodule

`default_nettype wire
