// G0: Conformal LEC hello-world - RTL against itself.
read design -sv -define SYNTHESIS flow/signoff/g0/hello.sv -golden
read design -sv -define SYNTHESIS flow/signoff/g0/hello.sv -revised
set system mode lec
add compared points -all
compare
report compare data -summary
exit -force
