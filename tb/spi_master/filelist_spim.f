// tb_spim: Block 13 against the SPI flash model
-f rtl/third_party/timescale.f
-f rtl/spi_master/filelist.f
-sv
tb/common/garuda_apb_bfm.sv
tb/common/dma_req_checker.sv
tb/models/spi_flash_model.sv
tb/spi_master/tb_spim.sv
