# =============================================================================
# tools/run/env.sh -- open-tool environment for the Track A flow.
#
#   source tools/run/env.sh          (from the repo root, bash)
#
# Puts the PINNED open tools first on PATH: Verilator 5.052, Icarus 12, the
# xPack riscv-none-elf GCC, Spike, dtc. The oss-cad-suite is NOT put on PATH:
# it ships its own verilator (5.053-devel) and iverilog, which would silently
# replace the pinned ones. Formal tools are called through $OSS_CAD/bin/<tool>.
#
# Does not touch the Cadence settings of scripts/setup_env.sh; the two can be
# sourced in either order. Override any location from outside, e.g.
#   GARUDA_TOOLS=/opt/garuda-tools source tools/run/env.sh
# Pinned versions and install notes: Docs/handbook/H1_tools.md
# =============================================================================

GARUDA_ROOT=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
export GARUDA_ROOT
export GARUDA_TOOLS=${GARUDA_TOOLS:-$HOME/tools}

# Verilator --timing needs GCC >= 10 for C++20 coroutines; Rocky 8's system
# GCC is 8, so use gcc-toolset-12 when it is installed.
if [ -f /opt/rh/gcc-toolset-12/enable ]; then
    # shellcheck disable=SC1091
    source /opt/rh/gcc-toolset-12/enable
fi

# Rocky 8's python3 is 3.6; the flow scripts need >= 3.11 (tomllib).
# The repo's sw Makefiles call plain `python3`, so a python3 that is the pinned
# interpreter goes first on PATH from an untracked directory (.garuda_bin/).
export PYTHON=${PYTHON:-python3.12}
mkdir -p "$GARUDA_ROOT/.garuda_bin"
ln -sfn "$(command -v "$PYTHON")" "$GARUDA_ROOT/.garuda_bin/python3"

export PATH="$GARUDA_ROOT/.garuda_bin:$GARUDA_TOOLS/verilator/bin:$GARUDA_TOOLS/iverilog/bin:$GARUDA_TOOLS/riscv/bin:$GARUDA_TOOLS/spike/bin:$GARUDA_TOOLS/dtc/bin:$PATH"

export OSS_CAD=${OSS_CAD:-$GARUDA_TOOLS/oss-cad-suite}
export VERILATOR=${VERILATOR:-$GARUDA_TOOLS/verilator/bin/verilator}
export VERILATOR_COV=${VERILATOR_COV:-$GARUDA_TOOLS/verilator/bin/verilator_coverage}

export RISCV_BIN=${RISCV_BIN_OPEN:-$GARUDA_TOOLS/riscv/bin}
export RISCV_PREFIX=${RISCV_PREFIX_OPEN:-riscv-none-elf-}
export SPIKE=${SPIKE_OPEN:-$GARUDA_TOOLS/spike/bin/spike}
export RISCV_TESTS=${RISCV_TESTS_OPEN:-$GARUDA_TOOLS/src/riscv-tests}
