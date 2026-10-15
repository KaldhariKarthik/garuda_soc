#!/usr/bin/env bash
# =============================================================================
# run_uvm_local.sh -- the UVM environments under Verilator, no licence needed.
#
#   ./scripts/run_uvm_local.sh all            every environment
#   ./scripts/run_uvm_local.sh clic timers    some of them
#   ./scripts/run_uvm_local.sh list
#   SEEDS=5 SEED0=100 ./scripts/run_uvm_local.sh clic
#
# The same tests as `make uvm_<env>` (flow/mk/common.mk run_uvm): the register
# test and the directed test at seed 1, then the random test at SEEDS seeds,
# each judged the same way -- "RESULT: PASSED", no UVM_ERROR or UVM_FATAL, no
# [FAIL] or SVA-FAIL line. What it does NOT give is coverage: Verilator
# collects no functional coverage of covergroups, so the IMC numbers and the
# closure of each environment still come from `make uvm_<env>` on xrun.
#
# Needs: Verilator 5 (scripts/setup_open_tools.sh) and a UVM library that
# Verilator can compile. The default is CHIPS Alliance's uvm-verilator, the
# IEEE 1800.2-2020 library with Verilator fixes:
#     git clone https://github.com/chipsalliance/uvm-verilator ~/external/uvm-verilator
# (UVM_HOME=<dir with uvm_pkg.sv> to use another). Work: sim/uvm_local/<env>/.
#
# MEMORY. Verilator turns uvm_pkg into very large C++ files. With one
# compiler per CPU (-j 0) a 16-CPU WSL with 7.4 GB ran out of memory and
# crashed, twice (2026-10-15). With -j 2 one build peaks at about 2.3 GB
# resident (/usr/bin/time -v, CLIC). So: UVM_JOBS compilers (default 2), at
# the lowest CPU and disk priority, never started with less than
# MIN_START_MIB available, and stopped by a watchdog if available memory
# falls below MIN_AVAIL_MIB while they run. One environment at a time.
#
# The shared APB driver drove its outputs through the clocking block, which
# under the IEEE UVM library lost the SETUP phase of back-to-back accesses
# (BUGS TOOL-26, fixed in tb/uvm/apb/garuda_apb_pkg.sv); the testbench APB
# checkers now report 0 violations here as under xrun.
# =============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1

UVM_HOME=${UVM_HOME:-$HOME/external/uvm-verilator/src}
SEEDS=${SEEDS:-3}
SEED0=${SEED0:-0}
SIM_TIMEOUT=${SIM_TIMEOUT:-900}
UVM_JOBS=${UVM_JOBS:-2}
MIN_START_MIB=${MIN_START_MIB:-4000}
MIN_AVAIL_MIB=${MIN_AVAIL_MIB:-1500}
PY=${PY:-python3}

# env | filelist | top | test prefix -- as the uvm_* targets of track_b.mk (dma: track_a.mk)
ENVS="
clic|tb/clic/uvm/filelist_clic_uvm.f|tb_clic_uvm|clic
timers|tb/timers/uvm/filelist_timers_uvm.f|tb_timers_uvm|tmr
pwm|tb/pwm/uvm/filelist_pwm_uvm.f|tb_pwm_uvm|pwm
spis|tb/spi_slave/uvm/filelist_spis_uvm.f|tb_spis_uvm|spis
i2c|tb/i2c/uvm/filelist_i2c_uvm.f|tb_i2c_uvm|i2c
uart|tb/uart/uvm/filelist_uart_uvm.f|tb_uart_uvm|uart
gpio|tb/gpio/uvm/filelist_gpio_uvm.f|tb_gpio_uvm|gpio
crg|tb/clk_div/uvm/filelist_crg_uvm.f|tb_crg_uvm|crg
dma|tb/dma/uvm/filelist_dma_uvm.f|tb_dma_uvm|dma
"

names() { echo "$ENVS" | awk -F'|' 'NF == 4 { print $1 }'; }

build() {   # build <env> <filelist> <top> -> sim/uvm_local/<env>/obj/sim
    local env=$1 fl=$2 top=$3 d=sim/uvm_local/$1 srcs incs defs
    mkdir -p "$d"
    srcs=$($PY scripts/expand_filelist.py "$fl" | tr '\n' ' ') || return 1
    incs=$($PY scripts/expand_filelist.py "$fl" --incdirs | sed 's/-I/+incdir+/g') || return 1
    defs=$($PY scripts/expand_filelist.py "$fl" --defines) || return 1
    local a
    a=$(avail_mib)
    if [ "$a" -lt "$MIN_START_MIB" ]; then
        echo "only $a MiB available, need $MIN_START_MIB to start a build" > "$d/build.log"
        return 1
    fi
    # UVM_NO_DPI: the library's C side (regex, HDL access) is not built.
    # -Wno-fatal: lint is local_lint's job. --assert: bound SVA stays live.
    # setsid: its own process group, so the watchdog stops every g++ at once.
    # shellcheck disable=SC2086
    setsid nice -n 19 ionice -c 3 \
        verilator --binary -j "$UVM_JOBS" --timing --assert -Wno-fatal -Wno-lint -Wno-style \
        -Wno-SYMRSVDWORD -Wno-CONSTRAINTIGN +define+UVM_NO_DPI \
        +incdir+"$UVM_HOME" $incs $defs "$UVM_HOME/uvm_pkg.sv" $srcs \
        --top-module "$top" --Mdir "$d/obj" -o sim > "$d/build.log" 2>&1 &
    watch_mem $! "$d/build.log"
}

avail_mib() { awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo; }

# watch_mem <pid> <log>: wait for <pid>; stop its process group if available
# memory falls below MIN_AVAIL_MIB. Returns the job's status, or 1 if stopped.
watch_mem() {
    local p=$1 log=$2 a peak=0 used
    while kill -0 "$p" 2> /dev/null; do
        a=$(avail_mib)
        used=$(( $(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo) - a ))
        [ "$used" -gt "$peak" ] && peak=$used
        if [ "$a" -lt "$MIN_AVAIL_MIB" ]; then
            kill -TERM -- "-$p" 2> /dev/null; sleep 2; kill -KILL -- "-$p" 2> /dev/null
            wait "$p" 2> /dev/null
            echo "STOPPED: available memory fell to $a MiB (limit $MIN_AVAIL_MIB); try UVM_JOBS=1" >> "$log"
            return 1
        fi
        sleep 1
    done
    wait "$p"; local rc=$?
    echo "peak memory in use while building: $peak MiB" >> "$log"
    return $rc
}

judge() {   # judge <log>: 0 if the run passed
    local log=$1
    grep -q 'RESULT: PASSED' "$log" || return 1
    grep -qE '^UVM_(ERROR|FATAL) :[[:space:]]+[1-9]' "$log" && return 1
    grep -qE 'SVA-FAIL|^\[FAIL\]|%Error' "$log" && return 1
    return 0
}

run_env() {   # run_env <env> <filelist> <top> <prefix>
    local env=$1 fl=$2 top=$3 pfx=$4 d=sim/uvm_local/$1 fail=0 s n
    rm -rf "$d"
    printf "  %-7s build " "$env"
    if ! build "$env" "$fl" "$top"; then
        echo "FAILED (see $d/build.log)"; grep -m5 -E "%Error|STOPPED|only .* MiB" "$d/build.log"; return 1
    fi
    echo "ok ($(grep -o "peak memory.*" "$d/build.log"))"
    one() {   # one <test> <seed> <tag>
        local log=$d/$3.log
        timeout -k 5 "$SIM_TIMEOUT" "$d/obj/sim" +UVM_TESTNAME="$1" +verilator+seed+"$2" \
            > "$log" 2>&1
        if judge "$log"; then printf "  %-7s %-12s PASS\n" "$env" "$3"
        else printf "  %-7s %-12s FAIL (%s)\n" "$env" "$3" "$log"; fail=1; fi
    }
    one "${pfx}_reg_test" 1 reg_s1
    one "${pfx}_directed_test" 1 directed_s1
    s=1
    while [ "$s" -le "$SEEDS" ]; do
        n=$((s + SEED0)); one "${pfx}_random_test" "$n" "random_s$n"; s=$((s + 1))
    done
    return $fail
}

[ $# -gt 0 ] || set -- all
if [ "$1" = list ]; then names; exit 0; fi
if [ "$1" = all ]; then set -- $(names); fi
command -v verilator > /dev/null || { echo "verilator not on PATH (source scripts/setup_open_tools.sh)"; exit 1; }
[ -f "$UVM_HOME/uvm_pkg.sv" ] || { echo "no UVM library at $UVM_HOME (see the header of $0)"; exit 1; }

echo "=== UVM under Verilator: $(verilator --version | head -1)"
echo "    UVM: $UVM_HOME, random seeds: $SEEDS"
bad=0
for e in "$@"; do
    row=$(echo "$ENVS" | awk -F'|' -v e="$e" '$1 == e')
    [ -n "$row" ] || { echo "unknown environment '$e' (try: list)"; bad=1; continue; }
    IFS='|' read -r env fl top pfx <<< "$row"
    run_env "$env" "$fl" "$top" "$pfx" || bad=1
done
if [ $bad -eq 0 ]; then echo "RESULT: PASSED"; else echo "RESULT: FAILED"; fi
exit $bad
