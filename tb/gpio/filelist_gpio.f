// tb_gpio: Block 19, two pins on a real bidirectional net
-f rtl/third_party/timescale.f
-f rtl/gpio/filelist.f
-sv
tb/common/garuda_apb_bfm.sv
tb/gpio/tb_gpio.sv
