// pulp-platform apb_gpio. Own library - see README.
// upstream carries no `timescale directive; the top-level filelist supplies
// one via rtl/third_party/timescale.f (D-22, and -timescale is once-only)
-makelib pulp_gpio
  -sv
  rtl/third_party/pulp/apb_gpio/src/apb_gpio.sv
-endlib
