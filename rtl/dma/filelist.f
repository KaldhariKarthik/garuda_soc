// =============================================================================
// GARUDA SoC - Block 9: DMA Controller
// filelist.f - synthesizable DMA sources, bottom-up
//
// Top module: dma_top   (boundary frozen by GARUDA-DMA-SPEC-001 Rev 2.0 Sec 5.7)
//
// Everything listed here is silicon RTL. There is no verification-only code in
// rtl/dma - the AHB slave and APB master models used by tb_dma_top live under
// tb/dma/ and are never compiled into a synthesis run.
// =============================================================================

-incdir rtl/dma

// CDC primitives (leaf, no dependencies)
rtl/dma/dma_cdc_sync.v
rtl/dma/dma_cdc_pulse.v
rtl/dma/dma_cdc_gray.v

// Datapath / control sub-blocks
rtl/dma/dma_apb_slave.v
rtl/dma/dma_reg_bank.v
rtl/dma/dma_arbiter.v
rtl/dma/dma_channel_fsm.v
rtl/dma/dma_ahb_master.v
rtl/dma/dma_irq_agg.v

// Block boundary
rtl/dma/dma_top.v
