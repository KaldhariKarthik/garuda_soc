# dsu_ncl.tcl -- GENERATED: compile and elaborate (no licence-bound run) the DSU Cadence coverage from NCLaunch
#   nclaunch -nokey -directory $PWD -cdslib $PWD/cds.lib -work worklib -input flow/cov/dsu_ncl.tcl
catch {exec bash flow/cov/dsu_cadence.sh --compile-only >& sim/cov_dsu/ncl_compile.log} res
puts $res
exit
