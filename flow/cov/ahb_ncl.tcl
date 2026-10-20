# ahb_ncl.tcl -- GENERATED: run the AHB Cadence coverage from NCLaunch
#   nclaunch -nokey -directory $PWD -cdslib $PWD/cds.lib -work worklib -input flow/cov/ahb_ncl.tcl
catch {exec bash flow/cov/ahb_cadence.sh >& sim/cov_ahb/ncl_run.log} res
puts $res
exit
