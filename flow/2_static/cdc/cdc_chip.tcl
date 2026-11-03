# =============================================================================
# cdc_chip.tcl - JasperGold CDC (clock and reset domain crossings) on the whole
# chip, garuda_chip_top. 1-TOPS item 3.15.
#
# Run from the repository root, in tcsh:
#   source /home/install/cshrc
#   /home/install/JASPER/bin/jg -allow_unsupported_OS -cdc -batch -no_jges -proj sim/cdc_chip flow/2_static/cdc/cdc_chip.tcl
#
# Two primary clocks enter the chip: refclk (500 MHz; clk_div makes aon_clk,
# hclk and pclk from it, one synchronous family) and tck (JTAG, asynchronous to
# everything). The only intended asynchronous crossing is dmi_cdc, inside
# block 12 (TRM section 2). Asynchronous input pins (UART rx, SPI slave,
# I2C, GPIO, boot_sel, JTAG) are synchronised where they enter.
# Results: sim/cdc_chip/reports/*.csv, summarised in flow/2_static/cdc/RESULTS.md.
# =============================================================================
clear -all
set FL rtl/soc/filelist_chip.f
set FILES [split [string trim [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $FL]] "\n"]
set INCS {}
foreach d [split [string trim [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $FL --incdirs]] " "] {
    if {$d ne ""} { lappend INCS +incdir+[string range $d 2 end] }
}
analyze -sv09 +define+SYNTHESIS +incdir+rtl/include +incdir+rtl/common {*}$INCS {*}$FILES
elaborate -top garuda_chip_top

# the two primary clocks, and the three clocks clk_div makes from refclk with
# flops (the tool does not follow a clock through a flop by itself). The refclk
# family is one synchronous group; tck is asynchronous to it.
clock refclk
clock tck
# a clock must be an input or a stopat: cut the divider outputs and clock them
stopat -env {u_core.u_clk_div.aon_clk_o u_core.u_clk_div.hclk_o u_core.u_clk_div.pclk_o}
clock u_core.u_clk_div.aon_clk_o
clock u_core.u_clk_div.hclk_o
clock u_core.u_clk_div.pclk_o
config_rtlds -clock -group -async {{refclk u_core.u_clk_div.aon_clk_o u_core.u_clk_div.hclk_o u_core.u_clk_div.pclk_o} {tck}}
# the external reset pin (active low); the internal resets come from reset_ctrl flops
config_rtlds -reset -async ext_rst_n -polarity low

check_cdc -clock_domain -find
check_cdc -pair -find
check_cdc -scheme -find
check_cdc -group -find
check_cdc -reset -find

set R sim/cdc_chip/reports
file mkdir $R
check_cdc -report domains    -file $R/domains.csv    -force
check_cdc -report pairs      -file $R/pairs.csv      -force
check_cdc -report schemes    -file $R/schemes.csv    -force
check_cdc -report violations -file $R/violations.csv -force
check_cdc -report reset_schemes -file $R/reset_schemes.csv -force
check_cdc -report clock_groups  -file $R/clock_groups.csv  -force
exit
