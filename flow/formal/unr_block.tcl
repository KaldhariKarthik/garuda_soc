# =============================================================================
# JasperGold coverage app, stimuli coverage: which code-coverage items of a block
# can never be hit, whatever its inputs do. Used to confirm the waivers of
# flow/cov/<blk>_exclusions.tcl that say "constant" or "unreachable" (plan task
# 4.4, block bar: "each unreachable waiver confirmed by JasperGold").
#
# From the repository root, for the GPIO:
#   GARUDA_UNR_FL=rtl/gpio/filelist.f GARUDA_UNR_TOP=garuda_gpio_top \
#   GARUDA_UNR_CLK=pclk_i GARUDA_UNR_RST=preset_n_i GARUDA_UNR_OUT=sim/jg_unr/gpio \
#   jg -allow_unsupported_OS -cov -batch -no_jges -proj sim/jg_unr/gpio/jgproject flow/formal/unr_block.tcl
# then
#   python3 tools/gen/unr_check.py flow/cov/gpio_exclusions.tcl garuda_gpio_top sim/jg_unr/gpio/run.log
#
# Every input of the block is free: any bus access, any pin level. The property
# modules (*_sva.sv) are left out: the question is about the design.
# =============================================================================
set fl   $::env(GARUDA_UNR_FL)
set top  $::env(GARUDA_UNR_TOP)
set clk  $::env(GARUDA_UNR_CLK)
set rst  $::env(GARUDA_UNR_RST)
set out  $::env(GARUDA_UNR_OUT)
set incs {}
foreach d [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $fl --incdirs] { lappend incs "+incdir+[string range $d 2 end]" }
set srcs {}
foreach f [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $fl] { if {![string match *_sva.sv $f]} { lappend srcs $f } }
check_cov -init -model {statement branch expression toggle} -type stimuli -exclude_bind_hierarchies
analyze -sv09 +define+SYNTHESIS {*}$incs {*}$srcs
elaborate -top $top
clock $clk
reset -expression "!$rst"
check_cov -measure -type stimuli -time_limit 15m
check_cov -report -type stimuli -no_return -report_file $out/stimuli_summary.txt -force
# (not "unprocessed": with the checker side off, as here, that list is every item)
foreach st {covered unreachable deadcode} {
    puts "==== ITEMS $st ===="
    check_cov -list -status $st
}
puts "==== END ===="
exit
