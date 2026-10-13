# =============================================================================
# JasperGold coverage app, stimuli coverage: which code-coverage items of the GPIO
# block can never be hit, whatever the inputs do.
# Confirms (or not) the waivers of flow/cov/gpio_exclusions.tcl that say
# "unreachable": since the shim's register map the vendored register file is
# selected only at the ten GARUDA registers (plan tasks 0.9 and 4.4).
#
# From the repository root:
#   jg -allow_unsupported_OS -cov -batch -no_jges -proj sim/jg_unr/jgproject flow/formal/gpio/gpio_unr.tcl
# Every input of garuda_gpio_top is free: any bus access, any pad level.
# =============================================================================
set fl rtl/gpio/filelist.f
set incs {}
foreach d [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $fl --incdirs] { lappend incs "+incdir+[string range $d 2 end]" }
set srcs {}
foreach f [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $fl] { if {![string match *_sva.sv $f]} { lappend srcs $f } }
check_cov -init -model {statement branch expression toggle} -type stimuli -exclude_bind_hierarchies
analyze -sv09 +define+SYNTHESIS {*}$incs {*}$srcs
elaborate -top garuda_gpio_top
clock pclk_i
reset -expression {!preset_n_i}
check_cov -measure -type stimuli -time_limit 15m
puts "==== COVER ITEMS BY STATUS ===="
foreach st {covered unreachable deadcode unprocessed} { puts [format "%-12s %d" $st [llength [check_cov -list -status $st]]] }
check_cov -report -type stimuli -no_return -report_file sim/jg_unr/gpio_stimuli.txt -force
puts "==== END ===="
exit
