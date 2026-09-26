// tb_spis: Block 14 against an SPI master model
-f rtl/spi_slave/filelist.f
-sv
tb/common/garuda_apb_bfm.sv
tb/common/dma_req_checker.sv
tb/models/spi_master_model.sv
tb/spi_slave/tb_spis.sv
