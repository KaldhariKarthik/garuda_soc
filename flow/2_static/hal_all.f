// HAL with its whole default rule set (zero-waiver F4, 2026-11-16): nothing is switched off.
//   irun -hal -64bit -f rtl/soc/filelist_chip.f -top garuda_chip_top -define SYNTHESIS \
//        -nclibdirname sim/hal_zero/INCA_libs -l sim/hal_zero/hal.log -f flow/2_static/hal_all.f
// The result is judged by tools/hal_zero.py against flow/2_static/hal_exceptions.tsv.
-sv
