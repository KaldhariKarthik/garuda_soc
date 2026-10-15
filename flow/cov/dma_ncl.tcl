# dma_ncl.tcl -- GENERATED: run the DMA Cadence coverage from NCLaunch
#   nclaunch -nokey -directory $PWD -cdslib $PWD/cds.lib -work worklib -input flow/cov/dma_ncl.tcl
catch {exec bash flow/cov/dma_cadence.sh >& sim/cov_dma/ncl_run.log} res
puts $res
exit
