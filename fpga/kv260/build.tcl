# =============================================================================
# GARUDA on KV260 - one-shot Vivado build
#
#   cd <repo>
#   make -C sw fpga                                  # bootrom.hex + test images
#   vivado -mode batch -source fpga/kv260/build.tcl [-tclargs <jobs>]
#
# Output in fpga/kv260/out/:
#   garuda.bit, garuda.bit.bin (for the Linux fpga_manager / xmutil),
#   timing.rpt, util.rpt, and garuda.xsa (the hardware handoff, if needed)
#
# Sources come from rtl/soc/filelist_chip.f through scripts/expand_filelist.py,
# the same list every simulator and Genus uses. The only differences are
# three substitutions, and nothing else in the source list changes:
#   rtl/clk_div/clk_div.v        -> rtl/fpga/clk_div_fpga.v
#   rtl/core/core_clk_gate.v     -> rtl/fpga/core_clk_gate_fpga.v
#   *_sva.sv                     -> dropped (bind-only assertions)
# =============================================================================
set jobs 8
if {[llength $argv] > 0} { set jobs [lindex $argv 0] }

set repo [file normalize [file join [file dirname [info script]] .. ..]]
set here [file join $repo fpga kv260]
set out  [file join $here out]
set part xck26-sfvc784-2LV-c
cd $repo
file mkdir $out

set brom [file join $repo sw build bootrom.hex]
if {![file exists $brom]} {
    error "missing $brom - run 'make -C sw fpga' first"
}

proc latest {vlnv} {
    set d [lsort -dictionary [get_ipdefs -all ${vlnv}:*]]
    if {[llength $d] == 0} { error "IP $vlnv not found in this Vivado" }
    return [lindex $d end]
}

# ---- project -----------------------------------------------------------------
create_project -force garuda_kv260 [file join $here prj] -part $part
set_property target_language Verilog [current_project]

# ---- RTL ---------------------------------------------------------------------
set srcs [exec python3 scripts/expand_filelist.py rtl/soc/filelist_chip.f]
set incs [exec python3 scripts/expand_filelist.py rtl/soc/filelist_chip.f --incdirs]
set keep {}
foreach f $srcs {
    if {[string match *_sva.sv $f]}               continue
    if {$f eq "rtl/clk_div/clk_div.v"}            continue
    if {$f eq "rtl/core/core_clk_gate.v"}         continue
    lappend keep [file join $repo $f]
}
foreach f {clk_div_fpga.v core_clk_gate_fpga.v garuda_fpga_core.v garuda_kv260_top.v} {
    lappend keep [file join $repo rtl fpga $f]
}
add_files -norecurse $keep
set idirs {}
foreach i $incs { lappend idirs [file join $repo [string range $i 2 end]] }
set_property include_dirs $idirs [current_fileset]
# Vivado predefines SYNTHESIS, but say it explicitly: the SRAM backdoor tasks
# and $display checkers sit under `ifndef SYNTHESIS.
set_property verilog_define {SYNTHESIS} [current_fileset]
puts "GARUDA: [llength $keep] RTL files, [llength $idirs] include dirs"

add_files -fileset constrs_1 -norecurse [file join $here garuda_kv260.xdc]
set_property used_in_synthesis false [get_files garuda_kv260.xdc]

# ---- PS block design ---------------------------------------------------------
create_bd_design garuda_ps

set ps [create_bd_cell -type ip -vlnv [latest xilinx.com:ip:zynq_ultra_ps_e] ps]
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__M_AXI_GP2 {0} \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH {128} \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
] $ps

set gpio [create_bd_cell -type ip -vlnv [latest xilinx.com:ip:axi_gpio] gpio]
# ctrl resets to 0x30: GARUDA held in reset, boot_sel=1, uart0 loopback
set_property -dict [list \
    CONFIG.C_IS_DUAL {1} \
    CONFIG.C_GPIO_WIDTH {32}  CONFIG.C_ALL_OUTPUTS {1}  CONFIG.C_DOUT_DEFAULT {0x00000030} \
    CONFIG.C_GPIO2_WIDTH {32} CONFIG.C_ALL_INPUTS_2 {1} \
] $gpio

set uart [create_bd_cell -type ip -vlnv [latest xilinx.com:ip:axi_uartlite] uart]
set_property -dict [list CONFIG.C_BAUDRATE {115200}] $uart

set sc  [create_bd_cell -type ip -vlnv [latest xilinx.com:ip:smartconnect] sc]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] $sc

set rst [create_bd_cell -type ip -vlnv [latest xilinx.com:ip:proc_sys_reset] rst]

connect_bd_net [get_bd_pins ps/pl_clk0] \
    [get_bd_pins ps/maxihpm0_fpd_aclk] [get_bd_pins sc/aclk] \
    [get_bd_pins gpio/s_axi_aclk] [get_bd_pins uart/s_axi_aclk] \
    [get_bd_pins rst/slowest_sync_clk]
connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins rst/ext_reset_in]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] \
    [get_bd_pins sc/aresetn] [get_bd_pins gpio/s_axi_aresetn] [get_bd_pins uart/s_axi_aresetn]

connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_FPD] [get_bd_intf_pins sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc/M00_AXI] [get_bd_intf_pins gpio/S_AXI]
connect_bd_intf_net [get_bd_intf_pins sc/M01_AXI] [get_bd_intf_pins uart/S_AXI]

create_bd_port -dir O -type clk pl_clk0
set_property CONFIG.FREQ_HZ [get_property CONFIG.FREQ_HZ [get_bd_pins ps/pl_clk0]] [get_bd_ports pl_clk0]
connect_bd_net [get_bd_pins ps/pl_clk0] [get_bd_ports pl_clk0]
create_bd_port -dir O -type rst pl_resetn0
connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_ports pl_resetn0]

create_bd_port -dir O -from 31 -to 0 ctrl_o
connect_bd_net [get_bd_pins gpio/gpio_io_o] [get_bd_ports ctrl_o]
create_bd_port -dir I -from 31 -to 0 stat_i
connect_bd_net [get_bd_ports stat_i] [get_bd_pins gpio/gpio2_io_i]
create_bd_port -dir I uart_rxd
connect_bd_net [get_bd_ports uart_rxd] [get_bd_pins uart/rx]
create_bd_port -dir O uart_txd
connect_bd_net [get_bd_pins uart/tx] [get_bd_ports uart_txd]

assign_bd_address
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps/Data]] {
    set r [get_property range $seg]
    if {[string match -nocase *gpio* $seg]} { set_property offset 0xA0000000 $seg; set_property range 64K $seg }
    if {[string match -nocase *uart* $seg]} { set_property offset 0xA0010000 $seg; set_property range 64K $seg }
}
foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps/Data]] {
    puts "GARUDA: addr [get_property offset $seg] [get_property range $seg] $seg"
}

validate_bd_design
save_bd_design
set bd [get_files garuda_ps.bd]
generate_target all $bd
add_files -norecurse [make_wrapper -files $bd -top]

# ---- top -----------------------------------------------------------------------
set_property top garuda_kv260_top [current_fileset]
set_property generic "BROM_INIT_FILE=\"$brom\"" [current_fileset]
update_compile_order -fileset sources_1

# ---- synth / impl / bitstream -----------------------------------------------------
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "synth_1 failed - see [file join $here prj] synth_1/runme.log" }

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "impl_1 failed - see impl_1/runme.log" }

open_run impl_1
report_timing_summary -max_paths 20 -file [file join $out timing.rpt]
report_utilization               -file [file join $out util.rpt]
report_clocks                    -file [file join $out clocks.rpt]
report_cdc -details              -file [file join $out cdc.rpt]

set bit [glob [file join $here prj garuda_kv260.runs impl_1 *.bit]]
file copy -force $bit [file join $out garuda.bit]
write_cfgmem -force -format BIN -interface SMAPx32 -disablebitswap \
    -loadbit "up 0x0 [file join $out garuda.bit]" [file join $out garuda.bit.bin]
write_hw_platform -fixed -force -include_bit [file join $out garuda.xsa]

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "================================================================="
puts "GARUDA KV260 build done:  WNS = $wns ns   WHS = $whs ns"
puts "  [file join $out garuda.bit.bin]"
if {$wns < 0 || $whs < 0} { puts "  *** TIMING NOT MET - do not trust this bitstream ***" }
puts "================================================================="
