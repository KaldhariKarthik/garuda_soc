// =============================================================================
// GARUDA SoC - Block 16: CLIC
// filelist.f - synthesizable CLIC sources, bottom-up
//
// Top module: clic_top  (boundary per GARUDA-CLIC-SPEC-001 Rev 2.0 Sec. 5)
//
// Everything here is silicon RTL. Note that this block has no verification
// model to replace: before it existed, tb/soc/tb_soc_ahb.sv simply tied the
// core's clic_irq_i low and delivered no interrupts at all, which is why the
// SoC testbench could pass while the entire interrupt path was unexercised.
// =============================================================================

-incdir rtl/clic

// Leaves
rtl/clic/clic_source_cond.v
rtl/clic/clic_arbiter.v
rtl/clic/clic_present.v

// Configuration port
rtl/clic/clic_apb_regs.v

// Block boundary
rtl/clic/clic_top.v
