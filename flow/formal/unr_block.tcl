# =============================================================================
# JasperGold coverage app, stimuli coverage: which code-coverage items of a block
# can never be hit, whatever its inputs do. Used to confirm the waivers of
# flow/cov/<blk>_exclusions.tcl that say "constant" or "unreachable" (plan task
# 4.4, block bar: "each unreachable waiver confirmed by JasperGold").
#
# Run it through flow/formal/unr_block.sh <block>, which sets the variables below, makes
# IMC's report of the same block and calls tools/gen/unr_check.py on the two.
#
#   GARUDA_UNR_FL    file list of the block
#   GARUDA_UNR_TOP   its top module
#   GARUDA_UNR_CLK   clocks as name:factor, the fastest with factor 1 ("hclk_i:1 pclk_i:2")
#   GARUDA_UNR_RST   active-low reset pins ("hreset_n_i preset_n_i")
#   GARUDA_UNR_OUT   directory for the summary
#
# Every other input of the block is free: any bus access, any pin level. The property
# modules (*_sva.sv) are left out, and SYNTHESIS is defined: the question is about
# the design that is built. JasperGold holds the resets off after the reset state,
# so an item in a reset branch comes out "unreachable, caused by reset": that is not
# a verdict, and the checker does not take it for one.
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
foreach c $clk {
    lassign [split $c :] name factor
    clock $name -factor $factor -phase 1
}
set rexp {}
foreach r $rst { lappend rexp "!$r" }
reset -expression {*}$rexp
check_cov -measure -type stimuli -time_limit 15m
check_cov -report -type stimuli -no_return -report_file $out/stimuli_summary.txt -force
# One line per item, with its instance and source line, for tools/gen/unr_check.py.
# (Not "unprocessed": with the checker side off, as here, that list is every item.)
foreach st {covered unreachable deadcode} {
    puts "==== ITEMS $st ===="
    check_cov -list -status $st
    foreach it [check_cov -list -status $st -silent] {
        puts "ITEM|$st|[dict get $it cover_item_type]|[dict get $it instance]|[dict get $it file]|[dict get $it source_location]|[dict get $it caused_by]|[dict get $it description]"
    }
}
puts "==== END ===="
exit
