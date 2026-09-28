#!/bin/bash
# =============================================================================
# FPGA-wrapper simulation (Verilator 5.x), from the repo root:
#   fpga/sim/run_sim.sh core  sw/build/t_chip_basic.hex [+WDT] [+CONSOLE]
#       tb_fpga_core: SystemVerilog copy of the host sequences
#   fpga/sim/run_sim.sh host  run sw/build/t_chip_basic.hex [--wdt] [--console]
#       tb_host: fpga/kv260/host/garuda_host.py itself, through FIFOs
# Needs: make -C sw fpga  (bootrom.hex + images)
# Sim-only substitutes: fpga/sim/xil_prims_sim.v (MMCM/BUFG models).
# =============================================================================
set -e
cd "$(dirname "$0")/../.."
MODE=$1; shift
OBJ=/tmp/garuda_fpga_sim_$MODE
FIX=$OBJ/fix; mkdir -p $FIX
# rtl/dsu/mac_unit.v has a comment that starts "// Verilator ...", which
# Verilator parses as a metacomment. Compile a copy with it neutralised.
sed 's@// Verilator@// (Verilator)@g' rtl/dsu/mac_unit.v > $FIX/mac_unit.v
SRCS=$(python3 scripts/expand_filelist.py rtl/soc/filelist_chip.f | tr ' ' '\n' \
       | grep -v "_sva.sv\|rtl/clk_div/clk_div.v\|rtl/core/core_clk_gate.v" \
       | sed "s@rtl/dsu/mac_unit.v@$FIX/mac_unit.v@")
INCS=$(python3 scripts/expand_filelist.py rtl/soc/filelist_chip.f --incdirs)
TOP=$([ "$MODE" = host ] && echo tb_host || echo tb_fpga_core)
verilator --binary --timing -j 8 -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN \
    --top-module $TOP -Mdir $OBJ $INCS fpga/sim/xil_prims_sim.v $SRCS \
    rtl/fpga/clk_div_fpga.v rtl/fpga/core_clk_gate_fpga.v rtl/fpga/garuda_fpga_core.v \
    fpga/sim/$TOP.sv > $OBJ/build.log 2>&1 || { grep %Error $OBJ/build.log; exit 1; }
if [ "$MODE" = host ]; then
    D=$(mktemp -d); mkfifo $D/cmd.fifo $D/rsp.fifo
    $OBJ/V$TOP +DIR=$D > $D/sim.log 2>&1 &
    python3 fpga/kv260/host/garuda_host.py --sim $D --timeout 600 "$@"; RC=$?
    wait; cat $D/sim.log; exit $RC
else
    HEX=$1; shift
    $OBJ/V$TOP +TEST=$HEX "$@"
fi
