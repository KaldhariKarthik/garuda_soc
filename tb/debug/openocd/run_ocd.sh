#!/usr/bin/env bash
# OpenOCD against the simulated debug block (Track A plan 6A.5 G7). Builds the bench, starts it,
# runs OpenOCD with check.tcl, and passes only if every OCD line is PASS and the bench passes.
# Usage: bash tb/debug/openocd/run_ocd.sh   (from the repo root)
set -u
# (logs go to one fixed folder: run one session at a time)
OUT=logs/debug/raw/ocd; mkdir -p "$OUT"
[ -f /opt/rh/gcc-toolset-12/enable ] && source /opt/rh/gcc-toolset-12/enable
export PATH=$HOME/tools/verilator/bin:$PATH
PORT=$((9800 + RANDOM % 100))
python3 -c "import struct,sys; open(sys.argv[1],'wb').write(b''.join(struct.pack('<I',(i*0x9E3779B1)&0xffffffff) for i in range(64)))" "$OUT/img.bin"
rm -rf "$OUT/obj"
verilator --binary --timing --assert -Wno-fatal -Wno-lint -Wno-style -Irtl/mem -Mdir "$OUT/obj" --top-module tb_debug_ocd \
  rtl/debug/jtag_tap.v rtl/debug/dtm.v rtl/debug/dmi_cdc.v rtl/debug/sba_master.v rtl/debug/debug_module.v \
  rtl/debug/debug_top.v rtl/debug/debug_sva.sv rtl/mem/sram_wrapper.v rtl/mem/ahb_mem_slave_if.v \
  rtl/isram/isram_top.v rtl/mem/mem_sva.sv tb/ahb/ahb_lite_checker.v tb/debug/openocd/tb_debug_ocd.sv \
  tb/debug/openocd/jtag_rbb.c > "$OUT/build.log" 2>&1 || { echo "build failed: $OUT/build.log"; exit 2; }
# the bench has its own time limit, so a missed connection cannot leave it waiting in accept()
timeout 1200 "$OUT/obj/Vtb_debug_ocd" +PORT=$PORT > "$OUT/sim.log" 2>&1 &
SIM=$!
for _ in $(seq 100); do grep -q '^\[rbb\] listening' "$OUT/sim.log" 2>/dev/null && break; sleep 0.1; done
grep -q '^\[rbb\] listening' "$OUT/sim.log" || { echo "bench never listened: $OUT/sim.log"; kill $SIM 2>/dev/null; exit 2; }
sed "s/remote_bitbang port 9823/remote_bitbang port $PORT/" tb/debug/openocd/garuda_sim.cfg > "$OUT/garuda_sim.cfg"
grep -q "remote_bitbang port $PORT" "$OUT/garuda_sim.cfg" || { echo "port not set in $OUT/garuda_sim.cfg"; kill $SIM; exit 2; }
timeout 900 "$HOME/tools/oss-cad-suite/bin/openocd" -f "$OUT/garuda_sim.cfg" -c "set IMG $OUT/img.bin" \
  ${OCD_DEBUG:+-d3} -f tb/debug/openocd/check.tcl > "$OUT/openocd.log" 2>&1
OCD_RC=$?
wait $SIM; SIM_RC=$?
grep -E '^OCD (PASS|FAIL)' "$OUT/openocd.log"; tail -2 "$OUT/sim.log" | grep -E 'tb_debug_ocd|RESULT'
# PASS only on a positive record: OpenOCD exit 0, all 8 checks PASS, the script reached its end,
# and the bench passed and exited 0 (not just "no FAIL line seen")
N_PASS=$(grep -c '^OCD PASS' "$OUT/openocd.log")
OCD_WANT=8
bad=0
[ "$OCD_RC" = 0 ]                       || { echo "openocd exit code $OCD_RC"; bad=1; }
[ "$N_PASS" = "$OCD_WANT" ]             || { echo "OCD PASS lines: $N_PASS, want $OCD_WANT"; bad=1; }
grep -q '^OCD FAIL' "$OUT/openocd.log" && { echo "an OCD check failed"; bad=1; }
grep -q '^OCD DONE' "$OUT/openocd.log" || { echo "check.tcl did not reach its end"; bad=1; }
[ "$SIM_RC" = 0 ]                       || { echo "bench exit code $SIM_RC"; bad=1; }
grep -q '^RESULT: PASSED' "$OUT/sim.log" || { echo "bench did not pass"; bad=1; }
[ $bad = 0 ] || { echo "OpenOCD session: FAIL"; exit 1; }
echo "OpenOCD session: PASS"
