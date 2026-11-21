#!/bin/bash
# sweep.sh - every program of tb/chip_uvm/programs.txt on the UVM chip bench (G6 6.1),
# one compile, then one run each (one at a time: irun runs are not started in parallel).
# Writes sim/chip_uvm/summary.txt; exit 1 if any program fails.
set -u
cd "$(dirname "$0")/../.."
S=sim/chip_uvm/summary.txt; mkdir -p sim/chip_uvm; : > "$S"
first=1; fail=0
while read -r n mode hex maxus blocks; do
    case "$n" in ''|\#*) continue ;; esac
    [ "$blocks" = "-" ] && blocks=""
    if [ $first = 1 ]; then c=1; first=0; else c=0; fi
    COMPILE=$c tb/chip_uvm/run_chip_uvm.sh "$n" "$mode" "$hex" "$maxus" "$blocks" | tee -a "$S" | grep -q PASS || fail=1
done < tb/chip_uvm/programs.txt
echo "chip_uvm: $(grep -c ' PASS$' "$S") PASS, $(grep -c ' FAIL ' "$S") FAIL" | tee -a "$S"
# negative controls: each planted defect must be caught while the program itself passes
nk=0; nc=0
while read -r pl prog chk; do
    case "$pl" in ''|\#*) continue ;; esac
    read -r _ mode hex maxus blocks < <(awk -v p="$prog" '$1==p' tb/chip_uvm/programs.txt)
    [ "$blocks" = "-" ] && blocks=""
    PLANT=$pl tb/chip_uvm/run_chip_uvm.sh "plant_$pl" "$mode" "$hex" "$maxus" "$blocks" > /dev/null
    L=sim/chip_uvm/plant_$pl/irun.log; nc=$((nc + 1))
    if grep -q "program rc=0" "$L" && grep -q "RESULT: FAILED" "$L" && grep -qE "UVM_ERROR .*\[$chk\]" "$L"; then
        echo "chip_uvm plant $pl KILLED by $chk (the program passed)" | tee -a "$S"; nk=$((nk + 1))
    else
        echo "chip_uvm plant $pl NOT KILLED ($L)" | tee -a "$S"; fail=1
    fi
done < tb/chip_uvm/plants.txt
echo "chip_uvm: $nk of $nc planted defects killed" | tee -a "$S"
exit $fail
