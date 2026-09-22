// pulp-platform apb_spi_master + the axi_spi_master datapath it shares.
// Own library: PULP's generic module names collide with GARUDA's (rtl/clk_div).
// upstream carries no `timescale directive; supply one here rather than
// editing the file (D-22)
-timescale 1ns/1ps
-makelib pulp_spim
  -sv
  rtl/third_party/pulp/axi_spi_master/src/spi_master_clkgen.sv
  rtl/third_party/pulp/axi_spi_master/src/spi_master_fifo.sv
  rtl/third_party/pulp/axi_spi_master/src/spi_master_rx.sv
  rtl/third_party/pulp/axi_spi_master/src/spi_master_tx.sv
  rtl/third_party/pulp/axi_spi_master/src/spi_master_controller.sv
  rtl/third_party/pulp/apb_spi_master/src/spi_master_apb_if.sv
  rtl/third_party/pulp/apb_spi_master/src/apb_spi_master.sv
-endlib
