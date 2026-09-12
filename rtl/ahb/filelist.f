// =============================================================================
// GARUDA SoC - Block 6: AHB-Lite Interconnect
// filelist.f - synthesizable interconnect sources, bottom-up
//
// Top module: ahb_interconnect  (boundary per GARUDA-AHB-SPEC-001 Rev 2.0 Sec 5)
//
// Everything listed here is silicon RTL. rtl/ahb/ahb_mem_slave.v is NOT in
// this list and never will be: it is a verification model (it says so in its
// own header) and it predates this block - it has no HSEL and no HREADY input,
// so it cannot sit on this interconnect at all. The AHB-Lite slave models that
// can are in tb/ahb/.
// =============================================================================

-incdir rtl/ahb

// Combinational leaves
rtl/ahb/ahb_decoder.v
rtl/ahb/ahb_master_mux.v

// Sequential sub-blocks
rtl/ahb/ahb_arbiter.v
rtl/ahb/ahb_master_port.v
rtl/ahb/ahb_slave_mux.v
rtl/ahb/ahb_default_slave.v

// Block boundary
rtl/ahb/ahb_interconnect.v
