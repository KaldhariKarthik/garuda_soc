// OpenCores I2C master bit/byte controllers (Richard Herveille, 2001).
// The APB register layer is ours: rtl/i2c/garuda_i2c_top.v (D-22).
// upstream carries no `timescale directive; the top-level filelist supplies
// one via rtl/third_party/timescale.f (D-22, and -timescale is once-only)
-makelib oc_i2c
  -incdir rtl/third_party/opencores/i2c/src
  -sv
  rtl/third_party/opencores/i2c/src/i2c_master_bit_ctrl.sv
  rtl/third_party/opencores/i2c/src/i2c_master_byte_ctrl.sv
-endlib
