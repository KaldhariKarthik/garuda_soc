#!/usr/bin/env bash
# =============================================================================
# run_test.sh <test> - one GARUDA test under irun 15.2, coverage on.
#
# Called by vManager for every run in flow/regress/garuda.vsif, and usable by
# hand from the repo root:
#     flow/regress/run_test.sh tb_uart
#     flow/regress/run_test.sh isa_add
#     flow/regress/run_test.sh chip_irq
#
# Coverage is collected with irun because IMC and vManager on this machine are
# 15.2 and cannot read an Xcelium 22.09 database (Docs/COVERAGE.md).
#
# Everything the simulator prints goes to stdout, which is what vManager scans.
# A run fails on any `*E`/`*F` (assertion failures included), any [FAIL] line,
# or a missing pass marker. The last line is always GARUDA_RESULT: PASS|FAIL.
# =============================================================================
set -u
T=${1:?usage: run_test.sh <test>}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT=${GARUDA_RUN_DIR:-$PWD}                 # vManager starts us in the run directory
[ "$OUT" = "$ROOT" ] && OUT="$ROOT/sim/run_test/$T"
mkdir -p "$OUT"
cd "$ROOT"
source scripts/setup_env.sh > /dev/null
export PATH=/home/install/INCISIVE152/tools/bin:$PATH

LOG="$OUT/irun.log"
COMMON="-64bit -nclibdirname $OUT/INCA_libs -l $LOG \
        -coverage all -cov_cgsample -covoverwrite -covworkdir $OUT/cov_work -covscope garuda -covtest $T"
ARGS=""; MARK="RESULT: +PASSED|ALL CHECKS PASSED"; LOCKSTEP=""

case "$T" in
  # ---- stage 3: block and IP ------------------------------------------------
  tb_crg)      FL=tb/clk_div/filelist_crg.f;       TOP=tb_crg ;;
  tb_mem)      FL=tb/mem/filelist_mem.f;           TOP=tb_mem_subsystem ;;
  tb_dma)      FL=tb/dma/filelist_dma_top.f;       TOP=tb_dma_top ;;
  tb_clic)     FL=tb/clic/filelist_clic.f;         TOP=tb_clic ;;
  tb_timers)   FL=tb/timers/filelist_timers.f;     TOP=tb_timers ;;
  tb_debug)    FL=tb/debug/filelist_debug.f;       TOP=tb_debug ;;
  tb_spim)     FL=tb/spi_master/filelist_spim.f;   TOP=tb_spim ;;
  tb_spis)     FL=tb/spi_slave/filelist_spis.f;    TOP=tb_spis ;;
  tb_i2c)      FL=tb/i2c/filelist_i2c.f;           TOP=tb_i2c ;;
  tb_uart)     FL=tb/uart/filelist_uart.f;         TOP=tb_uart ;;
  tb_gpio)     FL=tb/gpio/filelist_gpio.f;         TOP=tb_gpio ;;
  tb_pwm)      FL=tb/pwm/filelist_pwm.f;           TOP=tb_pwm ;;
  # ---- stage 5: integration -------------------------------------------------
  tb_ahb_ic)   FL=tb/ahb/filelist_ahb_ic.f;        TOP=tb_ahb_interconnect ;;
  tb_bridge)   FL=tb/ahb2apb/filelist_ahb2apb.f;   TOP=tb_ahb2apb ;;
  tb_apb_shim) FL=tb/common/filelist_shim.f;       TOP=tb_apb_shim ;;
  # ---- stage 4: core --------------------------------------------------------
  unit_*)      FL=tb/core/filelist_${T#unit_}.f;   TOP=tb_top; MARK="\[PASS\]|ALL CHECKS PASSED|RESULT: +PASSED" ;;
  dsu)         FL=tb/dsu/filelist_dsu_top.f;       TOP=tb_dsu_top
               python3 tools/gen/DSU_gen.py --count "${DSU_TESTS:-400}" --seed "${DSU_SEED:-1}" --outdir "$OUT" | tail -1
               ARGS="+STIM=$OUT/dsu_stim.mem +EXP=$OUT/dsu_expected.mem"; MARK="RESULT +: PASSED" ;;
  isa_*)       n=${T#isa_}; FL=tb/soc/filelist_boot_cov.f; TOP=tb_boot
               # vsif names cannot carry '-': isa_p_ma_addr is sw/riscv-tests/build/p-ma_addr.hex
               if [ ! -f "sw/riscv-tests/build/$n.hex" ]; then
                   for h in sw/riscv-tests/build/*.hex; do
                       b=$(basename "$h" .hex); [ "${b//-/_}" = "$n" ] && n=$b
                   done
               fi
               ARGS="+HEX=sw/riscv-tests/build/$n.hex +COMMIT=$OUT/commit.log +COVTAG=$OUT/fcov +MAXCYC=100000 +QUIET ${ISA_ARGS:-}"
               MARK="TOHOST=1 -> PASSED"; LOCKSTEP=$n ;;
  san_*)       n=${T#san_}; FL=tb/soc/filelist_boot_cov.f; TOP=tb_boot
               case "$n" in
                 t_flush)  x="+IWAIT=3 +IRAND=1 +SEED=${SEED:-7}" ;;
                 t_buserr) x="+ERR_EN=1 +ERR_BASE=10020000 +ERR_SIZE=1000" ;;
                 t_irq)    x="+IRQ_AT=300" ;;
                 t_wfi)    x="+IRQ_AT=400" ;;
                 t_clic)   x="+IRQ_EVERY=40 +IRQ_SWEEP=1" ;;
                 t_mtip)   x="+MTIP_AT=300" ;;
                 t_hold_flush_matrix) x="+IRQ_EVERY=61 +DWAIT=2 +DRAND=1 +SEED=3" ;;
                 *)        x="" ;;
               esac
               ARGS="+HEX=sw/build/$n.hex +COMMIT=$OUT/commit.log +COVTAG=$OUT/fcov +MAXCYC=400000 +QUIET $x"
               MARK="TOHOST=1 -> PASSED" ;;
  # ---- stage 6: the chip from the pins --------------------------------------
  chip_*)      m=${T#chip_}; FL=tb/soc/filelist_chip.f; TOP=tb_chip; MARK="RESULT: +PASSED"
               case "$m" in
                 uart)   ARGS="+MODE=basic +TEST=sw/build/t_chip_uart.hex" ;;
                 periph) ARGS="+MODE=basic +TEST=sw/build/t_chip_periph.hex +MAXUS=1200" ;;
                 jtag)   ARGS="+MODE=jtag +TEST=sw/build/t_chip_jtag.hex +MAXUS=1500" ;;
                 flash)  ARGS="+MODE=flash +TEST=sw/build/flash.hex +MAXUS=3000" ;;
                 integ)  ARGS="+MODE=basic +TEST=sw/build/t_chip_integ.hex +MAXUS=4000" ;;
                 *)      ARGS="+MODE=$m +TEST=sw/build/t_chip_$m.hex" ;;
               esac ;;
  *) echo "[FAIL] run_test.sh: unknown test '$T'"; echo "GARUDA_RESULT: FAIL $T"; exit 1 ;;
esac

irun $COMMON -f "$FL" -top "$TOP" $ARGS

fail=0
grep -qE "$MARK" "$LOG"                               || { echo "[FAIL] $T: pass marker not found in the log"; fail=1; }
# (a bench reports its own timeout as "*** TIMEOUT" or as a [FAIL] line; the bare
#  word also appears in passing check labels, e.g. the I2C TIMEOUT register)
grep -qE '\[FAIL\]|\[SVA-FAIL\]|\*[EF],|\*\*\* TIMEOUT' "$LOG" && fail=1

# ISA tests are also compared, instruction by instruction, against Spike
if [ -n "$LOCKSTEP" ]; then
    case " p-div p-divu p-rem p-remu p-sbreak p-mcsr " in
      *" $LOCKSTEP "*) echo "LOCKSTEP: n/a ($LOCKSTEP traps by design, see scripts/run_regression.sh)" ;;
      # vManager puts Incisive's own (old) libstdc++ on LD_LIBRARY_PATH, which Spike
      # cannot load; the comparison runs with the system libraries
      *) ls_out=$(env -u LD_LIBRARY_PATH python3 tools/lockstep.py --rtl "$OUT/commit.log" --elf "sw/riscv-tests/build/$LOCKSTEP.elf" \
                     --spike-log "$OUT/spike.log" --spike "$SPIKE" --max 3 2>&1)
         if echo "$ls_out" | grep -q "^MATCH"; then echo "LOCKSTEP: MATCH"
         else echo "[FAIL] $T: lockstep with Spike diverged"; echo "$ls_out" | head -12; fail=1; fi ;;
    esac
fi

if [ "$fail" = 0 ]; then echo "GARUDA_RESULT: PASS $T"; else echo "GARUDA_RESULT: FAIL $T"; fi
exit $fail
