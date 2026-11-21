#!/bin/bash
# run_chip_uvm.sh <name> <mode> <hex> [maxus] [blocks] [uvm test] - one program on the UVM chip bench
# (G6 6.1). Compiles once per tree into sim/chip_uvm/INCA_libs (pass COMPILE=1 to force),
# then runs (EXTRA = further plusargs, e.g. +SEED=3); PASS needs RESULT: PASSED, no *E/*F (bar IMPDLL), no [FAIL] or SVA-FAIL line.
# Run from the repository root, in an environment where irun 15.2 is licensed.
set -u
N=$1; MODE=$2; HEX=$3; MAXUS=${4:-2000}; BLOCKS=${5:-}; TEST=${6:-chip_base_test}
D=sim/chip_uvm; mkdir -p "$D/$N"
IRUN=/home/install/INCISIVE152/tools/bin/irun
COMMON="-64bit -ncerror CUVDSI -uvm -uvmhome CDNS-1.2 -nclibdirname $D/INCA_libs \
        -coverage all -covoverwrite -covworkdir $D/cov_work -covscope chip_uvm"
if [ "${COMPILE:-0}" = 1 ] || [ ! -d "$D/INCA_libs" ]; then
    rm -rf "${D:?}/INCA_libs"
    $IRUN $COMMON -f rtl/common/filelist_pkg.f -f tb/chip_uvm/filelist_chip_uvm.f -top tb_chip_uvm \
        -elaborate -l "$D/compile.log" < /dev/null > /dev/null 2>&1 || { echo "chip_uvm $N FAIL (compile, $D/compile.log)"; exit 1; }
fi
L="$D/$N/irun.log"
$IRUN $COMMON -R -covtest "$N" +UVM_TESTNAME="$TEST" +MODE="$MODE" +TEST="$HEX" +MAXUS="$MAXUS" ${BLOCKS:++BLOCKS=$BLOCKS} ${PLANT:++PLANT=$PLANT} ${EXTRA:-} -l "$L" < /dev/null > /dev/null 2>&1
if grep -q 'RESULT: PASSED' "$L" && [ "$(grep -E '\*[EF],' "$L" | grep -vc IMPDLL)" = 0 ] && ! grep -qE 'SVA-FAIL|^\[FAIL\]' "$L"; then
    echo "chip_uvm $N PASS"
else
    echo "chip_uvm $N FAIL ($L)"; exit 1
fi
