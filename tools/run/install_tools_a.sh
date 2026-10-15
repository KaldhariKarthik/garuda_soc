#!/usr/bin/env bash
# =============================================================================
# install_tools_a.sh -- Track A plan P0.6: install and PIN the open verification
# tools that are not on the machine yet. Idempotent; prints every pin.
#
#   bash tools/run/install_tools_a.sh           (installs into $GARUDA_TOOLS, default ~/tools)
#
#   riscv-formal       YosysHQ/riscv-formal              -> $T/src/riscv-formal
#   riscv-arch-test    riscv-non-isa/riscv-arch-test     -> $T/src/riscv-arch-test
#   riscv-dv           chipsalliance/riscv-dv (pygen)    -> $T/src/riscv-dv
#   Sail RISC-V model  riscv/sail-riscv release binary   -> $T/sail
#   Python venv        riscof, riscv-config, riscv-isac, pyvsc + riscv-dv deps -> $T/venv-a
#
# The pins written to $T/PINS_track_a.txt are copied into Docs/handbook/H1_tools.md.
# A pin moves only by editing this file (commit) and rerunning the runner
# qualification (Docs/handbook/H2_running.md).
# =============================================================================
set -euo pipefail
T=${GARUDA_TOOLS:-$HOME/tools}
PY=${PYTHON:-python3.12}
mkdir -p "$T/src"
PINS=$T/PINS_track_a.txt
: > "$PINS"

pin_clone() {   # pin_clone <name> <url> <ref>
    local name=$1 url=$2 ref=$3 dst=$T/src/$1
    if [ ! -d "$dst/.git" ]; then git clone --quiet "$url" "$dst"; fi
    git -C "$dst" fetch --quiet --tags origin
    git -C "$dst" checkout --quiet "$ref"
    echo "$name $(git -C "$dst" rev-parse --short=12 HEAD) $url ($ref)" | tee -a "$PINS"
}

# Refs: frozen to the commits the default branches resolved to on the first
# install (2026-10-11, recorded in H1). Moving a pin = editing these lines.
REF_FORMAL=${REF_FORMAL:-c992aa61fdfe}
REF_ARCH=${REF_ARCH:-6e8a45123f14}
REF_DV=${REF_DV:-0d71c2b666de}
pin_clone riscv-formal    https://github.com/YosysHQ/riscv-formal          "$REF_FORMAL"
pin_clone riscv-arch-test https://github.com/riscv-non-isa/riscv-arch-test "$REF_ARCH"
pin_clone riscv-dv        https://github.com/chipsalliance/riscv-dv        "$REF_DV"

# ---- Sail: the pinned Linux x86_64 release binary -----------------------------------
SAIL_URL=${SAIL_URL:-https://github.com/riscv/sail-riscv/releases/download/0.15/sail-riscv-Linux-x86_64.tar.gz}
if [ ! -x "$T/sail/bin/sail_riscv_sim" ]; then
    url=$SAIL_URL
    mkdir -p "$T/sail" && curl -fsSL "$url" | tar -xz -C "$T/sail" --strip-components=1
    echo "$url" > "$T/sail/SOURCE_URL"
fi
echo "sail $("$T/sail/bin/sail_riscv_sim" --version 2>&1 | head -1) $(cat "$T/sail/SOURCE_URL")" | tee -a "$PINS"

# ---- Python venv for RISCOF + pygen ----------------------------------------------------
if [ ! -x "$T/venv-a/bin/python" ]; then "$PY" -m venv "$T/venv-a"; fi
"$T/venv-a/bin/python" -m pip install --quiet --upgrade pip
"$T/venv-a/bin/python" -m pip install --quiet riscof==1.25.3 riscv-config==3.18.3 riscv-isac==0.18.0 \
    pyvsc==0.9.1.10086043874
if [ -f "$T/src/riscv-dv/requirements.txt" ]; then
    "$T/venv-a/bin/python" -m pip install --quiet -r "$T/src/riscv-dv/requirements.txt" || \
        echo "WARNING: some riscv-dv requirements did not install (see above)" | tee -a "$PINS"
fi
# riscv-config 3.18.3 declares pyyaml==5.2 (no Python 3.12 build); riscv-dv pulls
# PyYAML 6. riscof setup + riscv-config checks run clean on 6.0.3 (smoke-tested
# 2026-10-11, H1), so the venv ends on 6.0.3 whatever order pip resolved in.
"$T/venv-a/bin/python" -m pip install --quiet pyyaml==6.0.3
"$T/venv-a/bin/python" -m pip freeze | grep -i -E '^(riscof|riscv-config|riscv-isac|pyvsc|pyyaml)==' | sed 's/^/pip /' | tee -a "$PINS"
echo "done: pins in $PINS"
