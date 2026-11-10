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
elif [ -x /opt/rh/gcc-toolset-13/root/usr/bin/g++ ]; then
    # TOOL-A10 (2026-11-10): the lab machine has gcc-toolset-13 only. Its 64-bit
    # libatomic is not installed, so link against the empty shim, as
    # scripts/setup_open_tools.sh does.
    export PATH="/opt/rh/gcc-toolset-13/root/usr/bin:$PATH"
    if [ -f "$HOME/external/shim/libatomic.a" ]; then
        export LIBRARY_PATH="$HOME/external/shim${LIBRARY_PATH:+:$LIBRARY_PATH}"
    fi
fi

# Rocky 8's python3 is 3.6; the flow scripts need >= 3.11 (tomllib).
# The repo's sw Makefiles call plain `python3`, so a python3 that is the pinned
# interpreter goes first on PATH from an untracked directory (.garuda_bin/).
export PYTHON=${PYTHON:-python3.12}
mkdir -p "$GARUDA_ROOT/.garuda_bin"
ln -sfn "$(command -v "$PYTHON")" "$GARUDA_ROOT/.garuda_bin/python3"

# Spike install (bin, include, lib: the co-simulation links against libriscv).
# TOOL-A13 (2026-11-10): on the lab machine it is ~/external/spike-inst, not
# $GARUDA_TOOLS/spike; the manifests name it as $GARUDA_SPIKE.
if [ -z "${GARUDA_SPIKE:-}" ]; then
    GARUDA_SPIKE=$GARUDA_TOOLS/spike
    [ ! -d "$GARUDA_SPIKE/include/riscv" ] && [ -d "$HOME/external/spike-inst/include/riscv" ] \
        && GARUDA_SPIKE=$HOME/external/spike-inst
fi
export GARUDA_SPIKE

export PATH="$GARUDA_ROOT/.garuda_bin:$GARUDA_TOOLS/verilator/bin:$GARUDA_TOOLS/iverilog/bin:$GARUDA_TOOLS/riscv/bin:$GARUDA_SPIKE/bin:$GARUDA_TOOLS/dtc/bin:$PATH"

export OSS_CAD=${OSS_CAD:-$GARUDA_TOOLS/oss-cad-suite}
# TOOL-A13: on the lab machine the suite is ~/external/oss-cad-suite
if [ ! -d "$OSS_CAD/bin" ] && [ -d "$HOME/external/oss-cad-suite/bin" ]; then
    export OSS_CAD=$HOME/external/oss-cad-suite
fi
# Verilator's randomize() calls an SMT solver (z3 by default). The suite's z3
# is named by full path so the suite itself stays off PATH.
if [ -z "${VERILATOR_SOLVER:-}" ] && ! command -v z3 > /dev/null 2>&1 && [ -x "$OSS_CAD/bin/z3" ]; then
    export VERILATOR_SOLVER="$OSS_CAD/bin/z3 --in"
fi
# TOOL-A10: on the lab machine the pinned Verilator 5.052 is in ~/.local/verilator
if [ ! -x "$GARUDA_TOOLS/verilator/bin/verilator" ] && [ -x "$HOME/.local/verilator/bin/verilator" ]; then
    export PATH="$HOME/.local/verilator/bin:$PATH"
    export VERILATOR=${VERILATOR:-$HOME/.local/verilator/bin/verilator}
    export VERILATOR_COV=${VERILATOR_COV:-$HOME/.local/verilator/bin/verilator_coverage}
fi
export VERILATOR=${VERILATOR:-$GARUDA_TOOLS/verilator/bin/verilator}
export VERILATOR_COV=${VERILATOR_COV:-$GARUDA_TOOLS/verilator/bin/verilator_coverage}

# TOOL-A13: the xPack GCC is set only where it is installed; otherwise RISCV_BIN
# is left as it is (scripts/setup_env.sh, or sw/toolchain.mk's own search).
if [ -n "${RISCV_BIN_OPEN:-}" ] || [ -x "$GARUDA_TOOLS/riscv/bin/riscv-none-elf-gcc" ]; then
    export RISCV_BIN=${RISCV_BIN_OPEN:-$GARUDA_TOOLS/riscv/bin}
    export RISCV_PREFIX=${RISCV_PREFIX_OPEN:-riscv-none-elf-}
fi
export SPIKE=${SPIKE_OPEN:-$GARUDA_SPIKE/bin/spike}
export RISCV_TESTS=${RISCV_TESTS_OPEN:-$GARUDA_TOOLS/src/riscv-tests}
