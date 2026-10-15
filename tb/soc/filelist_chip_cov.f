// tb_chip with the functional coverage of the chip (chip_cov) and of the core (garuda_cov,
// garuda_core_cov_ext): the coverage runs of the chip programs (flow/regress/run_test.sh chip_*).
-f tb/soc/filelist_chip.f
-sv
tb/cov/garuda_cov.sv
tb/cov/garuda_core_cov_ext.sv
tb/soc/chip_cov.sv
tb/common/garuda_apb_shim_cov.sv
