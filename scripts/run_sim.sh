#!/usr/bin/env bash
# =============================================================================
# run_sim.sh -- run GARUDA testbenches under Icarus Verilog
#
# WHAT THIS IS, AND WHAT IT IS NOT
# --------------------------------
# The signoff simulator for this project is Cadence Xcelium and nothing here
# replaces it. This is the back-end for machines with no Cadence licence: it
# consumes the SAME .f filelists the Makefile's xrun leg consumes, so a run here
# is running exactly the same source list that runs there. That property is the
# whole point -- the moment a second flow gets its own hand-written source list,
# it starts building different RTL from the one that was simulated, and the
# divergence is silent.
#
# Icarus is a real compiler with a real parser, which is most of the value: the
# first thing it does is refuse to compile RTL that only a reader believed in.
#
# WHAT IT CANNOT DO. Anything needing a firmware image -- tb_chip, tb_boot,
# test_sanity, the ISA regression -- needs the RISC-V toolchain and is not
# listed here. Coverage needs Incisive. Neither is substitutable locally.
#
# USAGE
#     ./scripts/run_sim.sh tb_crg                 one testbench
#     ./scripts/run_sim.sh tb_clic +VERBOSE       with plusargs
#     ./scripts/run_sim.sh all                    every block TB + summary
#     ./scripts/run_sim.sh list                   what can be run
#
# Output lands in sim/<workdir>/ using the SAME workdir names as the Makefile's
# run_blk, so a local log and a lab log for the same block sit side by side.
#
# Exit status is 0 only if every testbench compiled, ran, and reported a
# verdict with zero failures. A compile failure, a missing binary or a missing
# verdict line is a failure -- see the note on stale binaries below.
# =============================================================================
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

# -----------------------------------------------------------------------------
# The block-level testbench table: top module | filelist | workdir
#
# Workdir names match the Makefile's run_blk third argument exactly, where
# there is one. Ordered with the protocol checker's own self-test first and
# clocks-and-reset second, because every other entry depends on those two
# working: a bad checker makes every later clean run meaningless, and a bad
# clock makes every later run nonsense.
# -----------------------------------------------------------------------------
TB_TABLE="
tb_ahb_checker_selftest|tb/ahb/filelist_checker_selftest.f|tb_chk_self
tb_crg|tb/clk_div/filelist_crg.f|tb_crg
tb_ahb_interconnect|tb/ahb/filelist_ahb_ic.f|tb_ahb_ic
tb_ahb2apb|tb/ahb2apb/filelist_ahb2apb.f|tb_bridge
tb_mem_subsystem|tb/mem/filelist_mem.f|tb_mem
tb_dma_top|tb/dma/filelist_dma_top.f|tb_dma
tb_clic|tb/clic/filelist_clic.f|tb_clic
tb_timers|tb/timers/filelist_timers.f|tb_timers
tb_debug|tb/debug/filelist_debug.f|tb_debug
tb_apb_shim|tb/common/filelist_shim.f|tb_apb_shim
tb_spim|tb/spi_master/filelist_spim.f|tb_spim
tb_uart|tb/uart/filelist_uart.f|tb_uart
tb_i2c|tb/i2c/filelist_i2c.f|tb_i2c
tb_gpio|tb/gpio/filelist_gpio.f|tb_gpio
tb_pwm|tb/pwm/filelist_pwm.f|tb_pwm
tb_spis|tb/spi_slave/filelist_spis.f|tb_spis
tb_dsu_top|tb/dsu/filelist_dsu_top.f|tb_dsu
"

# -----------------------------------------------------------------------------
# Known Icarus front-end limitations.
#
# These are NOT design defects and NOT testbench defects: Icarus cannot build
# them, so this back-end has nothing to say about them either way. Xcelium is
# the signoff simulator and it supports all of these constructs.
#
# The entries are measured, each with the message that produced it. Three are
# in vendored third-party PULP RTL that the project does not own.
#
# IMPORTANT: a listed testbench is still BUILT AND RUN on every regression. If
# one starts passing, the summary says so and says to delete the entry. A skip
# list that is never re-tested silently becomes a list of tests nobody runs --
# which is this project's own recurring defect (TOOL-4, TB-11, TOOL-5).
# -----------------------------------------------------------------------------
TB_SKIP="
tb_mem_subsystem|assoc array keyed by a packed type (tb line 100): 'Type names are not valid expressions here'
tb_uart|third-party pulp/apb_uart_sv uart_rx.sv:171 'This assignment requires an explicit cast'
tb_gpio|third-party pulp/apb_gpio apb_gpio.sv:131 variable index in a constant expression
tb_spim|third-party pulp/axi_spi_master: compiles, but 12x 'sorry: constant selects in always_* not fully supported' mis-models tx/rx and the run hangs with no time advance
"

skip_reason() {   # $1 = top -> echoes the reason, or nothing
    echo "$TB_SKIP" | while IFS='|' read -r t r; do
        [ -z "${t:-}" ] && continue
        [ "$t" = "$1" ] && { echo "$r"; return; }
    done
}

lookup() {   # $1 = top -> echoes "filelist workdir", or nothing
    echo "$TB_TABLE" | while IFS='|' read -r t f w; do
        [ -z "${t:-}" ] && continue
        [ "$t" = "$1" ] && { echo "$f $w"; return; }
    done
}

# -----------------------------------------------------------------------------
# python3 is a Microsoft Store stub on some Windows installs: it exits without
# running anything. Resolve an interpreter that actually works rather than
# trusting the name.
# -----------------------------------------------------------------------------
PY=""
for c in python3 python py; do
    if command -v $c > /dev/null 2>&1 && $c -c "" > /dev/null 2>&1; then PY=$c; break; fi
done
[ -z "$PY" ] && { echo "ERROR: no working python interpreter found"; exit 1; }

command -v iverilog > /dev/null 2>&1 || {
    echo "ERROR: iverilog is not on PATH."
    echo "  Portable toolchain: unpack YosysHQ oss-cad-suite and put BOTH"
    echo "  lib/ and bin/ on PATH, lib FIRST (see Docs/BUGS.md TOOL-3)."
    exit 127
}

# -----------------------------------------------------------------------------
# run_one <top> <filelist> <workdir> [plusargs...]
#
# ON STALE BINARIES. The .vvp is deleted before every build and vvp runs only
# if the compile returned 0 AND produced the file. Without that, a failed
# compile leaves the previous binary in place and the run "passes" against
# whatever was built last time -- which happened in this project on
# 2026-09-16 and reported a result from RTL that no longer existed.
# -----------------------------------------------------------------------------
run_one() {
    local top="$1" flist="$2" work="$3"; shift 3
    local plusargs="$*"
    local out="sim/$work"
    mkdir -p "$out"
    rm -f "$out/$top.vvp"

    local srcs incs
    srcs=$($PY scripts/expand_filelist.py "$flist") || { echo "FILELIST FAIL"; return 1; }
    incs=$($PY scripts/expand_filelist.py "$flist" --incdirs) || return 1

    iverilog -g2012 -Wall -o "$out/$top.vvp" -s "$top" $incs $srcs 2> "$out/compile.log"
    local rc=$?
    if [ $rc -ne 0 ] || [ ! -f "$out/$top.vvp" ]; then
        echo "COMPILE FAILED (rc=$rc)"
        grep -iE "error" "$out/compile.log" | head -12
        return 1
    fi

    # Wall-clock cap. A testbench whose end condition never arrives runs until
    # the machine is rebooted, and an unattended regression must not be
    # hangable by one bad TB. SIM_TIMEOUT seconds, then SIGKILL; the missing
    # RESULT: line makes verdict_of report NO-VERDICT, which counts as failure.
    if command -v timeout > /dev/null 2>&1; then
        timeout -k 5 "${SIM_TIMEOUT:-180}" vvp "$out/$top.vvp" $plusargs             > "$out/run.log" 2>&1
        if [ $? -eq 124 ]; then
            echo "WALL-CLOCK TIMEOUT after ${SIM_TIMEOUT:-180}s" >> "$out/run.log"
            # On Windows, `timeout` reports 124 but the native vvp child can
            # survive its signals. An orphan spinning in a zero-delay loop
            # takes a core for the rest of the session and slows every
            # testbench after it, so make sure this one is really gone.
            pkill -9 -f "$out/$top.vvp" 2> /dev/null || true
        fi
    else
        vvp "$out/$top.vvp" $plusargs > "$out/run.log" 2>&1
    fi
    return 0
}

# verdict_of <workdir> -> "checks fails verdict"
verdict_of() {
    local log="sim/$1/run.log"
    [ -f "$log" ] || { echo "0 0 NO-LOG"; return; }
    local c f v
    c=$(grep -oE "checks=[0-9]+" "$log" | head -1 | grep -oE "[0-9]+")
    [ -z "$c" ] && c=$(grep -oE "[0-9]+ checks" "$log" | head -1 | grep -oE "[0-9]+")
    # tb_dsu_top counts compared vectors rather than named checks
    [ -z "$c" ] && c=$(grep -oE "tests compared *: *[0-9]+" "$log" | head -1 | grep -oE "[0-9]+")
    f=$(grep -c "\[FAIL\]" "$log")
    if grep -q "WALL-CLOCK TIMEOUT" "$log"; then echo "${c:-0} ${f:-0} WALL-TIMEOUT"; return; fi
    v=$(grep -oE "PASSED|FAILED|TIMEOUT" "$log" | tail -1)
    [ -z "$v" ] && v="NO-VERDICT"
    echo "${c:-0} ${f:-0} $v"
}

TARGET=${1:-}
shift || true

case "$TARGET" in
  list)
      echo "Block testbenches runnable locally (Icarus):"
      echo "$TB_TABLE" | while IFS='|' read -r t f w; do
          [ -z "${t:-}" ] && continue
          printf "  %-22s %s\n" "$t" "$f"
      done
      echo
      echo "Not runnable locally (need the RISC-V toolchain for a hex image):"
      echo "  tb_chip, tb_boot  -- make test_chip / test_boot on the lab host"
      exit 0 ;;

  all)
      echo "=============================================================="
      echo "GARUDA local block regression -- Icarus Verilog"
      echo "  $(iverilog -V 2>&1 | head -1)"
      echo "  $(date '+%Y-%m-%d %H:%M')"
      echo "=============================================================="
      # Stale-results guard: the per-TB results are accumulated through a file
      # because the loop below runs in a subshell. If that file survives from a
      # previous run, the summary silently reports both runs added together --
      # the same class of defect as a stale .vvp. Delete it first, always.
      mkdir -p sim
      rm -f sim/.totals
      echo "$TB_TABLE" | while IFS='|' read -r t f w; do
          [ -z "${t:-}" ] && continue
          printf "  %-22s " "$w"
          reason=$(skip_reason "$t")
          if run_one "$t" "$f" "$w" > "sim/.$w.msg" 2>&1; then
              set -- $(verdict_of "$w")
              c=$1; fl=$2; v=$3
              if [ -n "$reason" ] && [ "$v" = "PASSED" ]; then
                  # The tool limitation is gone. Say so loudly: a stale skip
                  # entry is a test everyone believes is excused.
                  printf "checks=%-6s FAIL=%-4s PASSED  <-- SKIP ENTRY NOW STALE, DELETE IT
" "$c" "$fl"
                  echo "$c $fl PASSED" >> sim/.totals
              elif [ -n "$reason" ]; then
                  printf "SKIP (icarus) %s
" "$reason"
                  echo "0 0 SKIP" >> sim/.totals
              else
                  printf "checks=%-6s FAIL=%-4s %s
" "$c" "$fl" "$v"
                  echo "$c $fl $v" >> sim/.totals
              fi
          else
              if [ -n "$reason" ]; then
                  printf "SKIP (icarus) %s
" "$reason"
                  echo "0 0 SKIP" >> sim/.totals
              else
                  echo ""
                  head -3 "sim/.$w.msg" | sed 's/^/      /'
                  echo "0 1 COMPILE-FAIL" >> sim/.totals
              fi
          fi
          rm -f "sim/.$w.msg"
      done
      echo "  ------------------------------------------------------------"
      if [ -f sim/.totals ]; then
          awk '{
                 if ($3=="SKIP") { sk++ }
                 else            { c+=$1; f+=$2; ran++; if ($3!="PASSED") bad++ }
               }
               END {
                 printf("  %d testbenches ran: %d checks, %d failures, %d not passed%s",
                        ran+0, c+0, f+0, bad+0, ORS);
                 printf("  %d skipped (Icarus front-end limits, listed above)%s", sk+0, ORS);
                 if (f+0==0 && bad+0==0) print "  RESULT: PASSED";
                 else                    print "  RESULT: FAILED";
                 exit (f>0 || bad>0) ? 1 : 0
               }' sim/.totals
          RC=$?
          rm -f sim/.totals
          exit $RC
      fi
      echo "  no results collected"; exit 1 ;;

  "")
      echo "usage: $0 <top|all|list> [+plusargs]"; exit 1 ;;

  *)
      INFO=$(lookup "$TARGET")
      [ -z "$INFO" ] && { echo "unknown top '$TARGET' (try: $0 list)"; exit 1; }
      set -- $INFO
      FL=$1; WD=$2
      echo "=== $TARGET ($FL) ==="
      if run_one "$TARGET" "$FL" "$WD" "$@"; then
          cat "sim/$WD/run.log"
          echo
          read -r c f v <<EOF3
$(verdict_of "$WD")
EOF3
          echo "=== verdict: checks=$c FAIL=$f $v ==="
          [ "$f" = "0" ] && [ "$v" = "PASSED" ] && exit 0
          exit 1
      fi
      exit 1 ;;
esac
