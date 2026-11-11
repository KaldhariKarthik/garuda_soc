# =============================================================================
# sw/bench -- CoreMark and Dhrystone for GARUDA (1-TOPS 5.7, flow stage F6)
#
#   make -C sw/bench            build/<bench>.hex   timed (mcycle), for the score
#                               build/<bench>_ls.hex  fake timer, for Spike lockstep
#
# GARUDA is RV32I + Zmmul: multiply in hardware, divide in software
# (rt/bench_rt.c). crt0 as sw/common plus zeroed registers (rt/crt0_bench.S),
# same tohost handshake as sw/tests. How to run on
# the bench and read the score: README.md here.
# =============================================================================
include ../toolchain.mk

ARCH     = rv32i_zmmul_zicsr
ABI      = ilp32
OPT      = -O2
BASEFLAGS = -march=$(ARCH) -mabi=$(ABI) -mno-relax -fno-pic -ffreestanding -fno-builtin \
           -nostdlib -nostartfiles -Irt -g
LDFLAGS  = -T link_bench.ld -no-pie -static -Wl,--no-warn-rwx-segments -Wl,--build-id=none
BUILD    = build

# CoreMark: the 2K performance run. 20 iterations last about 12 M cycles, over
# CoreMark's 10-second minimum at the notional 1 MHz (core_portme.c).
CM_ITER    ?= 20
CM_ITER_LS ?= 2
CM_SRC   = coremark/core_list_join.c coremark/core_main.c coremark/core_matrix.c \
           coremark/core_state.c coremark/core_util.c coremark/core_portme.c
CM_FLAGS = -Icoremark -DPERFORMANCE_RUN=1 -DTOTAL_DATA_SIZE=2000 \
           -DFLAGS_STR='"$(OPT) -march=$(ARCH)"'

# Dhrystone 2.2 (riscv-tests copy), its own 500 runs (dhrystone.h). HZ = 1 000 000
# with mcycle, so Dhrystones per second is per MHz; DMIPS/MHz = that / 1757
# (tools/bench_report.py). dhrystone/sys holds stand-ins for the three libc
# headers it includes (the toolchain's glibc headers have no rv32 variant).
DH_SRC   = dhrystone/dhrystone.c dhrystone/dhrystone_main.c
DH_FLAGS = -Idhrystone -Idhrystone/sys -Wno-implicit-int -Wno-implicit-function-declaration \
           -Wno-return-type -Wno-builtin-declaration-mismatch -fno-common

COMMON   = rt/crt0_bench.S rt/bench_rt.c
DEPS     = $(COMMON) rt/bench_rt.h link_bench.ld Makefile

.PHONY: all clean
all: $(BUILD)/coremark.hex $(BUILD)/coremark_ls.hex $(BUILD)/dhrystone.hex $(BUILD)/dhrystone_ls.hex

$(BUILD):
	@mkdir -p $@

$(BUILD)/coremark.elf: $(CM_SRC) $(DEPS) | $(BUILD)
	$(CC) $(BASEFLAGS) $(OPT) $(CM_FLAGS) -DITERATIONS=$(CM_ITER) $(LDFLAGS) $(COMMON) $(CM_SRC) -o $@
$(BUILD)/coremark_ls.elf: $(CM_SRC) $(DEPS) | $(BUILD)
	$(CC) $(BASEFLAGS) $(OPT) $(CM_FLAGS) -DITERATIONS=$(CM_ITER_LS) -DBENCH_FAKE_TIMER $(LDFLAGS) $(COMMON) $(CM_SRC) -o $@

# -std=gnu89: Dhrystone is K&R C (implicit int, old-style definitions)
$(BUILD)/dhrystone.elf: $(DH_SRC) dhrystone/dhrystone.h dhrystone/util.h $(wildcard dhrystone/sys/*.h) $(DEPS) | $(BUILD)
	$(CC) $(BASEFLAGS) $(OPT) -std=gnu89 $(DH_FLAGS) $(LDFLAGS) $(COMMON) $(DH_SRC) -o $@
$(BUILD)/dhrystone_ls.elf: $(DH_SRC) dhrystone/dhrystone.h dhrystone/util.h $(wildcard dhrystone/sys/*.h) $(DEPS) | $(BUILD)
	$(CC) $(BASEFLAGS) $(OPT) -std=gnu89 $(DH_FLAGS) -DBENCH_FAKE_TIMER $(LDFLAGS) $(COMMON) $(DH_SRC) -o $@

# No compressed and no divide instruction may reach the core
$(BUILD)/%.bin: $(BUILD)/%.elf
	@if $(OBJDUMP) -d -M no-aliases $< | grep -E '\s(c\.[a-z]+|div|divu|rem|remu)\s' ; then \
	   echo "$<: instruction GARUDA does not implement"; exit 1; fi
	$(OBJCOPY) -O binary $< $@

$(BUILD)/%.hex: $(BUILD)/%.bin
	python3 ../../tools/elf2hex.py $< $@

clean:
	rm -rf $(BUILD)
