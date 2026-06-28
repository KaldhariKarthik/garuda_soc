# =============================================================
# GARUDA SoC -- top-level Makefile
# =============================================================

XRUN     = xrun
SIM_DIR  = sim

.PHONY: help check_tools clean

help:
	@echo "GARUDA SoC build targets:"
	@echo "  make check_tools  -- verify Cadence tools are on PATH"
	@echo "  make clean        -- remove all simulation artifacts"
	@echo ""
	@echo "Per-block targets will be added as blocks are written."

check_tools:
	@which $(XRUN) > /dev/null || (echo "ERROR: xrun not in PATH"; exit 1)
	@$(XRUN) -version

clean:
	rm -rf $(SIM_DIR) xcelium.d xrun.history xrun.log xrun.key
	rm -rf INCA_libs *.shm waves.shm .simvision cov_work
	rm -f *.log *.vcd *.fsdb
