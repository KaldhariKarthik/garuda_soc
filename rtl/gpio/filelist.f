// GARUDA Block 19: GPIO = vendored PULP apb_gpio + GARUDA wrapper
-f rtl/third_party/pulp/apb_gpio/filelist.f
-sv
rtl/common/garuda_apb_shim.sv
rtl/common/garuda_sync_bit.sv
rtl/common/garuda_pad_sync.sv
rtl/common/garuda_apb_shim_sva.sv
rtl/gpio/garuda_gpio_top.sv
// properties, bound to garuda_gpio_top (empty under SYNTHESIS)
rtl/gpio/gpio_sva.sv
