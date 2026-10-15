# ahb2apb_ncl.tcl -- GENERATED: run the AHB2APB Cadence coverage from NCLaunch
#   nclaunch -nokey -directory $PWD -cdslib $PWD/cds.lib -work worklib -input flow/cov/ahb2apb_ncl.tcl
catch {exec bash flow/cov/ahb2apb_cadence.sh >& sim/cov_ahb2apb/ncl_run.log} res
puts $res
exit
