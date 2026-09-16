// =============================================================================
// filelist_clic.f -- tb_clic: Block 16 block-level testbench
//
// Top module: tb_clic
//
// RTL under test is rtl/clic/filelist.f exactly as it would be synthesised.
//
// No verification models. The CLIC's two interfaces are an APB slave port and
// the frozen core sideband, and the testbench drives both directly - an APB
// master BFM would add a layer between the test and the register it is trying
// to write, and the core side is a handful of wires, not a protocol.
// =============================================================================

-incdir rtl/clic

-f rtl/clic/filelist.f

tb/clic/tb_clic.sv
