# dma_ncl.tcl -- GENERATED: compile and elaborate (no licence-bound run) the DMA Cadence coverage from NCLaunch
#   nclaunch -nokey -directory $PWD -cdslib $PWD/cds.lib -work worklib -input flow/cov/dma_ncl.tcl
catch {exec bash flow/cov/dma_cadence.sh --compile-only >& sim/cov_dma/ncl_compile.log} res
puts $res
exit
