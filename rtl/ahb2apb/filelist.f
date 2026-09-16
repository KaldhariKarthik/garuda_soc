// =============================================================================
// GARUDA SoC - Block 8: AHB-to-APB Bridge
// filelist.f - synthesizable bridge sources, bottom-up
//
// Top module: ahb2apb_bridge  (boundary per GARUDA-BRG-SPEC-001 Rev 2.0 Sec. 5)
//
// Everything here is silicon RTL. tb/ahb/ahb2apb_bridge_model.v is NOT in this
// list and never will be: it is the verification model that stood in for this
// block before it existed, it is APB3 with no PSTRB, and it says so in its own
// header. It stays in tb/ as the thing that proved the SoC integration path
// before the real bridge was written.
// =============================================================================

-incdir rtl/ahb2apb

// Leaves
rtl/ahb2apb/ahb2apb_cdc.v
rtl/ahb2apb/ahb2apb_decoder.v

// Domain sequencers
rtl/ahb2apb/ahb2apb_hclk_fsm.v
rtl/ahb2apb/ahb2apb_pclk_fsm.v

// Block boundary
rtl/ahb2apb/ahb2apb_bridge.v
