# =============================================================================
# superlint.tcl - JasperGold Superlint on one block of GARUDA.
#
# Four settings come from the environment, so this file never needs editing:
#   TOP   the module to check               garuda_pwm_top
#   FL    its RTL file list                 rtl/pwm/filelist.f
#   CLK   its clock port                    pclk_i
#   RST   its ACTIVE-LOW reset port         preset_n_i
#   OUT   (optional) where results go       sim/superlint/pwm      default sim/superlint/$TOP
#
# Run from the repository root (see flow/2_static/superlint/README.md).
# =============================================================================
set TOP $::env(TOP)
set FL  $::env(FL)
set CLK $::env(CLK)
set RST $::env(RST)
set OUT sim/superlint/$TOP
if {[info exists ::env(OUT)]} { set OUT $::env(OUT) }
file mkdir $OUT

# 1. read the RTL. The project's file lists carry simulator switches (-sv, -incdir)
#    that JasperGold takes differently, so the list is expanded to plain file names
#    first, as every other flow does (scripts/expand_filelist.py). Inside the tool
#    exec must not see the tool's own libraries: env -u LD_LIBRARY_PATH.
#    +define+SYNTHESIS hides the simulation-only code (as for HAL).
set FILES [split [string trim [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $FL]] "\n"]
analyze -sv09 +define+SYNTHESIS +incdir+rtl/include +incdir+rtl/common {*}$FILES

# 2. build the design from the top module
elaborate -top $TOP

# 3. tell the formal engine about the clock and the reset. The reset is written as
#    the condition that means "in reset": an active-low port is !port.
clock $CLK
reset -expression [list "!$RST"]

# 4. the Superlint app: set it up, extract its checks, let the formal engine decide them
check_superlint -init
check_superlint -extract
prove -all

# 5. the results
check_superlint -report -file $OUT/superlint_report.txt -force
# the same, with every violation, its file and line (-detailed), and as CSV for a spreadsheet
check_superlint -report -violation -detailed -file $OUT/superlint_violations.txt -force
check_superlint -report -violation -file $OUT/superlint_violations.csv -csv -force
report -summary
exit
