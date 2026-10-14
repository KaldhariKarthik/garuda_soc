#!/usr/bin/env bash
# =============================================================================
# planted_defects.sh <block> - does the block's UVM environment fail when the RTL
# is wrong? (the planted-defect run of the block bar, plan WP4 and WP6)
#
#   source scripts/setup_env.sh
#   ./scripts/planted_defects.sh spis
#
# tb/<dir>/uvm/planted.txt lists the defects, one per line:
#     <RTL file> @@ <sed -E expression that plants the defect> @@ <what the defect is>
# For each one a copy of rtl/ and tb/ is made under sim/planted/<block>/, the
# expression is applied to the copy, and the register test, the directed test and
# two random seeds are run on it. A defect is CAUGHT when at least one of them
# fails; the first failing check is named. The tree itself is never changed.
#
# Writes tb/<dir>/uvm/planted.result.txt. Exit status 1 if a defect is not caught,
# if an expression changes nothing, or if the unchanged copy does not pass.
# =============================================================================
set -u
BLK=${1:?usage: planted_defects.sh <spis|i2c|uart|spim>}
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT=$PWD
case $BLK in
    spis) DIR=spi_slave;  TOP=tb_spis_uvm; DUT=garuda_spis_top ;;
    i2c)  DIR=i2c;        TOP=tb_i2c_uvm;  DUT=garuda_i2c_top ;;
    uart) DIR=uart;       TOP=tb_uart_uvm; DUT=garuda_uart_top ;;
    spim) DIR=spi_master; TOP=tb_spim_uvm; DUT=garuda_spim_top ;;
    *) echo "unknown block $BLK"; exit 2 ;;
esac
LIST=tb/$DIR/uvm/planted.txt
[ -f "$LIST" ] || { echo "no $LIST"; exit 2; }
IRUN=${IRUN152:-$(command -v irun)}
W=$ROOT/sim/planted/$BLK
rm -rf "$W"; mkdir -p "$W"
cp -r rtl tb "$W/"

# run_all <tag>: 0 if every test passes; prints the first failing test and check
run_all() {
    local tag=$1 t seed first=""
    ( cd "$W" && rm -rf INCA_libs cov_work
      for t in reg directed random:1 random:2; do
          seed=${t#*:}; [ "$seed" = "$t" ] && seed=1; t=${t%%:*}
          $IRUN -64bit -uvm -uvmhome CDNS-1.2 -f tb/$DIR/uvm/filelist_${BLK}_uvm.f -top $TOP +UVM_TESTNAME=${BLK}_${t}_test \
              -svseed $seed -nclibdirname INCA_libs -l ${tag}_${t}_$seed.log > /dev/null 2>&1
          if ! grep -q 'RESULT: PASSED' ${tag}_${t}_$seed.log || grep -q 'SVA-FAIL' ${tag}_${t}_$seed.log \
             || [ "$(grep -E '\*[EF],' ${tag}_${t}_$seed.log | grep -vc IMPDLL)" != 0 ]; then
              first=$(grep -m1 -oE 'SVA-FAIL\] [a-z_0-9]+' ${tag}_${t}_$seed.log | sed 's/SVA-FAIL. /property /')
              [ -n "$first" ] || first=$(grep -m1 -oE 'UVM_ERROR [^ ]+ @ [0-9]+: [^ ]+ \[[A-Za-z0-9_]+\]' ${tag}_${t}_$seed.log | sed -E 's/.*\[(.*)\]/check \1/')
              [ -n "$first" ] || first="no pass line"
              echo "${t} test, $first"
              exit 1
          fi
      done ) 
}

OUT=tb/$DIR/uvm/planted.result.txt
{ echo "Planted defects, block $BLK: $(date +%Y-%m-%d), tree $(git rev-parse --short HEAD)."
  echo "Each defect is planted in a copy of the RTL; the register test, the directed test and two"
  echo "random seeds are run on it (scripts/planted_defects.sh $BLK)."; echo; } > "$OUT"
bad=0
if first=$(run_all clean); then echo "unchanged RTL: all four runs pass" >> "$OUT"
else echo "unchanged RTL: FAILS ($first): nothing below means anything" >> "$OUT"; bad=1; fi
echo >> "$OUT"
n=0
while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    file=${line%%@@*}; rest=${line#*@@}; expr=${rest%%@@*}; what=${rest#*@@}
    file=$(echo $file); what=$(echo $what); expr=$(printf '%s' "$expr" | sed 's/^ *//; s/ *$//')
    n=$((n+1))
    cp "$ROOT/$file" "$W/$file.orig"
    sed -i -E "$expr" "$W/$file"
    if cmp -s "$W/$file" "$W/$file.orig"; then
        echo "$n. NOT PLANTED (the expression changed nothing): $what" >> "$OUT"; bad=1
    elif first=$(run_all d$n); then
        echo "$n. NOT CAUGHT: $what" >> "$OUT"; bad=1
    else
        echo "$n. caught by the $first: $what" >> "$OUT"
    fi
    mv "$W/$file.orig" "$W/$file"
done < "$LIST"
echo >> "$OUT"
[ $bad -eq 0 ] && echo "$n defects planted, $n caught." >> "$OUT" || echo "NOT CLEAN: see the lines above." >> "$OUT"
cat "$OUT"
exit $bad
