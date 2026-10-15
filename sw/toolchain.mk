# =============================================================================
# sw/toolchain.mk -- which RISC-V GCC builds the firmware and the ISA tests.
# Included by sw/Makefile and sw/riscv-tests/Makefile, so both always agree.
#
# Order (first one that applies wins):
#   1. RISCV_BIN given on the command line or in the environment (for example
#      by tools/run/env.sh) -- used as given; RISCV_PREFIX is taken as given,
#      else found by looking for a known <prefix>gcc in RISCV_BIN
#   2. the Vitis 2025.2 toolchain at its install path (the lab machines)
#   3. the xPack riscv-none-elf toolchain in $(GARUDA_TOOLS)/riscv (Track A)
#   4. riscv-none-elf- / riscv64-unknown-elf- / riscv32-unknown-elf- on PATH
#
# Any of them must give byte-identical images for the same sources; the -march
# strings name every extension (zicsr, zifencei) so newer GCCs accept them.
# `make -C sw toolchain` prints the choice.
# =============================================================================
VITIS_RISCV_BIN := /home/vivado/2025.2/Vitis/gnu/riscv/linux_toolchain/lin64/bin
GARUDA_TOOLS    ?= $(HOME)/tools
RISCV_PREFIXES  := riscv64-amd-linux-gnu- riscv-none-elf- riscv64-unknown-elf- riscv32-unknown-elf-

ifeq ($(origin RISCV_BIN),undefined)
  ifneq ($(wildcard $(VITIS_RISCV_BIN)/riscv64-amd-linux-gnu-gcc),)
    RISCV_BIN := $(VITIS_RISCV_BIN)
  else ifneq ($(wildcard $(GARUDA_TOOLS)/riscv/bin/riscv-none-elf-gcc),)
    RISCV_BIN := $(GARUDA_TOOLS)/riscv/bin
  else
    _RV_GCC   := $(firstword $(foreach p,$(RISCV_PREFIXES),$(shell command -v $(p)gcc 2>/dev/null)))
    RISCV_BIN := $(patsubst %/,%,$(dir $(_RV_GCC)))
  endif
endif

ifeq ($(origin RISCV_PREFIX),undefined)
  RISCV_PREFIX := $(firstword $(foreach p,$(RISCV_PREFIXES),$(if $(wildcard $(RISCV_BIN)/$(p)gcc),$(p))))
endif

ifeq ($(wildcard $(RISCV_BIN)/$(RISCV_PREFIX)gcc),)
  $(warning no RISC-V GCC found (RISCV_BIN='$(RISCV_BIN)' RISCV_PREFIX='$(RISCV_PREFIX)'); set RISCV_BIN and RISCV_PREFIX)
endif

CC      = $(RISCV_BIN)/$(RISCV_PREFIX)gcc
OBJCOPY = $(RISCV_BIN)/$(RISCV_PREFIX)objcopy
OBJDUMP = $(RISCV_BIN)/$(RISCV_PREFIX)objdump

# keep the including Makefile's default goal (its first target, e.g. `all`)
_RV_GOAL := $(.DEFAULT_GOAL)
.PHONY: toolchain
toolchain:
	@echo "RISCV_BIN    = $(RISCV_BIN)"
	@echo "RISCV_PREFIX = $(RISCV_PREFIX)"
	@echo "gcc          = $$($(CC) --version | sed -n 1p)"
.DEFAULT_GOAL := $(_RV_GOAL)
