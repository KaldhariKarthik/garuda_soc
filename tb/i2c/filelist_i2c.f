// tb_i2c: Block 15 against a slave model on an open-drain bus
-f rtl/third_party/timescale.f
-f rtl/i2c/filelist.f
-sv
tb/common/garuda_apb_bfm.sv
tb/common/dma_req_checker.sv
tb/models/i2c_slave_model.sv
tb/i2c/tb_i2c.sv
