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
EXCLUDE   = fence_i ma_data
EXCLUDE_M = div divu rem remu

UI_SRCS = $(filter-out $(addprefix $(RISCV_TESTS)/isa/rv32ui/,$(addsuffix .S,$(EXCLUDE))), \
                       $(wildcard $(RISCV_TESTS)/isa/rv32ui/*.S))
UM_SRCS = $(filter-out $(addprefix $(RISCV_TESTS)/isa/rv32um/,$(addsuffix .S,$(EXCLUDE_M))), \
                       $(wildcard $(RISCV_TESTS)/isa/rv32um/*.S))

UI = $(notdir $(UI_SRCS:.S=))
UM = $(notdir $(UM_SRCS:.S=))
TESTS = $(UI) $(UM)

CFLAGS = -march=rv32im -mabi=ilp32 -mno-relax -fno-pic -nostdlib -nostartfiles \
         -Wa,--no-warn \
         -I env -I $(RISCV_TESTS)/isa/macros/scalar -I $(RISCV_TESTS)/env
LDFLAGS = -T ../common/link.ld -no-pie -static -Wl,--no-warn-rwx-segments

.PHONY: all clean list
.PRECIOUS: $(BUILD)/%.elf $(BUILD)/%.bin

all: $(addprefix $(BUILD)/,$(addsuffix .hex,$(TESTS)))

list:
	@echo "rv32ui ($(words $(UI))): $(UI)"
	@echo "rv32um ($(words $(UM))): $(UM)"

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/%.elf: $(RISCV_TESTS)/isa/rv32ui/%.S env/riscv_test.h | $(BUILD)
	@$(CC) $(CFLAGS) $(LDFLAGS) $< -o $@ 2>$(BUILD)/$*.buildlog || \
	  { echo "BUILD-FAIL $*"; rm -f $@; }

$(BUILD)/%.elf: $(RISCV_TESTS)/isa/rv32um/%.S env/riscv_test.h | $(BUILD)
	@$(CC) $(CFLAGS) $(LDFLAGS) $< -o $@ 2>$(BUILD)/$*.buildlog || \
	  { echo "BUILD-FAIL $*"; rm -f $@; }

$(BUILD)/%.bin: $(BUILD)/%.elf
	@$(OBJCOPY) -O binary $< $@

$(BUILD)/%.hex: $(BUILD)/%.bin
	@python3 ../../tools/elf2hex.py $< $@ > /dev/null

clean:
	rm -rf $(BUILD)
