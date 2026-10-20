# =============================================================================
# Shared settings for the GARUDA mock-memory blocks (ORFS hierarchical BLOCKS).
# EXPLORATORY. Included by each <block>/config.mk, which sets BLOCK_W/BLOCK_H.
# Dimensions approved 2026-10-13 (Docs/logs/pd/PD_LOG_2026-10-13.md §8).
# =============================================================================
export PLATFORM     = asap7
export VERILOG_FILES = $(GARUDA_ROOT)/flow/pd/asap7/mock/garuda_mock_srams.v
export SDC_FILE      = $(GARUDA_ROOT)/flow/pd/asap7/mock/block.sdc

# Die forced to the approved macro size; a 1 um core inset leaves room for the
# block's M4/M5 power ring (BLOCK_grid_strategy.tcl).
export DIE_AREA  = 0 0 $(BLOCK_W) $(BLOCK_H)
export CORE_AREA = 1 1 $(shell python3 -c "print(round($(BLOCK_W)-1,3), round($(BLOCK_H)-1,3))")

# As ORFS's mock-sram example: route the block on M2-M4 only, so the parent can
# route over it from M5 up; signal pins on the RIGHT edge (M4).
export MAX_ROUTING_LAYER     = M4
export MIN_CLK_ROUTING_LAYER = M2
export PDN_TCL               = $(PLATFORM_DIR)/openRoad/pdn/BLOCK_grid_strategy.tcl
export IO_CONSTRAINTS        = $(GARUDA_ROOT)/flow/pd/asap7/mock/io_right.tcl
export PLACE_PINS_ARGS       = -min_distance 2 -min_distance_in_tracks
export PLACE_DENSITY         = 0.30
