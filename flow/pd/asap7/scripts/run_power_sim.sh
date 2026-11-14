#!/usr/bin/env bash
# =============================================================================
# run_power_sim.sh [program.hex] [saif-start-ns] [max-us]   (PD-14)
#
# Switching activity for power analysis: runs a chip program on the RTL under
# Verilator with SAIF tracing and writes $PD_WORK/power_sim/activity.saif.
# Default program: sw/build/t_chip_integ.hex (374 us, DMA and peripherals),
# from 20 us (after the boot ROM) to the end, timeout 4000 us.
#
# tb/soc/tb_chip.sv is not changed: a copy with a SAIF dump block is made in
# the work directory, and the chip file list is pointed at it. Needs the RISC-V
# programs (make -C sw) and oss-cad-suite's Verilator on PATH
# (scripts/setup_open_tools.sh). Then:
#   flow/pd/asap7/scripts/run_power.sh <variant> TC $PD_WORK/power_sim/activity.saif
# =============================================================================
set -euo pipefail
HEX=${1:-sw/build/t_chip_integ.hex}
START=${2:-20000}
MAXUS=${3:-4000}
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
W=${PD_WORK:-$HOME/tools/garuda_pd}/power_sim
mkdir -p "$W"
cd "$ROOT"
[ -s "$HEX" ] || { echo "run_power_sim: no $HEX (make -C sw)"; exit 1; }
command -v verilator > /dev/null || { echo "run_power_sim: verilator not on PATH"; exit 1; }

python3 - "$W" <<'EOF'
import sys
w = sys.argv[1]
s = open("tb/soc/tb_chip.sv").read()
anchor = "module tb_chip;\n"
assert anchor in s, "tb_chip.sv: module line not found"
dump = anchor + """    // ---- added by run_power_sim.sh (power analysis only) ----
    integer saif_start;
    initial if ($value$plusargs("SAIF_START=%d", saif_start)) begin
        #(saif_start * 1.0);
        $dumpfile("WORKDIR/activity.saif");
        $dumpvars(0, tb_chip.dut.u_core);
        $display("[power] SAIF dump of tb_chip.dut.u_core from %0t", $time);
    end
""".replace("WORKDIR", w)
open(w + "/tb_chip.sv", "w").write(s.replace(anchor, dump, 1))
f = open("tb/soc/filelist_chip.f").read().replace("tb/soc/tb_chip.sv", w + "/tb_chip.sv")
open(w + "/filelist_chip_power.f", "w").write(f)
EOF

FL=$W/filelist_chip_power.f
srcs=$(python3 scripts/expand_filelist.py "$FL")
incs=$(python3 scripts/expand_filelist.py "$FL" --incdirs)
defs=$(python3 scripts/expand_filelist.py "$FL" --defines)
# -j 2: a chip build on the 7.4 GB WSL default must not use every core
verilator --binary --timing --assert --trace-saif -j 2 -Wno-fatal -Wno-lint -Wno-style \
    --top-module tb_chip -Mdir "$W/obj" $incs $defs $srcs > "$W/compile.log" 2>&1 \
    || { tail -20 "$W/compile.log"; echo "run_power_sim: build failed"; exit 1; }
"$W/obj/Vtb_chip" +verilator+error+limit+1000 +MODE=basic +TEST="$HEX" +SAIF_START="$START" \
    +MAXUS="$MAXUS" > "$W/run.log" 2>&1 || true
grep -E "power|tohost|RESULT" "$W/run.log" | tail -4
grep -q "RESULT: PASSED" "$W/run.log" || { echo "run_power_sim: the program did not pass"; exit 1; }
ls -la "$W/activity.saif"
