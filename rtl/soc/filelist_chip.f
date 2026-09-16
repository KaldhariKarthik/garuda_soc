// =============================================================================
// filelist_chip.f -- garuda_chip_top: the whole chip, clocks and resets included
//
// Top module: garuda_chip_top
//
// This is the list a synthesis run should use for "the SoC". It is
// filelist_soc.f plus Blocks 22 and 23, and it is the only build in which the
// design generates its own clocks rather than receiving them.
//
// Note for STA: the clock relationship is MODE-DEPENDENT and each mode must be
// constrained as its own scenario (CRG Sec. 5.2).
//   normal   - pclk is a generated ÷2 of the hclk source
//   fallback - hclk and pclk are the SAME 100 MHz net; do NOT declare ÷2 here
// In neither mode may hclk and pclk be declared asynchronous clock groups: the
// bridge and the CLIC have both chosen not to instantiate synchronisers on the
// strength of the synchronous relationship, and declaring the clocks unrelated
// leaves real setup paths in those blocks unchecked.
// =============================================================================

-f rtl/soc/filelist_soc.f

// Blocks 22 / 23
-f rtl/clk_div/filelist.f
-f rtl/reset_ctrl/filelist.f

// Chip boundary
rtl/soc/garuda_chip_top.v
