// OpenCores I2C master bit/byte controllers (Richard Herveille, 2001).
// The APB register layer is ours: rtl/i2c/garuda_i2c_top.v (D-22).
// upstream carries no `timescale directive; supply one here rather than
// editing the file (D-22)
-timescale 1ns/1ps
-makelib oc_i2c
  -incdir rtl/third_party/opencores/i2c/src
  -sv
  rtl/third_party/opencores/i2c/src/i2c_master_bit_ctrl.sv
  rtl/third_party/opencores/i2c/src/i2c_master_byte_ctrl.sv
-endlib
