#!/usr/bin/env bash
# =============================================================================
# GARUDA environment setup.  Usage:   source scripts/setup_env.sh
#
# NOTHING needed to build or simulate GARUDA is on PATH in a default shell.
# This script is the single place those locations are recorded, so a new
# machine (or a new team member) needs one edit, not six.
#
# Override any of these from outside if your install differs, e.g.
#   XCELIUM_HOME=/opt/xcelium source scripts/setup_env.sh
# =============================================================================

# --- Cadence Xcelium (simulator) --------------------------------------------
# NOTE: the binaries are under tools/bin, NOT bin. The obvious path is wrong.
XCELIUM_HOME=${XCELIUM_HOME:-/home/install/XCELIUM2209}
export PATH="$XCELIUM_HOME/tools/bin:$PATH"

# --- Cadence license --------------------------------------------------------
# Without this, xrun COMPILES AND ELABORATES FINE and then dies at simulation
# with "xmsim: *F,NOLICN". The failure is late and looks unrelated to licensing.
# The address of the licence server is not in the repository, which is public:
# it is read from scripts/local_env.sh, a file of your own that git does not
# track (copy scripts/local_env.sh.example and fill it in), or from the
# environment if LM_LICENSE_FILE is already set there.
_garuda_local="$(dirname "${BASH_SOURCE[0]}")/local_env.sh"
[ -f "$_garuda_local" ] && . "$_garuda_local"
unset _garuda_local
export LM_LICENSE_FILE=${LM_LICENSE_FILE:-}
export CDS_LIC_FILE=${CDS_LIC_FILE:-$LM_LICENSE_FILE}

# --- Coverage reporting -----------------------------------------------------
# imc ships with Incisive on this box, not with Xcelium.
export IMC_HOME=${IMC_HOME:-/home/install/INCISIVE152}
export PATH="$IMC_HOME/bin:$PATH"

# --- RISC-V toolchain -------------------------------------------------------
# This is the Vitis *Linux* toolchain, but it carries an rv32imac/ilp32
# multilib, so -march=rv32im -mabi=ilp32 produces correct bare-metal code.
export RISCV_BIN=${RISCV_BIN:-/home/vivado/2025.2/Vitis/gnu/riscv/linux_toolchain/lin64/bin}
export RISCV_PREFIX=${RISCV_PREFIX:-riscv64-amd-linux-gnu-}
export PATH="$RISCV_BIN:$PATH"

# --- Golden model + test suite ----------------------------------------------
export SPIKE=${SPIKE:-$HOME/external/spike-inst/bin/spike}
export RISCV_TESTS=${RISCV_TESTS:-$HOME/external/riscv-tests}

# --- Report -----------------------------------------------------------------
echo "GARUDA environment:"
_chk() { if [ -x "$2" ] || command -v "$2" >/dev/null 2>&1; then
             echo "  OK      $1"; else echo "  MISSING $1  ($2)"; fi; }
_chk "xrun (Xcelium)"      "$XCELIUM_HOME/tools/bin/xrun"
_chk "imc (coverage)"      "$IMC_HOME/bin/imc"
_chk "riscv gcc"           "$RISCV_BIN/${RISCV_PREFIX}gcc"
_chk "spike (golden ISS)"  "$SPIKE"
[ -d "$RISCV_TESTS/isa" ] && echo "  OK      riscv-tests" \
                          || echo "  MISSING riscv-tests ($RISCV_TESTS)"
if [ -n "$LM_LICENSE_FILE" ]; then echo "  license: set (from scripts/local_env.sh or the environment)"
else echo "  MISSING license: LM_LICENSE_FILE is empty - copy scripts/local_env.sh.example to scripts/local_env.sh"; fi
unset -f _chk
