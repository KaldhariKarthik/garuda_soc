# =============================================================================
# GARUDA SoC -- bare-metal software build
#
# Produces, for each test, a .elf (for spike / objdump) and a .hex (for
# tb_boot's $readmemh). Both come from the SAME link, so the image the RTL
# runs and the image the golden model runs cannot drift apart -- which is the
# whole precondition for lockstep comparison being meaningful.
# =============================================================================

RISCV_PREFIX ?= riscv64-amd-linux-gnu-
RISCV_BIN    ?= /home/vivado/2025.2/Vitis/gnu/riscv/linux_toolchain/lin64/bin

CC      = $(RISCV_BIN)/$(RISCV_PREFIX)gcc
OBJCOPY = $(RISCV_BIN)/$(RISCV_PREFIX)objcopy
OBJDUMP = $(RISCV_BIN)/$(RISCV_PREFIX)objdump

ARCH    = rv32im_zicsr        # zicsr: the assembler needs it named explicitly for csrr/csrw
ABI     = ilp32

# -mno-relax: no __global_pointer$ is set up by crt0, so gp-relative
# relaxation would address small data off a zero gp. See crt0.S.
CFLAGS  = -march=$(ARCH) -mabi=$(ABI) -mno-relax -fno-pic -Os -g \
          -ffreestanding -fno-builtin -nostdlib -nostartfiles \
          -Wall -Wextra
LDFLAGS = -T common/link.ld -no-pie -static -Wl,--no-warn-rwx-segments

BUILD   = build

.SECONDARY:
.PRECIOUS: $(BUILD)/%.elf $(BUILD)/%.bin
COMMON  = common/crt0.S

CTESTS  = ctest1
ATESTS  = boot6 dsu_flag2 t_loadbranch t_mem t_clic t_cov \
          t_buserr t_irq t_wfi t_flush t_dsu

ALL     = $(addprefix $(BUILD)/,$(addsuffix .hex,$(CTESTS) $(ATESTS)))

.PHONY: all clean dump
all: $(ALL)

$(BUILD):
	@mkdir -p $(BUILD)

# C tests link against crt0
$(BUILD)/%.elf: tests/%.c $(COMMON) common/link.ld | $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) $(COMMON) $< -o $@

# Assembly tests are their own reset vector -- no crt0. One pattern rule, so
# adding a test means adding its name to ATESTS and nothing else.
$(BUILD)/%.elf: tests/%.S common/link.ld | $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) $< -o $@

$(BUILD)/%.bin: $(BUILD)/%.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/%.hex: $(BUILD)/%.bin
	python3 ../tools/elf2hex.py $< $@

dump:
	@for t in $(CTESTS) $(ATESTS); do \
	  echo "=== $$t ==="; $(OBJDUMP) -d $(BUILD)/$$t.elf | head -40; \
	done

clean:
	rm -rf $(BUILD)
