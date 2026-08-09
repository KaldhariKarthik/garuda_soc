// =============================================================================
// filelist_dma_top.f -- DMA block-level TB against the real rtl/dma sources.
//
// Top module: tb_dma_top
//
// The AHB slave model is verification-only and lives in tb/dma. Nothing under
// rtl/dma depends on it, so this filelist and rtl/dma/filelist.f compile the
// same design sources - a pass here is a statement about the silicon RTL.
// =============================================================================

-incdir rtl/dma

rtl/dma/dma_cdc_sync.v
rtl/dma/dma_cdc_pulse.v
rtl/dma/dma_cdc_gray.v
rtl/dma/dma_apb_slave.v
rtl/dma/dma_reg_bank.v
rtl/dma/dma_arbiter.v
rtl/dma/dma_channel_fsm.v
rtl/dma/dma_ahb_master.v
rtl/dma/dma_irq_agg.v
rtl/dma/dma_top.v

-sv
tb/dma/dma_ahb_slave_model.sv
tb/dma/tb_dma_top.sv
