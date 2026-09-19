`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 1 : core root clock gate
// core_clk_gate.v
//
// Spec: GARUDA-CORE-SPEC-001 Rev 3.0 §7.7 [N-7.28]..[N-7.31], §9 [N-9.3]; R11
//
// A standard latch-based integrated clock gate: the enable is captured while
// the clock is LOW, so the gated clock can only ever produce whole pulses.
// Its enable is ~pipe_ctrl.quiescent and nothing else ([N-7.29]).
//
// `GARUDA_ICG_CELL` : instantiate the library ICG here (PD handoff).
// otherwise         : behavioural model. The latch below is the intended ICG
//                     latch, not an inference accident; it is the only latch
//                     in the design and synthesis must map this module to the
//                     library ICG cell (dont_touch / set_clock_gating_check).
// test_en_i forces the clock on for scan.
// =============================================================================

module core_clk_gate (
    input  wire clk_i,
    input  wire en_i,
    input  wire test_en_i,
    output wire gclk_o
);

`ifdef GARUDA_ICG_CELL
    // e.g. ICGx1 u_icg (.CK(clk_i), .E(en_i), .SE(test_en_i), .ECK(gclk_o));
    initial begin
        $display("core_clk_gate: GARUDA_ICG_CELL set but no cell is instantiated");
        $finish;
    end
`else
    reg en_l;
    always @(clk_i or en_i or test_en_i)
        if (!clk_i) en_l = en_i | test_en_i;
    assign gclk_o = clk_i & en_l;
`endif

endmodule

`default_nettype wire
