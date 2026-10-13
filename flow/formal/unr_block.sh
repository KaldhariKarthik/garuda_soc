#!/usr/bin/env bash
# =============================================================================
# unr_block.sh <gpio|pwm|timers|clic|crg> - are the coverage waivers of a closed
# block confirmed by JasperGold? (plan task 4.4)
#
#   source scripts/setup_env.sh
#   ./flow/formal/unr_block.sh gpio
#
# 1. IMC: merges the block's UVM runs (sim/uvm_<blk>/cov_work/scope/*) and writes
#    the detailed block and expression report, which gives each of IMC's block
#    numbers its source line.
# 2. JasperGold, coverage app: flow/formal/unr_block.tcl, all inputs free.
# 3. JasperGold, property app: flow/formal/vacuity_block.tcl, for the waivers that
#    say a property can never trigger or a cover can never happen.
# 4. tools/gen/unr_check.py compares the waivers of flow/cov/<blk>_exclusions.tcl
#    with all three and writes flow/formal/<blk>_unr.result.txt.
#
# Exit status 1 if a waived item is reachable. The UVM runs must exist (make uvm_<blk>).
# =============================================================================
set -u
BLK=${1:?usage: unr_block.sh <gpio|pwm|timers|clic|crg>}
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
# block | file list | top | clocks (name:factor) | active-low resets
case $BLK in
    gpio)   FL=rtl/gpio/filelist.f;       TOP=garuda_gpio_top; CLK="pclk_i:1";            RST="preset_n_i" ;;
    pwm)    FL=rtl/pwm/filelist.f;        TOP=garuda_pwm_top;  CLK="pclk_i:1";            RST="preset_n_i" ;;
    timers) FL=rtl/timers/filelist.f;     TOP=timers_top;      CLK="hclk_i:1 pclk_i:2";   RST="hreset_n_i preset_n_i ext_rst_n_i" ;;
    clic)   FL=rtl/clic/filelist.f;       TOP=clic_top;        CLK="hclk_i:1 pclk_i:2";   RST="hreset_n_i preset_n_i" ;;
    # the divider has no waiver in its design code; the reset controller with hclk at
    # half the always-on clock (DIV4) and pclk at half of hclk
    crg)    FL=rtl/reset_ctrl/filelist.f; TOP=reset_ctrl;      CLK="aon_clk_i:1 hclk_i:2 pclk_i:4"; RST="ext_rst_n_i" ;;
    *) echo "unknown block $BLK"; exit 2 ;;
esac
D=sim/jg_unr/$BLK
rm -rf "$D"; mkdir -p "$D"
RUNS=$(ls -d sim/uvm_$BLK/cov_work/scope/*/ 2> /dev/null | grep -v '/all/' | tr '\n' ' ')
[ -n "$RUNS" ] || { echo "no coverage runs under sim/uvm_$BLK: make uvm_$BLK first"; exit 2; }
cat > "$D/imc.tcl" <<IMC
merge $RUNS -out $D/imc_all -overwrite -message 1
load -run $D/imc_all
report -detail -inst $TOP... -metrics block:expression -both -out $D/imc_blocks.txt
exit
IMC
imc -exec "$D/imc.tcl" > "$D/imc.log" 2>&1
[ -s "$D/imc_blocks.txt" ] || { echo "IMC wrote no report: see $D/imc.log"; exit 2; }
GARUDA_UNR_FL=$FL GARUDA_UNR_TOP=$TOP GARUDA_UNR_CLK=$CLK GARUDA_UNR_RST=$RST GARUDA_UNR_OUT=$D \
    "${JG:-/home/install/JASPER/bin/jg}" -allow_unsupported_OS -cov -batch -no_jges -proj "$D/jgproject" flow/formal/unr_block.tcl > "$D/run.log" 2>&1
rc=$?
if [ $rc -ne 0 ] || ! grep -q '^==== END ====' "$D/run.log"; then
    echo "JasperGold did not finish (exit $rc): see $D/run.log"; grep -E '^ERROR' "$D/run.log" | head -5; exit 2
fi
VAC=
if grep -q -- ' -assertion ' ${WAIVERS:-flow/cov/${BLK}_exclusions.tcl}; then
    VAC=$D/vacuity.log
    GARUDA_UNR_FL=$FL GARUDA_UNR_TOP=$TOP GARUDA_UNR_CLK=$CLK GARUDA_UNR_RST=$RST GARUDA_UNR_WAIVERS=${WAIVERS:-flow/cov/${BLK}_exclusions.tcl} \
        "${JG:-/home/install/JASPER/bin/jg}" -allow_unsupported_OS -fpv -batch -no_jges -proj "$D/jgproject_fpv" flow/formal/vacuity_block.tcl > "$VAC" 2>&1
    grep -q '^==== END ====' "$VAC" || { echo "JasperGold (property app) did not finish: see $VAC"; grep -E '^ERROR' "$VAC" | head -5; exit 2; }
fi
{ echo "Block $BLK, top $TOP, clocks $CLK, resets $RST. JasperGold $(grep -m1 -oE 'Jasper Apps [0-9a-z.]+' "$D/run.log" | cut -d' ' -f3), $(date +%Y-%m-%d), tree $(git rev-parse --short HEAD)."
  python3 tools/gen/unr_check.py ${WAIVERS:-flow/cov/${BLK}_exclusions.tcl} "$D/run.log" "$D/imc_blocks.txt" $VAC; echo "rc=$?" > "$D/.rc"; } > ${RESULT:-flow/formal/${BLK}_unr.result.txt}
cat ${RESULT:-flow/formal/${BLK}_unr.result.txt}
. "$D/.rc"; exit $rc
