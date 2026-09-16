// =============================================================================
// filelist_ahb2apb.f -- tb_ahb2apb: Block 8 block-level testbench
//
// Top module: tb_ahb2apb
//
// RTL under test is rtl/ahb2apb/filelist.f exactly as it would be synthesised.
//
// tb/ahb/ahb2apb_bridge_model.v is deliberately NOT here. That file is the APB3
// stand-in that preceded this block; including it alongside the real bridge
// would be a duplicate-module elaboration error, which is the correct outcome.
// =============================================================================

-incdir rtl/ahb2apb

-f rtl/ahb2apb/filelist.f

// verification model for the APB peripherals (Blocks 10-15, 18-21)
tb/ahb2apb/apb_slave_model.v

tb/ahb2apb/tb_ahb2apb.sv
