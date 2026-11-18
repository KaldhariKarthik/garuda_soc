// =============================================================================
// GARUDA SoC - Block 1 : core root clock gate
// core_clk_gate.v
//
// Spec: GARUDA-CORE-SPEC-001 Rev 3.0 Sec.7.7 [N-7.28]..[N-7.31], Sec.9 [N-9.3];
// R11
//
// A standard latch-based integrated clock gate: the enable is captured while
// the clock is LOW, so the gated clock can only ever produce whole pulses.
// Its enable is ~pipe_ctrl.quiescent and nothing else ([N-7.29]).
//
// The behavioural model: the latch below is the intended ICG latch, not an
// inference accident; it is the only latch in the design. The physical flow
// reads flow/pd/asap7/core_clk_gate_icg.sv in place of this file (the library
// ICG), the FPGA build rtl/fpga/core_clk_gate_fpga.sv (a BUFGCE); F4
// (2026-11-17) took the `ifdef GARUDA_ICG_CELL out of this file.
// The enable arrives already ORed with the scan enable (the cell's ENA | SE),
// so this module holds the latch and the AND and nothing else (HAL CLKGNP).
// =============================================================================

module core_clk_gate (
    input wire hclk,
    input wire en_i,
    output wire gclk_o
);
    timeunit 1ns;
    timeprecision 1ps;

    // the latch is open while the clock is low
    wire hclk_low = ~hclk;
    reg  en_l;
    always_latch begin : l_en
        if (hclk_low) begin
            en_l <= en_i;
        end
    end
    assign gclk_o = hclk & en_l;

endmodule
