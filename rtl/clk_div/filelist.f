// =============================================================================
// GARUDA SoC - Block 22: Clock Divider
// filelist.f - synthesizable clock divider source
//
// Top module: clk_div
//
// One file, no dependencies, no include directory. Blocks 22 and 23 share a
// specification (GARUDA-CRG-SPEC-001 Rev 2.0) but NOT an implementation: the
// spec is explicit that they have no common bus interface, no common register
// model and no common access semantics, and that an engineer implementing one
// should not need to read the other. Two independent filelists is that
// structure carried into the build.
// =============================================================================

rtl/clk_div/clk_div.v
