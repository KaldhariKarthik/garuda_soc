// =============================================================================
// GARUDA SoC - core root clock gate, physical-design build (ASAP7 / ORFS)
//
// The physical flow reads this file in place of rtl/core/core_clk_gate.sv
// (flow/pd/asap7/config.mk), the way the FPGA build reads
// rtl/fpga/core_clk_gate_fpga.sv: same module name and ports, the library ICG
// instead of the behavioural latch. Before F4 (2026-11-17) the two lived in
// one file behind `ifdef GARUDA_ICG_CELL.
//
// OpenROAD-flow-scripts maps OPENROAD_CLKGATE to the platform cell through its
// CLKGATE_MAP_FILE (ASAP7: platforms/asap7/yoSys/cells_clkgate_R.v ->
// ICGx1_ASAP7_75t_R, latch_posedge_precontrol). That map is a plain wire
// (GCK = CK) unless OPENROAD_CLKGATE is defined, which would silently remove
// the gate, so a build without the define fails elaboration on the unresolved
// module below instead. en_i already carries the scan enable (the cell's
// ENA | SE). For the 28 nm library, the flow's map names the foundry ICG.
// =============================================================================

module core_clk_gate (
    input wire hclk,
    input wire en_i,
    output wire gclk_o
);
`ifndef OPENROAD_CLKGATE
    core_clk_gate_icg_requires_OPENROAD_CLKGATE_define u_missing_define ();
`endif
    OPENROAD_CLKGATE u_icg (.CK(hclk), .E(en_i), .GCK(gclk_o));
endmodule
