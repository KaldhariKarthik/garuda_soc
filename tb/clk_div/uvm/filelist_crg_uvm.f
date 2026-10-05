// Clock and reset UVM environment (blocks 22 and 23). Top: tb_crg_uvm
-incdir rtl/include
-incdir tb/clk_div/uvm
-f rtl/clk_div/filelist.f
-f rtl/reset_ctrl/filelist.f
tb/common/apb_checker.v
tb/uvm/apb/garuda_apb_if.sv
tb/uvm/apb/garuda_apb_pkg.sv
tb/clk_div/uvm/crg_reg_pkg.sv
tb/clk_div/uvm/crg_if.sv
tb/clk_div/uvm/crg_env_pkg.sv
tb/clk_div/uvm/tb_crg_uvm.sv
