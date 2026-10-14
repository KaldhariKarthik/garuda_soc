# core_ncl.tcl -- GENERATED: compile and elaborate (no licence-bound run) the CORE Cadence coverage from NCLaunch
#   nclaunch -nokey -directory $PWD -cdslib $PWD/cds.lib -work worklib -input flow/cov/core_ncl.tcl
catch {exec bash flow/cov/core_cadence.sh --compile-only >& sim/cov_core/ncl_compile.log} res
puts $res
exit
