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
          t_buserr t_irq t_wfi t_flush t_dsu t_mtip

ALL     = $(addprefix $(BUILD)/,$(addsuffix .hex,$(CTESTS) $(ATESTS)))

# ---- Rev 4.0 chip: Boot ROM image and ISRAM-resident chip-level tests -------
CHIPTESTS = t_chip_basic t_chip_irq t_chip_wdt t_chip_jtag t_chip_flash
CHIPFLAGS = -Icommon -Ichip
CHIP_ALL  = $(BUILD)/bootrom.hex $(BUILD)/flash.hex \
            $(addprefix $(BUILD)/,$(addsuffix .hex,$(CHIPTESTS)))

.PHONY: all chip clean dump
all: $(ALL) $(CHIP_ALL)
chip: $(CHIP_ALL)

# GARUDA_HAVE_SPIM swaps boot.c's stub for the real block 13 driver; without it
# the flash reads as erased and boot always takes the recovery path.
$(BUILD)/bootrom.elf: bootrom/rom_start.S bootrom/boot.c bootrom/spim.c \
                      bootrom/link_rom.ld common/garuda_map.h | $(BUILD)
	$(CC) $(CFLAGS) $(CHIPFLAGS) -DGARUDA_HAVE_SPIM \
	    -T bootrom/link_rom.ld -no-pie -static \
	    bootrom/rom_start.S bootrom/boot.c bootrom/spim.c -o $@

# 1024 words: unused ROM is 0x0000_0000, an illegal instruction (rom_fill)
$(BUILD)/bootrom.hex: $(BUILD)/bootrom.bin
	python3 ../tools/elf2hex.py $< $@ --base 0x10000000 --words 1024

$(BUILD)/t_chip_%.elf: chip/t_chip_%.c chip/crt0_chip.S chip/chip.h chip/link_chip.ld common/garuda_map.h | $(BUILD)
	$(CC) $(CFLAGS) $(CHIPFLAGS) -T chip/link_chip.ld -no-pie -static \
	    chip/crt0_chip.S $< -o $@

$(BUILD)/t_chip_%.hex: $(BUILD)/t_chip_%.bin
	python3 ../tools/elf2hex.py $< $@ --base 0x00000000

# The SPI flash image: a boot header plus t_chip_flash, byte per line for the
# flash model's backing store. This is the only image the chip loads itself.
# --entry 0 because link_chip.ld places .text.init (_start) first in ISRAM.
$(BUILD)/flash.hex: $(BUILD)/t_chip_flash.bin | $(BUILD)
	python3 ../tools/mkbootimg.py $< $@ --entry 0x0 --size 69632 \
	    --bin $(BUILD)/flash.bin

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
