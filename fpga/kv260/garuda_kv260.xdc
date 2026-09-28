## =============================================================================
## GARUDA on KV260 - constraints
## Part: xck26-sfvc784-2LV-c (K26 commercial SOM, KV260 carrier)
## =============================================================================

## ---- PMOD J2 (HDA, 3.3 V) ---------------------------------------------------
## Pin map from the KV260 carrier. CHECK AGAINST UG1089 BEFORE WIRING ANYTHING
## to the header. With nothing plugged in it doesn't matter (outputs and
## pulled inputs only).
##   J2.1 H12  J2.2 E10  J2.3 D10  J2.4 C11      (top row)
##   J2.7 B10  J2.8 E12  J2.9 D11  J2.10 B11     (bottom row)
set_property -dict {PACKAGE_PIN H12 IOSTANDARD LVCMOS33 PULLTYPE PULLUP}   [get_ports i2c_scl]
set_property -dict {PACKAGE_PIN E10 IOSTANDARD LVCMOS33 PULLTYPE PULLUP}   [get_ports i2c_sda]
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33 PULLTYPE PULLDOWN} [get_ports gpio0]
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS33 PULLTYPE PULLDOWN} [get_ports gpio1]
set_property -dict {PACKAGE_PIN B10 IOSTANDARD LVCMOS33} [get_ports pwm0]
set_property -dict {PACKAGE_PIN E12 IOSTANDARD LVCMOS33} [get_ports pwm1]
set_property -dict {PACKAGE_PIN D11 IOSTANDARD LVCMOS33} [get_ports pwm2]
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33} [get_ports pwm3]

## ---- fan (on) --------------------------------------------------------------
set_property -dict {PACKAGE_PIN A12 IOSTANDARD LVCMOS33} [get_ports fan_en_b]

## Slow pads, no timing relationship we care about
set_false_path -to   [get_ports {pwm* gpio* i2c_* fan_en_b}]
set_false_path -from [get_ports {gpio* i2c_*}]

## ---- clocks ----------------------------------------------------------------
## pl_clk0 is constrained by the PS IP. The MMCM, BUFGCE_DIV /1 and /2 clocks
## are derived automatically. hclk and pclk are one synchronous family.
##
## TCK: a GPIO register bit promoted to a BUFG. It is asynchronous to every
## other clock, and the host changes TMS/TDI in a separate AXI write from the
## TCK edge. 10 MHz is a ceiling only, since the host bit-bang is far slower.
create_clock -name tck -period 100.000 [get_pins u_core/u_bufg_tck/O]
set_clock_groups -asynchronous -group [get_clocks tck]

## PS domain <-> chip domain. The only crossings are:
##   ctrl (AXI GPIO ch1): host-paced over many microseconds. ext_rst_n goes
##     into GARUDA's own reset synchronisers, and TMS/TDI are stable around
##     the TCK edges (separate writes).
##   stat (AXI GPIO ch2): the host re-reads it, and a one-read-stale value is
##     harmless.
##   UART: asynchronous serial, oversampled on both ends.
## pl_clk0 feeds the MMCM, so Vivado would otherwise time these crossings as
## synchronous. They are asynchronous by construction, so cut them.
set_clock_groups -asynchronous \
    -group [get_clocks clk_pl_0] \
    -group [get_clocks -include_generated_clocks -of_objects [get_pins u_core/u_mmcm/CLKOUT0]]

## ---- bitstream --------------------------------------------------------------
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
