# dsu_ncl.tcl -- GENERATED: run the DSU Cadence coverage from NCLaunch
#   nclaunch -nokey -directory $PWD -cdslib $PWD/cds.lib -work worklib -input flow/cov/dsu_ncl.tcl
catch {exec bash flow/cov/dsu_cadence.sh >& sim/cov_dsu/ncl_run.log} res
puts $res
exit
