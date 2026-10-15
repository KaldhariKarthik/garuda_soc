// dma_regs_pkg.sv -- GENERATED from Design_Docs/regs/dma_a.rdl by tools/gen/gen_regs_sv.py. Do not edit;
// change the RDL and regenerate. Register map of block 'dma' for plain-SV benches.
`timescale 1ns/1ps
package dma_regs_pkg;
    typedef enum int {REG_RW, REG_RO, REG_WO} reg_kind_e;
    localparam int DMA_NCH       = 6;
    localparam int DMA_CH_STRIDE = 'h20;
    localparam int DMA_NREGS     = 6;
    // per-channel registers, indexed 0..5 in address order
    localparam string       DMA_REG_NAME  [DMA_NREGS] = '{"CR", "SAR", "DAR", "CNT", "STAT", "ICLR"};
    localparam logic [11:0] DMA_REG_OFS   [DMA_NREGS] = '{12'h000, 12'h004, 12'h008, 12'h00C, 12'h010, 12'h014};
    localparam logic [31:0] DMA_REG_RESET [DMA_NREGS] = '{32'h0000_0040, 32'h0000_0000, 32'h0000_0000, 32'h0000_0000, 32'h0000_0000, 32'h0000_0000};
    localparam logic [31:0] DMA_REG_WMASK [DMA_NREGS] = '{32'h0000_01FF, 32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'h0000_FFFF, 32'h0000_0000, 32'h0000_0000};
    localparam logic [31:0] DMA_REG_W1C   [DMA_NREGS] = '{32'h0000_0000, 32'h0000_0000, 32'h0000_0000, 32'h0000_0000, 32'h0000_0000, 32'h0000_0003};
    localparam logic [31:0] DMA_REG_RMASK [DMA_NREGS] = '{32'h0000_01FF, 32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'h0000_FFFF, 32'h003F_FFFF, 32'h0000_0000};
    localparam reg_kind_e   DMA_REG_KIND  [DMA_NREGS] = '{REG_RW, REG_RW, REG_RW, REG_RW, REG_RO, REG_WO};
    localparam int DMA_CR_IDX = 0;
    localparam int DMA_SAR_IDX = 1;
    localparam int DMA_DAR_IDX = 2;
    localparam int DMA_CNT_IDX = 3;
    localparam int DMA_STAT_IDX = 4;
    localparam int DMA_ICLR_IDX = 5;
    // top-level registers
    localparam logic [11:0] DMA_GSTAT_ADDR  = 12'h100;
    localparam logic [31:0] DMA_GSTAT_RESET = 32'h0000_0000;
    localparam logic [31:0] DMA_GSTAT_WMASK = 32'h0000_0000;
    localparam logic [31:0] DMA_GSTAT_RMASK = 32'h003F_3F3F;
    localparam reg_kind_e   DMA_GSTAT_KIND  = REG_RO;
    // field positions
    localparam int DMA_CR_EN_LSB = 0, DMA_CR_EN_W = 1;
    localparam int DMA_CR_MODE_LSB = 1, DMA_CR_MODE_W = 2;
    localparam int DMA_CR_SINC_LSB = 3, DMA_CR_SINC_W = 1;
    localparam int DMA_CR_DINC_LSB = 4, DMA_CR_DINC_W = 1;
    localparam int DMA_CR_SIZE_LSB = 5, DMA_CR_SIZE_W = 2;
    localparam int DMA_CR_IE_COMP_LSB = 7, DMA_CR_IE_COMP_W = 1;
    localparam int DMA_CR_IE_ERR_LSB = 8, DMA_CR_IE_ERR_W = 1;
    localparam int DMA_SAR_ADDR_LSB = 0, DMA_SAR_ADDR_W = 32;
    localparam int DMA_DAR_ADDR_LSB = 0, DMA_DAR_ADDR_W = 32;
    localparam int DMA_CNT_COUNT_LSB = 0, DMA_CNT_COUNT_W = 16;
    localparam int DMA_STAT_REMAINING_LSB = 0, DMA_STAT_REMAINING_W = 16;
    localparam int DMA_STAT_ACTIVE_LSB = 16, DMA_STAT_ACTIVE_W = 1;
    localparam int DMA_STAT_COMPLETE_LSB = 17, DMA_STAT_COMPLETE_W = 1;
    localparam int DMA_STAT_ERROR_LSB = 18, DMA_STAT_ERROR_W = 1;
    localparam int DMA_STAT_ERRPHASE_LSB = 19, DMA_STAT_ERRPHASE_W = 3;
    localparam int DMA_ICLR_CLR_COMPLETE_LSB = 0, DMA_ICLR_CLR_COMPLETE_W = 1;
    localparam int DMA_ICLR_CLR_ERROR_LSB = 1, DMA_ICLR_CLR_ERROR_W = 1;
    localparam int DMA_GSTAT_ACTIVE_LSB = 0, DMA_GSTAT_ACTIVE_W = 6;
    localparam int DMA_GSTAT_COMPLETE_LSB = 8, DMA_GSTAT_COMPLETE_W = 6;
    localparam int DMA_GSTAT_ERROR_LSB = 16, DMA_GSTAT_ERROR_W = 6;
endpackage
