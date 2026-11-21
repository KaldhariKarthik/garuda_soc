// the UVM bench of the whole chip (G6 6.1): tb_chip with GARUDA_CHIP_UVM, the block
// environments it reuses, and the chip-level package and top
-f tb/soc/filelist_chip_cov.f
+define+GARUDA_CHIP_UVM
-incdir tb/uart/uvm
tb/common/dma_req_checker.sv
tb/uvm/apb/garuda_apb_if.sv
tb/uvm/apb/garuda_apb_pkg.sv
tb/uart/uvm/uart_reg_pkg.sv
tb/uart/uvm/uart_if.sv
tb/uart/uvm/uart_env_pkg.sv
-incdir tb/gpio/uvm
tb/gpio/uvm/gpio_reg_pkg.sv
tb/gpio/uvm/gpio_if.sv
tb/gpio/uvm/gpio_env_pkg.sv
-incdir tb/pwm/uvm
tb/pwm/uvm/pwm_reg_pkg.sv
tb/pwm/uvm/pwm_if.sv
tb/pwm/uvm/pwm_env_pkg.sv
-incdir tb/i2c/uvm
tb/i2c/uvm/i2c_reg_pkg.sv
tb/i2c/uvm/i2c_if.sv
tb/i2c/uvm/i2c_env_pkg.sv
-incdir tb/spi_slave/uvm
tb/spi_slave/uvm/spis_reg_pkg.sv
tb/spi_slave/uvm/spis_if.sv
tb/spi_slave/uvm/spis_env_pkg.sv
-incdir tb/timers/uvm
tb/timers/uvm/timers_reg_pkg.sv
tb/timers/uvm/timers_if.sv
tb/timers/uvm/timers_env_pkg.sv
-incdir tb/clic/uvm
tb/clic/uvm/clic_reg_pkg.sv
tb/clic/uvm/clic_src_if.sv
tb/clic/uvm/clic_env_pkg.sv
-incdir tb/clk_div/uvm
tb/clk_div/uvm/crg_reg_pkg.sv
tb/clk_div/uvm/crg_if.sv
tb/clk_div/uvm/crg_env_pkg.sv
-incdir tb/dma/uvm
tb/dma/uvm/dma_reg_pkg.sv
tb/dma/uvm/dma_if.sv
tb/dma/uvm/dma_env_pkg.sv
-incdir tb/chip_uvm
tb/chip_uvm/chip_ctl_if.sv
tb/chip_uvm/chip_uvm_pkg.sv
tb/chip_uvm/tb_chip_uvm.sv
