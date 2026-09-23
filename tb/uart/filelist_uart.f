// tb_uart: Blocks 16/17/18 against a terminal model
-f rtl/third_party/timescale.f
-f rtl/uart/filelist.f
-sv
tb/common/garuda_apb_bfm.sv
tb/common/dma_req_checker.sv
tb/models/uart_model.sv
tb/uart/tb_uart.sv
