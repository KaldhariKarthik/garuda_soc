read design -sv -define SYNTHESIS sim/lec_inline/debug_module_old.v -golden
read design -sv -define SYNTHESIS rtl/debug/debug_module.v -revised
set system mode lec
add compared points -all
compare
report compare data -summary
exit -force
