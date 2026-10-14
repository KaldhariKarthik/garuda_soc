# ahb_ncl.tcl -- GENERATED: compile and elaborate (no licence-bound run) the AHB Cadence coverage from NCLaunch
#   nclaunch -nokey -directory $PWD -cdslib $PWD/cds.lib -work worklib -input flow/cov/ahb_ncl.tcl
catch {exec bash flow/cov/ahb_cadence.sh --compile-only >& sim/cov_ahb/ncl_compile.log} res
puts $res
exit
