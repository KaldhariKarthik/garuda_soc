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
# ---- resets: only the pin is declared. reset_ctrl makes hreset_n, preset_n,
# core_rst_n, dm_rst_n and ext_hrst_n from it with asynchronous assertion and a
# two-flop release in each domain (flow/2_static/rdc_review.md); declaring those
# nets as resets would cut them (stopat) and hide the synchronisers, so the tool
# traces them from the pin instead.
config_rtlds -reset -async ext_rst_n -polarity low

# ---- pins: the clock each one belongs to
set ASYNC_IN {boot_sel uart0_rx uart1_rx uart2_rx spim_miso spis_cs_n spis_sclk spis_mosi i2c_scl i2c_sda gpio0 gpio1}
config_rtlds -port $ASYNC_IN -clock async_to_all          ;# synchronised where they enter
config_rtlds -port {tms tdi tdo} -clock tck                ;# JTAG
config_rtlds -port {pwm0 pwm1 pwm2 pwm3 spim_sclk spim_mosi spim_cs_flash_n spim_cs_imu_n uart0_tx uart1_tx uart2_tx spis_miso} -clock u_core.u_clk_div.pclk_o
# the memory arrays the tool black-boxes run on hclk
foreach m {u_brom.u_array u_isram.u_array u_dsram.g_bank[0].u_array u_dsram.g_bank[1].u_array u_dsram.g_bank[2].u_array u_dsram.g_bank[3].u_array} {
    config_rtlds -port [list u_core.u_soc.$m.mem.read_address_0 u_core.u_soc.$m.mem.read_data_0] -clock u_core.u_clk_div.hclk_o
}

# ---- the DMI handshake (DEBUG [N-7.16]): the payload is held stable from the
# request toggle until the acknowledge comes back, so it needs no synchroniser.
set D u_core.u_soc.u_debug
# request, tck -> hclk: address, data and op of the DTM
foreach d {req_addr_o req_data_o req_op_o} {
    check_cdc -scheme -add handshake -map [list [list data $D.u_dtm.$d] [list sreq $D.u_dtm.req_tgl_o] \
        [list dreq $D.u_cdc.req_s\[2\]] [list dack $D.u_cdc.ack_tgl_o] [list sack $D.u_cdc.ack_s\[1\]]]
}
# response, hclk -> tck: the Debug Module's read data
check_cdc -scheme -add handshake -map [list [list data $D.u_dm.rdata_o] [list sreq $D.u_cdc.ack_tgl_o] \
    [list dreq $D.u_cdc.ack_s\[1\]] [list dack $D.u_dtm.req_tgl_o] [list sack $D.u_cdc.req_s\[2\]]]

check_cdc -clock_domain -find
check_cdc -pair -find
check_cdc -scheme -find
check_cdc -group -find
check_cdc -reset -find

# ---- waivers: each class read by hand (flow/2_static/cdc/RESULTS.md). A waiver
# names a narrow pattern, so anything new still shows as a violation.
proc waive {tag what pattern why} {
    check_cdc -waiver -add -filter [check_cdc -filter -add -tag $tag $what $pattern] -comment $why
}
# RDC into storage with no reset: contents are undefined after any reset by design
foreach u {u_core.u_soc.u_dsram.g_bank*.u_array.rdata u_core.u_soc.u_isram.u_array.rdata u_core.u_soc.u_brom.u_array.rdata} {
    waive RDC_RS_DFRS -destination_unit $u "memory array: no reset by design; contents undefined after a reset (MEM spec); a write needs a valid AHB data phase, which a reset ends"
}
waive RDC_RS_DFRS -destination_unit {u_core.u_soc.u_core.u_id.u_regfile.mem*} "register file: no reset by design (CORE 4); its write enable comes from mem_wb.reg_write, which resets to 0"
waive RDC_RS_DFRS -destination_unit {u_core.u_i2c.u_byte.bit_controller.d*} "vendored OpenCores I2C: dout and dscl_oen are one-cycle delayed copies without reset; they follow their reset source within one pclk"
# resets taken from the pin without a release synchroniser, by design
waive RST_NO_SYNC -occurrence {u_core.u_clk_div.*} "clk_div is reset by the raw pin so that clocks exist before any synchronised reset (D-14); the divider phase after release is arbitrary and nothing else is out of reset (1024-cycle stretch)"
waive RST_NO_SYNC -occurrence {u_core.u_reset_ctrl.*} "the reset generator itself: at release each flop's D equals its reset value because the synchronised pin (ext_sync_q) still reads held for two cycles"
waive RST_NO_SYNC -occurrence {u_core.u_soc.u_debug.u_*} "JTAG side (TAP, DTM, dmi_cdc ack): power-on reset from the pin, tck stopped at power-up; the TAP is also reset by five TMS-high clocks (IEEE 1149.1)"
# reset structure inside reset_ctrl and the core, already reviewed
waive RST_RS_CONV -occurrence {u_core.u_reset_ctrl.*} "the request logic of reset_ctrl combines the synchronised pin with the other reset causes; its outputs are re-registered (hrst_q, core_q, dm_q)"
waive RST_RS_CONV -occurrence {u_core.u_soc.u_core.rst_n_i} "core_rst_n AND hartreset_n inside the core: CORE (N-7.33), HAL GLTASR waiver"
waive RST_RS_RIDP -occurrence {u_core.u_reset_ctrl.hrst_q*} "hreset_n is data on purpose: preset_n releases after it (prst_q chain) and the watchdog request flop is cleared by it (rdc_review.md crossings 1 and 2)"
# clock-domain items
waive CDC_PR_FOUT -occurrence {u_core.u_soc.u_debug.u_dtm.req_*} "DMI payload fans out to several Debug Module registers; it is stable for the whole handshake (DEBUG (N-7.16))"
foreach pin {i2c_scl i2c_sda gpio0 gpio1} {
    waive CDC_NO_SYNC -occurrence $pin "bidirectional pin: the pclk output drive into the pad is not an on-chip crossing; the input side is synchronised in the shim (NDFF, passed)"
}
waive CNV_ST_CONV -occurrence {u_core.u_gpio.u_shim.irqstat_q} "per-pin interrupt status: each pin is synchronised and recorded in its own bit; a one-cycle skew between pins changes nothing"
waive CNV_ST_CONV -occurrence {u_core.u_soc.u_bridge.u_fsm.rdata_o*} "APB read data mux: one window is selected per read, so bits synchronised in different peripherals never meet in one value"
waive CNV_ST_CONV -occurrence {u_core.g_spis.u_spis.u_core.*} "SPI slave oversamples sclk, mosi and cs in pclk; SCLK <= pclk/6 (SPIS (N-7.1a)) keeps mosi stable around the detected sclk edge despite the skew between synchronisers"

set R sim/cdc_chip/reports
file mkdir $R
check_cdc -report domains    -file $R/domains.csv    -force
check_cdc -report pairs      -file $R/pairs.csv      -force
check_cdc -report schemes    -file $R/schemes.csv    -force
check_cdc -report violations -file $R/violations.csv -force
check_cdc -report reset_schemes -file $R/reset_schemes.csv -force
check_cdc -report clock_groups  -file $R/clock_groups.csv  -force
check_cdc -report waivers       -file $R/waivers.csv       -force
exit
