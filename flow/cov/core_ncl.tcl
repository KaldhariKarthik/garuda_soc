# core_ncl.tcl -- GENERATED: run the CORE Cadence coverage from NCLaunch
#   nclaunch -nokey -directory $PWD -cdslib $PWD/cds.lib -work worklib -input flow/cov/core_ncl.tcl
catch {exec bash flow/cov/core_cadence.sh >& sim/cov_core/ncl_run.log} res
puts $res
exit
