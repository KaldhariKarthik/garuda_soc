// pulp-platform apb_gpio. Own library - see README.
// upstream carries no `timescale directive; supply one here rather than
// editing the file (D-22)
-timescale 1ns/1ps
-makelib pulp_gpio
  -sv
  rtl/third_party/pulp/apb_gpio/src/apb_gpio.sv
-endlib
