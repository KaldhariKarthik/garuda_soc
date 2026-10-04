// Mirafra's UVM environment for the PULP SPI master, compiled against GARUDA's
// integrated block. This is Mirafra's sim/verif_compile.f with its paths made
// absolute through MIRAFRA_SPIM and its hdl_top replaced by GARUDA's.
//   export MIRAFRA_SPIM=~/external/mirafra/pulpino__spi_master__ip_verification
+incdir+${MIRAFRA_SPIM}/src/dv/hvl_top/test/sequences/master_sequences/
+incdir+${MIRAFRA_SPIM}/src/dv/hvl_top/test/sequences/slave_sequences/
+incdir+${MIRAFRA_SPIM}/src/dv/hvl_top/test/sequences/master_sequences/reg_sequences/
+incdir+${MIRAFRA_SPIM}/src/dv/hvl_top/test/virtual_sequences/
+incdir+${MIRAFRA_SPIM}/src/dv/hvl_top/apb_master_agent/
+incdir+${MIRAFRA_SPIM}/src/dv/hvl_top/spi_slave_agent/
+incdir+${MIRAFRA_SPIM}/src/dv/hvl_top/env/virtual_sequencer/
+incdir+${MIRAFRA_SPIM}/src/dv/hvl_top/env/
+incdir+${MIRAFRA_SPIM}/src/dv/hvl_top/test/
+incdir+${MIRAFRA_SPIM}/src/dv/systemRDL
+incdir+${MIRAFRA_SPIM}/src/dv/systemRDL/output
${MIRAFRA_SPIM}/src/dv/globals/apb_master_global_pkg.sv
${MIRAFRA_SPIM}/src/dv/globals/spi_slave_global_pkg.sv
${MIRAFRA_SPIM}/src/dv/globals/pulpino_spi_master_ip_global_pkg.sv
${MIRAFRA_SPIM}/src/dv/hvl_top/apb_master_agent/apb_master_pkg.sv
${MIRAFRA_SPIM}/src/dv/hvl_top/spi_slave_agent/spi_slave_pkg.sv
${MIRAFRA_SPIM}/src/dv/systemRDL/output/spi_master_defines_pkg.svh
${MIRAFRA_SPIM}/src/dv/systemRDL/output/spi_master_uvm_pkg.sv
${MIRAFRA_SPIM}/src/dv/hvl_top/test/sequences/master_sequences/reg_sequences/apb_reg_seq_pkg.sv
${MIRAFRA_SPIM}/src/dv/hvl_top/test/sequences/master_sequences/apb_master_seq_pkg.sv
${MIRAFRA_SPIM}/src/dv/hvl_top/test/sequences/slave_sequences/spi_slave_seq_pkg.sv
${MIRAFRA_SPIM}/src/dv/hvl_top/env/pulpino_spi_master_ip_env_pkg.sv
${MIRAFRA_SPIM}/src/dv/hvl_top/test/virtual_sequences/pulpino_spi_master_ip_virtual_seq_pkg.sv
${MIRAFRA_SPIM}/src/dv/hvl_top/test/pulpino_spi_master_ip_test_pkg.sv
${MIRAFRA_SPIM}/src/dv/hdl_top/assertions/fifo_assertions.sv
${MIRAFRA_SPIM}/src/dv/hdl_top/apb_if/apb_if.sv
${MIRAFRA_SPIM}/src/dv/hdl_top/spi_if/spi_if.sv
${MIRAFRA_SPIM}/src/dv/hdl_top/apb_master_agent_bfm/apb_master_agent_bfm.sv
${MIRAFRA_SPIM}/src/dv/hdl_top/apb_master_agent_bfm/apb_master_driver_bfm.sv
${MIRAFRA_SPIM}/src/dv/hdl_top/apb_master_agent_bfm/apb_master_monitor_bfm.sv
${MIRAFRA_SPIM}/src/dv/hdl_top/spi_slave_agent_bfm/spi_slave_agent_bfm.sv
${MIRAFRA_SPIM}/src/dv/hdl_top/spi_slave_agent_bfm/spi_slave_driver_bfm.sv
${MIRAFRA_SPIM}/src/dv/hdl_top/spi_slave_agent_bfm/spi_slave_monitor_bfm.sv
tb/spi_master/uvm_mirafra/hdl_top.sv
${MIRAFRA_SPIM}/src/dv/hvl_top/hvl_top.sv
