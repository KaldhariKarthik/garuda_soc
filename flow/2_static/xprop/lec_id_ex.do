read design -sv -define SYNTHESIS sim/lec_inline/id_ex_old.v -golden
read design -sv -define SYNTHESIS rtl/core/id_ex.v -revised
set system mode lec
add compared points -all
compare
report compare data -summary
exit -force
