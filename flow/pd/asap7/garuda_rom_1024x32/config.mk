# Mock boot-ROM block (EXPLORATORY): 16.686 x 83.300 um, approved 2026-10-13.
# Holds NO boot image; the real ROM gets it at the foundry stage.
export GARUDA_ROOT ?= /home/aneesh/garuda_soc
export DESIGN_NAME     = garuda_rom_1024x32
export DESIGN_NICKNAME = garuda_garuda_rom_1024x32
export BLOCK_W = 16.686
export BLOCK_H = 83.300
include $(GARUDA_ROOT)/flow/pd/asap7/block_common.mk
