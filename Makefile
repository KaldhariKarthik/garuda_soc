# =============================================================
# GARUDA SoC -- top-level Makefile
#
# Two simulator back-ends, selected with SIM=:
#   SIM=xrun  (default) -- Cadence Xcelium, the signoff flow
#   SIM=xsim            -- Vivado xsim, for machines without Cadence tools
# Both consume the same .f filelists, so a target verified under one is
# running exactly the same source list under the other.
# =============================================================

SIM      ?= xrun
XRUN      = xrun
SIM_DIR   = sim

# Vivado xsim back-end: filelists carry -incdir/-sv, which xvlog does not accept
# from a file, so they are stripped here and re-applied on the command line.
XSIM_BIN ?= /home/vivado/2025.2/Vivado/bin
INCDIRS   = -i $(CURDIR)/rtl/common -i $(CURDIR)/rtl/core -i $(CURDIR)/rtl/dsu

# run_test <filelist> <top> [<workdir, defaults to top>]
# The workdir arg keeps two runs of the same testbench (e.g. tb_ex_smoke against
# the stub and against the real DSU) from overwriting each other's logs.
WORKDIR = $(if $(3),$(3),$(2))
ifeq ($(SIM),xsim)
define run_test
	@mkdir -p $(SIM_DIR)/$(WORKDIR) && cd $(SIM_DIR)/$(WORKDIR) && \
	  $(XSIM_BIN)/xvlog -sv $(INCDIRS) \
	    $$(grep -v '^-\|^//\|^[[:space:]]*$$' $(CURDIR)/$(1) | sed 's|^|$(CURDIR)/|') > analyze.log 2>&1 && \
	  $(XSIM_BIN)/xelab $(2) -s $(2) -R > run.log 2>&1; \
	  grep -ihE "^ERROR" analyze.log; \
	  grep -ihE "FAIL|PASSED|ERROR|Built simulation snapshot" run.log \
	    || echo "$(WORKDIR): no result line"
endef
else
# NOTE: xrun runs from the REPO ROOT, not from sim/<workdir>. The .f files list
# source paths relative to the repo root, and xrun resolves them against its own
# cwd -- so cd-ing into sim/<workdir> first (as the xsim leg does, where the
# paths are rewritten absolute by the sed) made every filelist unresolvable:
#   xrun: *F,BDARGF: command line argument file 'rtl/core/filelist_core_dsu.f'
#         could not be opened for reading
# Outputs are redirected into sim/<workdir> instead of chdir-ing there.
define run_test
	@mkdir -p $(SIM_DIR)/$(WORKDIR) && \
	  $(XRUN) -f $(1) -top $(2) \
	    -xmlibdirname $(SIM_DIR)/$(WORKDIR)/xcelium.d \
	    -l $(SIM_DIR)/$(WORKDIR)/run.log; \
	  grep -ihE "FAIL|PASSED|ERROR|Built simulation snapshot" $(SIM_DIR)/$(WORKDIR)/run.log \
	    || echo "$(WORKDIR): no result line"
endef
endif

.PHONY: help check_tools clean elab_core elab_core_dsu \
        test_ex test_ex_dsu test_idex test_exmem test_pipe test_csr test_trap \
        test_core sw isa_tests test_boot test_c regress regress_wait test_flag2

help:
	@echo "GARUDA SoC build targets:"
	@echo "  make check_tools     -- verify the selected simulator is on PATH"
	@echo "  make elab_core       -- elaborate core standalone (inert DSU stub)"
	@echo "  make elab_core_dsu   -- elaborate core + REAL DSU (integration)"
	@echo "  make test_core       -- run every core unit smoke"
	@echo "  make test_ex_dsu     -- EX smoke against the real DSU"
	@echo "  make sw              -- build bare-metal tests (boot6, ctest1, dsu_flag2)"
	@echo "  make isa_tests       -- build riscv-tests rv32ui + rv32um"
	@echo "  make test_boot       -- 6-instruction boot smoke through tb_boot"
	@echo "  make test_c          -- first C test (crt0 + stack + .bss + M-ext)"
	@echo "  make test_flag2      -- DSU FLAG-2 compute->read ordering probe"
	@echo "  make regress         -- full ISA regression + Spike lockstep"
	@echo "  make regress_wait    -- same, with AHB wait states injected"
	@echo "  make clean           -- remove all simulation artifacts"
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

# ---- elaboration ----
elab_core:
	$(call run_test,rtl/core/filelist_core.f,garuda_core_top,elab_core)

elab_core_dsu:
	$(call run_test,rtl/core/filelist_core_dsu.f,garuda_core_top,elab_core_dsu)

# ---- core unit smokes ----
test_ex:
	$(call run_test,tb/core/filelist_ex_smoke.f,tb_ex_smoke)

test_ex_dsu:
	$(call run_test,tb/core/filelist_ex_smoke_dsu.f,tb_ex_smoke,tb_ex_smoke_dsu)

test_idex:
	$(call run_test,tb/core/filelist_idex_fwd.f,tb_id_ex_fwd)

test_exmem:
	$(call run_test,tb/core/filelist_exmem_ifid.f,tb_exmem_ifid)

test_pipe:
	$(call run_test,tb/core/filelist_pipe_ctrl.f,tb_pipe_ctrl)

test_csr:
	$(call run_test,tb/core/filelist_csr_file.f,tb_csr_file)

test_trap:
	$(call run_test,tb/core/filelist_trap_ctrl.f,tb_trap_ctrl)

test_core: test_ex test_ex_dsu test_idex test_exmem test_pipe test_csr test_trap

clean:
	rm -rf $(SIM_DIR) xcelium.d xrun.history xrun.log xrun.key
	rm -rf INCA_libs *.shm waves.shm .simvision cov_work
	rm -rf xsim.dir *.jou *.pb *.wdb
	rm -f *.log *.vcd *.fsdb

# =============================================================================
# Software + full-pipeline flows
# =============================================================================
sw:
	$(MAKE) -C sw all

isa_tests:
	$(MAKE) -C sw/riscv-tests all

BOOT_ARGS = -f tb/soc/filelist_boot.f -top tb_boot

test_boot: sw
	@mkdir -p $(SIM_DIR)/tb_boot
	@$(XRUN) $(BOOT_ARGS) -xmlibdirname $(SIM_DIR)/tb_boot/xcelium.d \
	   -l $(SIM_DIR)/tb_boot/run.log \
	   +HEX=sw/build/boot6.hex +COMMIT=$(SIM_DIR)/tb_boot/commit.log +MAXCYC=2000 \
	   | grep -E "TOHOST|PASSED|FAILED|TIMEOUT"

test_c: sw
	@mkdir -p $(SIM_DIR)/tb_boot
	@$(XRUN) $(BOOT_ARGS) -xmlibdirname $(SIM_DIR)/tb_boot/xcelium.d \
	   -l $(SIM_DIR)/tb_boot/ctest1.log \
	   +HEX=sw/build/ctest1.hex +COMMIT=$(SIM_DIR)/tb_boot/ctest1.commit.log \
	   +MAXCYC=20000 +QUIET | grep -E "TOHOST|PASSED|FAILED|TIMEOUT"

test_flag2: sw
	@mkdir -p $(SIM_DIR)/tb_boot
	@$(XRUN) $(BOOT_ARGS) -xmlibdirname $(SIM_DIR)/tb_boot/xcelium.d \
	   -l $(SIM_DIR)/tb_boot/flag2.log \
	   +HEX=sw/build/dsu_flag2.hex +COMMIT=$(SIM_DIR)/tb_boot/flag2.commit.log \
	   +MAXCYC=2000 +DBGACC | grep -E "ACC:|TOHOST|PASSED|FAILED|TIMEOUT" | head -40

regress: isa_tests
	@./scripts/run_regression.sh

regress_wait: isa_tests
	@RUNDIR=$(SIM_DIR)/regress_wait EXTRA_ARGS="+IWAIT=2 +DWAIT=3" MAXCYC=400000 \
	   ./scripts/run_regression.sh
