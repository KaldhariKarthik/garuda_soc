#!/usr/bin/env bash
# synth_sta.sh -- ASAP7 synthesis + post-synthesis STA of today's RTL in the OpenROAD-flow-scripts
# container (podman), all four clock-ratio modes, full and logic-only (Track A, 2026-11-01).
# Usage: bash tools/sta/synth_sta.sh [workdir]   (default /tmp/garuda_sta); summary to
# logs/common/summary/sta_synth.txt. SRAMs are the flow's stubs: paths into the macros are not timed.
set -u
ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
W=${1:-/tmp/garuda_sta}; mkdir -p "$W/work"
IMG=${ORFS_IMAGE:-docker.io/openroad/orfs:latest}
OR=/OpenROAD-flow-scripts/tools/install/OpenROAD/bin/openroad
run() { podman run --rm "$@" -v "$ROOT":/garuda:z -v "$W/work":/work:z "$IMG"; }
run -w /OpenROAD-flow-scripts/flow bash -lc 'source ../env.sh >/dev/null 2>&1; make DESIGN_CONFIG=/garuda/flow/pd/asap7/config.mk GARUDA_ROOT=/garuda BLOCKS= WORK_HOME=/work synth' > "$W/synth.log" 2>&1
NET="$W/work/results/asap7/garuda/base/1_2_yosys.v"
[ -s "$NET" ] || { echo "synth_sta: no netlist, see $W/synth.log"; exit 2; }
# the 1_synth.odb step stops on the SRAM stubs (no LEF); STA needs only the gate netlist
python3 - "$NET" "$W/work/1_2_nomacro.v" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
s, n = re.subn(r'\n\s*garuda_(sram_16384x32|sram_4096x32|rom_1024x32)\s+\S+\s*\((?:.|\n)*?\);', '', s)
open(sys.argv[2], 'w').write(s); print(f"synth_sta: {n} macro instances left out of STA")
PY
OUT="$ROOT/logs/common/summary/sta_synth.txt"; mkdir -p "$(dirname "$OUT")"
{ echo "# post-synthesis STA, ASAP7 FF, ideal clocks; $(date -Iseconds); design $(git -C "$ROOT" rev-parse --short HEAD) (+ uncommitted)"
  grep -m1 'Chip area' "$W/work/reports/asap7/garuda/base/synth_stat.txt" 2>/dev/null
  for lo in 0 1; do for m in div2 div4 div8 div16; do
    run -e MODE=$m -e LOGIC_ONLY=$lo -v "$ROOT/tools/sta":/s:z $OR -no_init -exit /s/sta_post_synth.tcl > "$W/sta_${m}_$lo.log" 2>&1
    echo "== $m $( [ $lo = 1 ] && echo 'logic only (reset tree excluded)' || echo 'full')"
    awk '/^Path Group:/{g=$3} /^Path Type: max/{t="max"} /^Path Type: min/{t="min"} /slack \((MET|VIOLATED)\)/{if(t=="max") printf "  %-14s setup %10s %s\n", g, $1, $3}' "$W/sta_${m}_$lo.log" | sort -u
  done; done; } | tee "$OUT"
