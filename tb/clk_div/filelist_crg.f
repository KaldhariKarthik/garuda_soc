// =============================================================================
// filelist_crg.f -- tb_crg: Blocks 22 and 23 block-level testbench
//
// Top module: tb_crg
//
// Both blocks in one testbench even though they are two independent modules
// with two independent filelists: the properties worth testing most are at the
// seam between them (the clock/reset bootstrap, and the bounded de-assertion
// skew), and testing each alone verifies both blocks and none of the coupling.
//
// No verification models are needed. These blocks have no bus interface, so
// there is no BFM to drive and nothing to stand in for - the testbench drives
// a reference clock and a reset pin, which is exactly what the pads do.
// =============================================================================

-f rtl/clk_div/filelist.f
-f rtl/reset_ctrl/filelist.f

tb/clk_div/tb_crg.sv
