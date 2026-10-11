# =============================================================
# GARUDA SoC -- top-level Makefile
#
# The targets live in three files, so that two people working on two
# tracks never edit the same lines:
#   flow/mk/common.mk    tool paths, the simulation macros, shared targets
#   flow/mk/track_a.mk   core, DSU, AHB, bridge, DMA, debug, memories
#   flow/mk/track_b.mk   peripherals, clocks and resets, chip, static, UVM,
#                        synthesis, the licence-free local flow
# This file holds only what joins the two: help, check_tools, test_blocks,
# regress_all and clean.
#
# Two simulator back-ends, selected with SIM=:
#   SIM=xrun  (default) -- Cadence Xcelium, the signoff flow
#   SIM=xsim            -- Vivado xsim, for machines without Cadence tools
# =============================================================

.DEFAULT_GOAL := help

include flow/mk/common.mk
include flow/mk/track_a.mk
include flow/mk/track_b.mk

.PHONY: help help_head help_tail check_tools clean test_blocks regress_all

help: help_head help_a help_b help_tail

help_head:
	@echo "GARUDA SoC build targets:"
	@echo "  make check_tools     -- verify the selected simulator is on PATH"
	@echo "  make sw              -- build the bare-metal tests, the boot ROM and the chip programs"
	@echo "  make test_blocks     -- every block TB of both tracks"
	@echo "  make regress_all     -- core, elements, blocks, sanity, DSU, ISA and chip"
	@echo "  make clean           -- remove all simulation artifacts"

help_tail:
	@echo ""
	@echo "Select simulator with SIM=xrun (default) or SIM=xsim."

check_tools:
ifeq ($(SIM),xsim)
	@test -x $(XSIM_BIN)/xvlog || (echo "ERROR: xvlog not at $(XSIM_BIN)"; exit 1)
	@$(XSIM_BIN)/xvlog --version | head -1
else
	@which $(XRUN) > /dev/null || (echo "ERROR: xrun not in PATH"; exit 1)
	@$(XRUN) -version
endif

# Every block of both tracks. Clocks and reset first (track B's list starts
# with them) because everything else assumes them.
test_blocks: test_blocks_b test_blocks_a

# Everything that is expected to be green, in one command.
regress_all: $(REGRESS_A) $(REGRESS_B)

clean:
	rm -rf $(SIM_DIR) xcelium.d xrun.history xrun.log xrun.key
	rm -rf INCA_libs *.shm waves.shm .simvision cov_work
	rm -rf xsim.dir *.jou *.pb *.wdb
	rm -f *.log *.vcd *.fsdb
