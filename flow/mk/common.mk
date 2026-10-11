# =============================================================
# GARUDA SoC -- make rules shared by both tracks
# flow/mk/common.mk, included by the top-level Makefile.
#
# Tool locations, the simulation macros and the targets both tracks
# depend on. Track A's targets are in flow/mk/track_a.mk, track B's
# in flow/mk/track_b.mk. A change here affects both tracks: ask the
# owner of flow/ (track B) for it in the status sheet.
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

# irun 15.2: HAL, and every run whose coverage IMC 15.2 has to read.
IRUN152 ?= /home/install/INCISIVE152/tools/bin/irun
GENUS   ?= /home/install/GENUS211/tools/bin/genus

# RISC-V tools and the golden model
RISCV_DV_ROOT ?= $(HOME)/external/riscv-dv
RISCV_GNU     ?= /home/vivado/2025.2/Vitis/gnu/riscv/linux_toolchain/lin64/bin/riscv64-amd-linux-gnu
SPIKE         ?= $(HOME)/external/spike-inst/bin/spike

# run_test <filelist> <top> [<workdir, defaults to top>]
# The workdir arg keeps two runs of the same testbench (e.g. tb_ex_smoke against
# the stub and against the real DSU) from overwriting each other's logs.
WORKDIR = $(if $(3),$(3),$(2))
# TOOL-13: every simulation macro ends in scripts/sim_verdict.sh, so a target
# fails when the simulator fails, the log reports a failure, or the pass marker
# is missing. elab_* targets only elaborate and print no pass marker. A failing
# target now stops make: use `make -k` to run a whole group regardless.
RUN_TEST_PASS = $(if $(filter elab_%,$(WORKDIR)),,PASSED)
ifeq ($(SIM),xsim)
define run_test
	@mkdir -p $(SIM_DIR)/$(WORKDIR) && cd $(SIM_DIR)/$(WORKDIR) && \
	  $(XSIM_BIN)/xvlog -sv $(INCDIRS) \
	    $$(grep -v '^-\|^//\|^[[:space:]]*$$' $(CURDIR)/$(1) | sed 's|^|$(CURDIR)/|') > analyze.log 2>&1 && \
	  $(XSIM_BIN)/xelab $(2) -s $(2) -R > run.log 2>&1; rc=$$?; \
	  grep -ihE "^ERROR" analyze.log; \
	  grep -ihE "FAIL|PASSED|ERROR|Built simulation snapshot" run.log \
	    || echo "$(WORKDIR): no result line"; \
	  $(CURDIR)/scripts/sim_verdict.sh run.log $$rc $(RUN_TEST_PASS)
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
	    -l $(SIM_DIR)/$(WORKDIR)/run.log; rc=$$?; \
	  grep -ihE "FAIL|PASSED|ERROR|Built simulation snapshot" $(SIM_DIR)/$(WORKDIR)/run.log \
	    || echo "$(WORKDIR): no result line"; \
	  scripts/sim_verdict.sh $(SIM_DIR)/$(WORKDIR)/run.log $$rc $(RUN_TEST_PASS)
endef
endif

# run_tb_top <name>: the six constrained-random unit benches (top module tb_top).
# -64bit is required: the SV randomization library is only present as 64-bit
# here, and the default 32-bit invocation dies with
#   *F,RNCNL: ... libz.so.1 ... not a valid ELFCLASS32 library
# These bind to the REAL rtl/core sources via GARUDA_REAL_RTL; the testbenches
# also carry an inlined DUT snapshot for standalone VCS builds.
define run_tb_top
	@mkdir -p $(SIM_DIR)/unit_$(1) && \
	  $(XRUN) -64bit -f tb/core/filelist_$(1).f -top tb_top \
	    -xmlibdirname $(SIM_DIR)/unit_$(1)/xcelium.d \
	    -l $(SIM_DIR)/unit_$(1)/run.log > /dev/null 2>&1; rc=$$?; \
	  printf "%-22s PASS=%-5s FAIL=%-4s SVA_FAIL=%s\n" "$(1)" \
	    "$$(grep -c '\[PASS\]' $(SIM_DIR)/unit_$(1)/run.log)" \
	    "$$(grep -c '\[FAIL\]' $(SIM_DIR)/unit_$(1)/run.log)" \
	    "$$(grep -c '\*E,ASRTST' $(SIM_DIR)/unit_$(1)/run.log)"; \
	  scripts/sim_verdict.sh $(SIM_DIR)/unit_$(1)/run.log $$rc '\[PASS\]'
endef

# run_tb_elem <name>: the per-element SV unit benches (Sec. 18.2 directed tests,
# block level). One core element from the block diagram per target, verified on
# its own against AERO-GARUDA-DS-001. These follow the same SystemVerilog
# convention as the six tb_top benches -- interface + bound SVA, rand/constraint
# stimulus, reference model, covergroup, [PASS]/[FAIL] scoreboard -- so they
# need -64bit for the randomisation library and their top module is tb_top.
#
# Unlike run_tb_top this keeps the log's RESULT and coverage lines, which is
# what actually tells you WHICH check failed rather than only how many did.
# See Docs/CORE_ELEMENT_VERIFICATION.md for the element -> spec section ->
# C-test mapping.
define run_tb_elem
	@mkdir -p $(SIM_DIR)/elem_$(1) && \
	  $(XRUN) -64bit -f tb/core/filelist_$(1).f -top tb_top \
	    -xmlibdirname $(SIM_DIR)/elem_$(1)/xcelium.d \
	    -l $(SIM_DIR)/elem_$(1)/run.log > /dev/null 2>&1; rc=$$?; \
	  printf "%-26s PASS=%-6s FAIL=%-4s SVA_FAIL=%-4s %s\n" "$(1)" \
	    "$$(grep -c '\[PASS\]' $(SIM_DIR)/elem_$(1)/run.log)" \
	    "$$(grep -c '\[FAIL\]' $(SIM_DIR)/elem_$(1)/run.log)" \
	    "$$(grep -c '\*E,ASRTST' $(SIM_DIR)/elem_$(1)/run.log)" \
	    "$$(grep -hE '^ RESULT:' $(SIM_DIR)/elem_$(1)/run.log | head -1)"; \
	  grep -hE '\[FAIL\]|\[SVA-FAIL\]|^\*E|^xmelab: \*E' $(SIM_DIR)/elem_$(1)/run.log | head -20; \
	  scripts/sim_verdict.sh $(SIM_DIR)/elem_$(1)/run.log $$rc 'RESULT: ALL CHECKS PASSED'
endef

# run_blk <filelist> <top> <workdir> [<extra xrun arguments>]
# Rev 4.0 block and chip benches (GARUDA-SYS-001; Docs/DECISIONS.md D-4..D-20).
# Every one is self-checking, prints [PASS]/[FAIL] lines and "RESULT:".
define run_blk
	@mkdir -p $(SIM_DIR)/$(3) && \
	  $(XRUN) -64bit -f $(1) -top $(2) -xmlibdirname $(SIM_DIR)/$(3)/xcelium.d \
	    -l $(SIM_DIR)/$(3)/run.log $(4) > /dev/null 2>&1; rc=$$?; \
	  printf "%-14s " "$(3)"; grep -hE "^RESULT:|checks=|TB: .* checks" $(SIM_DIR)/$(3)/run.log | tr '\n' ' '; \
	  n=$$(grep -c '\*E,ASRTST' $(SIM_DIR)/$(3)/run.log); \
	  [ "$$n" = 0 ] && echo || echo " ** $$n ASSERTION FAILURE(S), not counted in RESULT"; \
	  grep -hE "\[FAIL\]|^xmelab: \*E|^xmvlog: \*E|\*E,ASRTST" $(SIM_DIR)/$(3)/run.log | head -10; \
	  scripts/sim_verdict.sh $(SIM_DIR)/$(3)/run.log $$rc PASSED
endef

# run_uvm <name> <-covdut arguments> <filelist> <top> <test name prefix>
# UVM block environments (stage 2). Run under irun 15.2 so the coverage opens in
# IMC. irun prints one tool error on every UVM run, "ncsim: *E,IMPDLL" (it cannot
# build its own DPI export stub on this machine); the simulation is unaffected
# and that one line is ignored here. Any other error fails the run.
# The Incisive tools must be first on PATH for these runs: with Xcelium first,
# irun 15.2 writes a coverage model that IMC 15.2 cannot load.
# Each environment has a register test, a directed test and a random test; the
# random test is run SEEDS times.
#   make uvm_clic            register test, directed test, random test x SEEDS
#   make uvm_clic SEEDS=50
SEEDS ?= 20
UVM_IRUN = $(IRUN152) -64bit -uvm -uvmhome CDNS-1.2 -coverage all -covoverwrite
define run_uvm
	@export PATH=$(dir $(IRUN152)):$$PATH; \
	 D=$(SIM_DIR)/uvm_$(1); mkdir -p $$D; rm -rf $$D/cov_work $$D/INCA_libs; fail=0; \
	 C="$(UVM_IRUN) -covworkdir $$D/cov_work $(2) -nclibdirname $$D/INCA_libs"; \
	 run() { $$C $$1 +UVM_TESTNAME=$$2 -svseed $$3 -covtest $$4 -l $$D/$$4.log > /dev/null 2>&1; \
	   if grep -q 'RESULT: PASSED' $$D/$$4.log && [ "$$(grep -E '\*[EF],' $$D/$$4.log | grep -vc IMPDLL)" = 0 ] && ! grep -q 'SVA-FAIL' $$D/$$4.log; \
	   then echo "uvm_$(1)  $$4 PASS"; else echo "uvm_$(1)  $$4 FAIL"; fail=1; fi; }; \
	 run "-f $(3) -top $(4)" $(5)_reg_test 1 reg_s1; \
	 run -R $(5)_directed_test 1 directed_s1; \
	 s=1; while [ $$s -le $(SEEDS) ]; do run -R $(5)_random_test $$s random_s$$s; s=$$((s+1)); done; \
	 [ $$fail -eq 0 ]
endef

# ---- software both tracks run -------------------------------------------------
.PHONY: sw
sw:
	$(MAKE) -C sw all
