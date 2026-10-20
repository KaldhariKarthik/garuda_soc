# =============================================================================
# GARUDA on ASAP7: EXPLORATORY ORFS design config (B2, 2026-10-13)
#
# ASAP7 is a predictive 7 nm teaching PDK, used here only to exercise the flow.
# The target is TSMC 28 nm. NO timing, area or power number from an ASAP7 run
# carries over to 28 nm.
#
# Scope: full exploratory flow to GDS, approved 2026-10-13/14: mock memory
# blocks, floorplan, place, CTS, route, finish. P1, P2, P3 applied. Results are
# EXPLORATORY: no timing-closure claim, nothing about 28 nm.
#
# Use (from ~/tools/OpenROAD-flow-scripts/flow, after `source ../env.sh`):
#   make DESIGN_CONFIG=/home/aneesh/garuda_soc/flow/pd/asap7/config.mk \
#        WORK_HOME=$HOME/tools/garuda_pd FLOW_VARIANT=<run_name> synth
# Each run gets its own FLOW_VARIANT directory under WORK_HOME. Nothing is
# written into the repo or into the ORFS tree.
# =============================================================================
export PLATFORM    = asap7
# P2 (applied 2026-10-13): the core-only flow synthesises garuda_chip_core, which has
# no tri-states. garuda_chip_top is the pin-level wrapper whose tri-state
# lines become pad cells.
export DESIGN_NAME = garuda_chip_core
export DESIGN_NICKNAME = garuda

export GARUDA_ROOT ?= /home/aneesh/garuda_soc

# Sources, include dirs and defines come from the SAME filelist the
# simulations and scripts/run_synth.sh use (scripts/expand_filelist.py), so
# synthesis cannot drift from the simulated source list. Plus one PD-only
# file: black-box declarations of the named memory macros (P3).
export VERILOG_FILES = $(shell cd $(GARUDA_ROOT) && python3 scripts/expand_filelist.py rtl/soc/filelist_chip.f | sed 's|^|$(GARUDA_ROOT)/|')
# Memory macros: with BLOCKS set (default), ORFS hardens the PD-only mock models
# (flow/pd/asap7/mock/) into LEF + liberty and reads them as black boxes. With
# BLOCKS empty (e.g. `make ... BLOCKS=`), the stub declarations stand in.
export BLOCKS ?= garuda_sram_16384x32 garuda_sram_4096x32 garuda_rom_1024x32
ifeq ($(BLOCKS),)
  export VERILOG_FILES += $(GARUDA_ROOT)/flow/pd/asap7/garuda_sram_stubs.v
endif
export VERILOG_INCLUDE_DIRS = $(shell cd $(GARUDA_ROOT) && python3 scripts/expand_filelist.py rtl/soc/filelist_chip.f --incdirs | sed 's|-I|$(GARUDA_ROOT)/|g')
# P1: GARUDA_ICG_CELL + OPENROAD_CLKGATE map core_clk_gate onto the platform ICG
#     (ASAP7 ICGx1_ASAP7_75t_R via CLKGATE_MAP_FILE). Without OPENROAD_CLKGATE
#     the map would be a wire; P1's guard then fails elaboration.
# P3: GARUDA_SRAM_MACRO makes sram_wrapper instantiate the named macros
#     garuda_sram_16384x32 / garuda_sram_4096x32 / garuda_rom_1024x32, declared
#     as black boxes in garuda_sram_stubs.v. GARUDA_SRAM_BLACKBOX is NOT
#     defined: that branch is a constant-0 register and would trim the core.
#     SYNTH_MEMORY_MAX_BITS stays at 4096 and SYNTH_MOCK_LARGE_MEMORIES at 0,
#     so ORFS aborts if any memory were inferred as flops.
export VERILOG_DEFINES = $(shell cd $(GARUDA_ROOT) && python3 scripts/expand_filelist.py rtl/soc/filelist_chip.f --defines) \
                         -D GARUDA_ICG_CELL -D OPENROAD_CLKGATE -D GARUDA_SRAM_MACRO

# Constraints (ASAP7 time unit = 1 ps): the implementation is driven by the
# PRIMARY scenario, DIV2. The other DIVSEL modes are checked by separate STA
# runs on the routed database (flow/constraints/asap7/garuda_div{4,8,16}.sdc).
export SDC_FILE = $(GARUDA_ROOT)/flow/constraints/asap7/garuda_div2.sdc

# Floorplan (EXPLORATORY; approved 2026-10-13: 320 x 300 um start, up to
# 380 x 340 um if channels, the power grid or congestion need it; every
# change is recorded in Docs/logs/pd/PD_LOG_<date>.md).
export DIE_AREA  ?= 0 0 320 300
export CORE_AREA ?= 5 5 315 295
export MACRO_PLACEMENT_TCL = $(GARUDA_ROOT)/flow/pd/asap7/macro_place.tcl

# CTS: ORFS's default arguments plus -no_insertion_delay (BUGS PD-7). Without it,
# TritonCTS's macro/register latency balancer (CTS-0033) inserted ~2.1 ns of
# delay buffers on the aon_clk branch feeding the hclk mux, skewing hclk/pclk
# against aon_clk and creating ~1700 hold violations (and an OpenROAD crash in
# hold repair, TOOL-18). The aon/hclk/pclk trees must stay latency-aligned.
export CTS_ARGS ?= -sink_clustering_enable -repair_clock_nets -no_insertion_delay
export PLACE_DENSITY ?= 0.45
