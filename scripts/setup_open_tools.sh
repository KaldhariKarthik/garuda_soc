#!/usr/bin/env bash
# =============================================================================
# The licence-free tools.  Usage:   source scripts/setup_open_tools.sh
#
# Icarus Verilog, Verilator, Yosys and SymbiYosys from the YosysHQ
# oss-cad-suite, unpacked under ~/external (task 1.2 of the pre-PDK plan). Both
# machines use the build of 2026-10-02, so that a result on one can be
# repeated on the other. Use it in a shell of its own: the Cadence tools are
# set up by scripts/setup_env.sh and do not need this one.
#
#   OSS_CAD_SUITE=/somewhere/else source scripts/setup_open_tools.sh
#
# Verilator builds a simulation with C++20 coroutines (--timing). The compiler
# of Rocky 8 (GCC 8.5) has none, so the GCC 13 tool set is put first on PATH
# when it is installed (`dnf install gcc-toolset-13`); without it
# `SIM=verilator scripts/run_sim.sh` stops with "unrecognized command line
# option -fcoroutines". Lint (make local_lint) does not need it.
# =============================================================================
OSS_CAD_SUITE=${OSS_CAD_SUITE:-$HOME/external/oss-cad-suite}
export PATH="$OSS_CAD_SUITE/bin:$PATH"
export VERILATOR_ROOT="$OSS_CAD_SUITE/share/verilator"
if [ -x /opt/rh/gcc-toolset-13/root/usr/bin/g++ ]; then
    export PATH="/opt/rh/gcc-toolset-13/root/usr/bin:$PATH"
fi
# Verilator links every simulation with -latomic. The GCC 13 tool set installs
# no 64-bit libatomic unless gcc-toolset-13-libatomic-devel is added (root).
# x86-64 needs nothing from that library, so an empty archive satisfies the
# linker without root and without a run-time dependency:
#     mkdir -p ~/external/shim && ar rcs ~/external/shim/libatomic.a
if [ -f "$HOME/external/shim/libatomic.a" ]; then
    export LIBRARY_PATH="$HOME/external/shim${LIBRARY_PATH:+:$LIBRARY_PATH}"
fi

echo "GARUDA licence-free tools ($(cat "$OSS_CAD_SUITE/VERSION" 2>/dev/null || echo 'oss-cad-suite not found')):"
_v() { if command -v "$2" > /dev/null 2>&1; then printf "  %-10s %s\n" "$1" "$($2 $3 2>&1 | head -1)";
       else printf "  %-10s MISSING\n" "$1"; fi; }
_v Icarus    iverilog  -V
_v Verilator verilator --version
_v Yosys     yosys     --version
_v SBY       sby       --version
_v "C++"     g++       --version
unset -f _v
