# =============================================================================
# garuda_rtl.sdc - timing constraints of garuda_chip_top (plan task 3.2).
#
# Two constraint files exist. This one is written against the RTL of
# garuda_chip_top for the static checks of the plan (task 3.2): every exception
# has its reason in exceptions.md and make sdc_check loads it in Genus. The
# other, flow/constraints/garuda.sdc, is the 28 nm draft written with the
# physical-design exploration (flow/constraints/asap7/). They are to be merged
# into one file before the rehearsal synthesis (task 3.6).
#
# Written 2026-10-14 against the RTL, before there is a pad ring or a clock tree.
# Every exception in this file has its reason in flow/constraints/exceptions.md,
# under the same number. Clock structure: GARUDA-CLKRST-SPEC-001 section 5.1 and
# rtl/clk_div/clk_div.v.
#
#   refclk 500 MHz --> t1 (/2) = aon_clk, and hclk at DIV2
#                       t1 --> t2 (/2) --> t3 (/2) --> t4 (/2)      ripple
#   hclk = t1, t2, t3 or t4, chosen by RSTCTL.DIVSEL through a glitch-free select
#   pclk = hclk / 2
#   tck  = the debugger's clock, unrelated to all of the above
#
# The select of hclk is a mode of the chip, not a path: one ratio is analysed at
# a time, set here by GARUDA_DIV (2, 4, 8 or 16). The default, 2, is the fastest
# and the one the chip resets to; it is the mode timing is closed in. The others
# are run to check hold and the paths between aon_clk and a slower hclk.
#
#   read_sdc flow/constraints/garuda_rtl.sdc                 hclk = refclk / 2
#   set GARUDA_DIV 8; read_sdc flow/constraints/garuda_rtl.sdc
#
# Check that it loads: ./scripts/run_sdc_check.sh [2|4|8|16]
# =============================================================================
if {![info exists GARUDA_DIV]} { set GARUDA_DIV 2 }

set T_REF   2.000                         ;# ns, 500 MHz
set T_HCLK  [expr {$T_REF * $GARUDA_DIV}]
set T_PCLK  [expr {$T_HCLK * 2}]
set T_TCK   50.000                        ;# ns, 20 MHz: the upper limit of tck (DEBUG section 5, PHYS pin 3)

# ---- 1. clocks ---------------------------------------------------------------
create_clock -name refclk -period $T_REF [get_ports refclk]
create_clock -name tck    -period $T_TCK [get_ports tck]

# The ripple chain: each flop divides the output of the one before it by two.
set T1 [get_pins -of_objects [get_cells u_core/u_clk_div/t1_q_reg] -filter {direction == out}]
set T2 [get_pins -of_objects [get_cells u_core/u_clk_div/t2_q_reg] -filter {direction == out}]
set T3 [get_pins -of_objects [get_cells u_core/u_clk_div/t3_q_reg] -filter {direction == out}]
set T4 [get_pins -of_objects [get_cells u_core/u_clk_div/t4_q_reg] -filter {direction == out}]
create_generated_clock -name aon_clk -source [get_ports refclk] -divide_by 2 $T1
create_generated_clock -name clk_t2  -source $T1 -divide_by 2 $T2
create_generated_clock -name clk_t3  -source $T2 -divide_by 2 $T3
create_generated_clock -name clk_t4  -source $T3 -divide_by 2 $T4

# The mode: the active select of the hclk multiplexer (exception E1).
set SEL [expr {$GARUDA_DIV == 2 ? 0 : $GARUDA_DIV == 4 ? 1 : $GARUDA_DIV == 8 ? 2 : 3}]
set_case_analysis [expr {$SEL & 1}]        [get_pins -of_objects [get_cells u_core/u_clk_div/sel_act_q_reg[0]] -filter {direction == out}]
set_case_analysis [expr {($SEL >> 1) & 1}] [get_pins -of_objects [get_cells u_core/u_clk_div/sel_act_q_reg[1]] -filter {direction == out}]

# hclk is the chosen one of the four, so it needs no clock of its own: at DIV2 the
# flops of the hclk domain are clocked by aon_clk, at DIV4 by clk_t2, and so on.
# pclk is hclk divided by two in one flop.
set HSRC [lindex [list $T1 $T2 $T3 $T4] $SEL]
create_generated_clock -name pclk -source $HSRC -divide_by 2 \
    [get_pins -of_objects [get_cells u_core/u_clk_div/pclk_q_reg] -filter {direction == out}]

# The pins that have no clock in common with the chip are timed against a clock of
# their own, io_async, which exists only in this file (exception E3).
create_clock -name io_async -period $T_PCLK

# Every clock made from refclk is synchronous to the others. tck is not (exception
# E2), and neither is io_async (exception E3).
set_clock_groups -asynchronous -name unrelated_clocks \
    -group [get_clocks {refclk aon_clk clk_t2 clk_t3 clk_t4 pclk}] \
    -group [get_clocks tck] \
    -group [get_clocks io_async]

# Before the clock tree: 5% of the period for setup (jitter and skew), 50 ps for hold.
foreach {c t} [list refclk $T_REF aon_clk [expr {2 * $T_REF}] clk_t2 [expr {4 * $T_REF}] clk_t3 [expr {8 * $T_REF}] \
                    clk_t4 [expr {16 * $T_REF}] pclk $T_PCLK tck $T_TCK io_async $T_PCLK] {
    set_clock_uncertainty -setup [expr {0.05 * $t}] [get_clocks $c]
    set_clock_uncertainty -hold  0.050              [get_clocks $c]
}

# ---- 2. pins without a clock in common with the chip (exception E3) -------------
# Inputs: the reset pin (released through synchronisers), the boot strap (read once
# after reset), and every serial or general-purpose input, each of which enters
# through a two-flop synchroniser and is slower than pclk by rule.
set ASYNC_IN  [get_ports {ext_rst_n boot_sel uart0_rx uart1_rx uart2_rx i2c_scl i2c_sda gpio0 gpio1 spis_sclk spis_mosi spis_cs_n}]
# Outputs whose receiver samples with its own clock or not at all.
set ASYNC_OUT [get_ports {uart0_tx uart1_tx uart2_tx pwm0 pwm1 pwm2 pwm3 gpio0 gpio1 i2c_scl i2c_sda spis_miso}]
set_input_delay  -clock io_async 0.0 $ASYNC_IN
set_output_delay -clock io_async 0.0 $ASYNC_OUT

# ---- 3. I/O budgets -------------------------------------------------------------
# JTAG: the debugger drives tms and tdi on the falling edge of tck and samples tdo on
# the rising edge. The board and the probe get 40% of the period on each side.
set_input_delay  -clock tck -clock_fall -max [expr {0.40 * $T_TCK}] [get_ports {tms tdi}]
set_input_delay  -clock tck -clock_fall -min 0.0                    [get_ports {tms tdi}]
set_output_delay -clock tck -max [expr {0.40 * $T_TCK}] [get_ports tdo]
set_output_delay -clock tck -min 0.0                    [get_ports tdo]

# SPI master: SCLK is made by the chip from pclk flops, at most pclk / 2 ([N-6.2]).
# The device gets 40% of a pclk period: its clock-to-output and the board on MISO,
# its setup and the board on MOSI and the chip selects.
set_output_delay -clock pclk -max [expr {0.40 * $T_PCLK}] [get_ports {spim_sclk spim_mosi spim_cs_flash_n spim_cs_imu_n}]
set_output_delay -clock pclk -min 0.0                     [get_ports {spim_sclk spim_mosi spim_cs_flash_n spim_cs_imu_n}]
set_input_delay  -clock pclk -max [expr {0.40 * $T_PCLK}] [get_ports spim_miso]
set_input_delay  -clock pclk -min 0.0                     [get_ports spim_miso]

# ---- 4. electrical assumptions until there is a pad ring (plan task 3.8) ----------
set_input_transition 0.200 [all_inputs]
set_load 0.050 [all_outputs]
