# Mock DSRAM bank block (EXPLORATORY): 33.372 x 166.600 um, approved 2026-10-13.
export GARUDA_ROOT ?= /home/aneesh/garuda_soc
export DESIGN_NAME     = garuda_sram_4096x32
export DESIGN_NICKNAME = garuda_garuda_sram_4096x32
export BLOCK_W = 33.372
export BLOCK_H = 166.600
include $(GARUDA_ROOT)/flow/pd/asap7/block_common.mk
