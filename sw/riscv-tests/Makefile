# =============================================================================
# Build riscv-tests rv32ui + rv32um against the GARUDA memory map.
#
# Each test produces a .elf (spike + objdump) and a .hex (tb_boot), from the
# same link, so RTL and golden model always execute an identical image.
# =============================================================================

RISCV_TESTS ?= /home/kkarthik/external/riscv-tests
RISCV_BIN   ?= /home/vivado/2025.2/Vitis/gnu/riscv/linux_toolchain/lin64/bin
CC          = $(RISCV_BIN)/riscv64-amd-linux-gnu-gcc
OBJCOPY     = $(RISCV_BIN)/riscv64-amd-linux-gnu-objcopy

BUILD  = build

# EXCLUDED, with reasons -- these are not "skipped because they fail":
#   fence_i : self-modifying code. GARUDA has a prefetch buffer and no
#             instruction-cache flush; FENCE.I semantics are a design question
#             (Sec.6), not an ALU test. Run it once that decision is recorded.
#   ma_data : deliberately misaligned loads/stores. GARUDA traps these by
#             design rather than emulating them, so the test's expectation
#             (hardware completes them) does not apply.
#   div/divu/rem/remu : decode_control.v deliberately raises illegal_instr for
#             these (Sec. 7.2) so a software Newton-Raphson handler runs. That
#             handler does not exist in this env, so the tests would trap by
#             design, not by defect. They belong in the trap-handler suite.
#   Moved to the p-env (trap handler) build below, not excluded any more:
#     ma_data, div, divu, rem, remu  -- all need a trap handler.
EXCLUDE   = ma_data          # fence_i re-enabled: FENCE.I implemented (ERRATUM C-3)
EXCLUDE_M = div divu rem remu

# ---- p-env (trap handler) suites -------------------------------------------
# rv32mi is the machine-mode trap suite. Excluded from it:
#   pmpaddr : GARUDA implements no PMP.
#   zicntr / instret_overflow : depend on counter CSRs beyond what csr_file.v
#     implements; revisit once the CSR list is confirmed against Sec.13.
#   breakpoint : probes the Sdtrig debug-trigger CSRs (tselect, tdata1/2,
#     tcontrol). GARUDA implements no debug module at all - the README lists
#     Debug (RISC-V DM v0.13 + JTAG TAP) as Pending - so those CSRs correctly
#     raise illegal-instruction. The test's own mtvec_handler then rejects any
#     cause that is not CAUSE_BREAKPOINT and fails. Re-enable when the debug
#     block lands; nothing here is waived, the feature simply does not exist.
EXCLUDE_MI = pmpaddr instret_overflow breakpoint   # zicntr re-enabled (ERRATUM C-4)

MI_SRCS = $(filter-out $(addprefix $(RISCV_TESTS)/isa/rv32mi/,$(addsuffix .S,$(EXCLUDE_MI))), \
                       $(wildcard $(RISCV_TESTS)/isa/rv32mi/*.S))
MI = $(notdir $(MI_SRCS:.S=))

# Tests that live in rv32ui/rv32um but need the trap handler to run at all.
PTRAP_UI = ma_data
PTRAP_UM = div divu rem remu
PTESTS   = $(MI) $(PTRAP_UI) $(PTRAP_UM)

UI_SRCS = $(filter-out $(addprefix $(RISCV_TESTS)/isa/rv32ui/,$(addsuffix .S,$(EXCLUDE))), \
                       $(wildcard $(RISCV_TESTS)/isa/rv32ui/*.S))
UM_SRCS = $(filter-out $(addprefix $(RISCV_TESTS)/isa/rv32um/,$(addsuffix .S,$(EXCLUDE_M))), \
                       $(wildcard $(RISCV_TESTS)/isa/rv32um/*.S))

UI = $(notdir $(UI_SRCS:.S=))
UM = $(notdir $(UM_SRCS:.S=))
TESTS = $(UI) $(UM)

CFLAGS = -march=rv32im_zifencei -mabi=ilp32 -mno-relax -fno-pic -nostdlib -nostartfiles \
         -Wa,--no-warn \
         -I env -I $(RISCV_TESTS)/isa/macros/scalar -I $(RISCV_TESTS)/env
LDFLAGS = -T ../common/link.ld -no-pie -static -Wl,--no-warn-rwx-segments

.PHONY: all clean list p_all
.PRECIOUS: $(BUILD)/%.elf $(BUILD)/%.bin
# .SECONDARY with no prerequisites marks EVERY intermediate as secondary, so
# make never deletes it. .PRECIOUS alone did not hold for the p-% pattern rules
# and the ELFs were removed after linking -- which silently disabled the Spike
# lockstep check, because the runner skips any test whose .elf is missing.
.SECONDARY:

all: $(addprefix $(BUILD)/,$(addsuffix .hex,$(TESTS))) p_all

p_all: $(addprefix $(BUILD)/p-,$(addsuffix .hex,$(PTESTS)))

list:
	@echo "rv32ui ($(words $(UI))): $(UI)"
	@echo "rv32um ($(words $(UM))): $(UM)"
	@echo "p-env  ($(words $(PTESTS))): $(PTESTS)"

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/%.elf: $(RISCV_TESTS)/isa/rv32ui/%.S env/riscv_test.h | $(BUILD)
	@$(CC) $(CFLAGS) $(LDFLAGS) $< -o $@ 2>$(BUILD)/$*.buildlog || \
	  { echo "BUILD-FAIL $*"; rm -f $@; }

$(BUILD)/%.elf: $(RISCV_TESTS)/isa/rv32um/%.S env/riscv_test.h | $(BUILD)
	@$(CC) $(CFLAGS) $(LDFLAGS) $< -o $@ 2>$(BUILD)/$*.buildlog || \
	  { echo "BUILD-FAIL $*"; rm -f $@; }

PCFLAGS = -march=rv32im_zicsr_zifencei -mabi=ilp32 -mno-relax -fno-pic -nostdlib -nostartfiles \
          -Wa,--no-warn \
          -I env/p -I $(RISCV_TESTS)/isa/macros/scalar -I $(RISCV_TESTS)/env

$(BUILD)/p-%.elf: $(RISCV_TESTS)/isa/rv32mi/%.S env/p/riscv_test.h | $(BUILD)
	@$(CC) $(PCFLAGS) $(LDFLAGS) $< -o $@ 2>$(BUILD)/p-$*.buildlog || \
	  { echo "BUILD-FAIL p-$*"; rm -f $@; }

$(BUILD)/p-%.elf: $(RISCV_TESTS)/isa/rv32um/%.S env/p/riscv_test.h | $(BUILD)
	@$(CC) $(PCFLAGS) $(LDFLAGS) $< -o $@ 2>$(BUILD)/p-$*.buildlog || \
	  { echo "BUILD-FAIL p-$*"; rm -f $@; }

$(BUILD)/p-%.elf: $(RISCV_TESTS)/isa/rv32ui/%.S env/p/riscv_test.h | $(BUILD)
	@$(CC) $(PCFLAGS) $(LDFLAGS) $< -o $@ 2>$(BUILD)/p-$*.buildlog || \
	  { echo "BUILD-FAIL p-$*"; rm -f $@; }

$(BUILD)/%.bin: $(BUILD)/%.elf
	@$(OBJCOPY) -O binary $< $@

$(BUILD)/%.hex: $(BUILD)/%.bin
	@python3 ../../tools/elf2hex.py $< $@ > /dev/null

clean:
	rm -rf $(BUILD)
