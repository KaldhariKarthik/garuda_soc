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

# -----------------------------------------------------------------------------
# One verdict for every simulation the macros below run: scripts/sim_verdict.sh
# (Docs/bugs/archive/BUGS_HISTORY.md TOOL-13). A run has passed only if all three hold:
#   the simulator's exit status is 0     a failed assertion gives 1, $fatal 2,
#                                        a compile error 1
#   the log holds the bench's pass line  a bench that stops early prints none
#   the log holds no failure line        [FAIL], [SVA-FAIL], RESULT: FAILED, or
#                                        any tool error (*E) or fatal (*F)
# No one of them is enough: a bench that prints RESULT: FAILED and calls $finish
# exits 0, and a bench killed by $fatal may already have printed RESULT: PASSED.
# The log is deleted before each run, so a simulator that never started cannot
# be judged on the log of the run before. A failing target stops make: use
# `make -k` to run a whole group regardless. `make selfcheck_runners` plants
# each kind of failure and checks that every macro reports it.
# -----------------------------------------------------------------------------
VERDICT = scripts/sim_verdict.sh
# judge <log> <pass line>: the verdict of the run whose exit status is in $$rc.
# Says nothing when the run passed; prints the reasons and fails when it did not.
judge = v=$$($(VERDICT) $(1) $$rc '$(2)'); r=$$?; [ $$r -eq 0 ] || echo "$$v"; exit $$r

# run_test <filelist> <top> [<workdir, defaults to top>] [<pass line, default ALL CHECKS PASSED; - for none>]
#          [<extra xrun arguments, xrun leg only>]
# The workdir arg keeps two runs of the same testbench (e.g. tb_ex_smoke against
# the stub and against the real DSU) from overwriting each other's logs.
WORKDIR = $(if $(3),$(3),$(2))
RUN_TEST_PASS = $(if $(filter -,$(4)),,$(if $(4),$(4),ALL CHECKS PASSED))
ifeq ($(SIM),xsim)
define run_test
	@mkdir -p $(SIM_DIR)/$(WORKDIR) && cd $(SIM_DIR)/$(WORKDIR) && rm -f run.log && \
	  $(XSIM_BIN)/xvlog -sv $(INCDIRS) \
	    $$(grep -v '^-\|^//\|^[[:space:]]*$$' $(CURDIR)/$(1) | sed 's|^|$(CURDIR)/|') > analyze.log 2>&1 && \
	  $(XSIM_BIN)/xelab $(2) -s $(2) -R > run.log 2>&1; rc=$$?; \
	  grep -ihE "^ERROR" analyze.log; \
	  grep -ihE "FAIL|PASSED|ERROR|Built simulation snapshot" run.log \
	    || echo "$(WORKDIR): no result line"; \
	  v=$$($(CURDIR)/$(VERDICT) run.log $$rc '$(RUN_TEST_PASS)'); r=$$?; [ $$r -eq 0 ] || echo "$$v"; exit $$r
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
	@mkdir -p $(SIM_DIR)/$(WORKDIR) && rm -f $(SIM_DIR)/$(WORKDIR)/run.log; \
	  $(XRUN) -f $(1) -top $(2) \
	    -xmlibdirname $(SIM_DIR)/$(WORKDIR)/xcelium.d \
	    -l $(SIM_DIR)/$(WORKDIR)/run.log $(5) > /dev/null 2>&1; rc=$$?; \
	  grep -ihE "FAIL|PASSED|ERROR|Built simulation snapshot" $(SIM_DIR)/$(WORKDIR)/run.log 2> /dev/null \
	    || echo "$(WORKDIR): no result line"; \
	  $(call judge,$(SIM_DIR)/$(WORKDIR)/run.log,$(RUN_TEST_PASS))
endef
endif

# run_tb_top <name> [<filelist directory, default tb/core>] [<extra xrun arguments>]
# The six constrained-random unit benches (top module tb_top).
# -64bit is required: the SV randomization library is only present as 64-bit
# here, and the default 32-bit invocation dies with
#   *F,RNCNL: ... libz.so.1 ... not a valid ELFCLASS32 library
# These bind to the REAL rtl/core sources via GARUDA_REAL_RTL; the testbenches
# also carry an inlined DUT snapshot for standalone VCS builds.
define run_tb_top
	@mkdir -p $(SIM_DIR)/unit_$(1) && rm -f $(SIM_DIR)/unit_$(1)/run.log; \
	  $(XRUN) -64bit -f $(if $(2),$(2),tb/core)/filelist_$(1).f -top tb_top \
	    -xmlibdirname $(SIM_DIR)/unit_$(1)/xcelium.d \
	    -l $(SIM_DIR)/unit_$(1)/run.log $(3) > /dev/null 2>&1; rc=$$?; \
	  printf "%-22s PASS=%-5s FAIL=%-4s SVA_FAIL=%s\n" "$(1)" \
	    "$$(grep -c '\[PASS\]' $(SIM_DIR)/unit_$(1)/run.log 2> /dev/null)" \
	    "$$(grep -c '\[FAIL\]' $(SIM_DIR)/unit_$(1)/run.log 2> /dev/null)" \
	    "$$(grep -c '\*E,ASRTST' $(SIM_DIR)/unit_$(1)/run.log 2> /dev/null)"; \
	  $(call judge,$(SIM_DIR)/unit_$(1)/run.log,^ ?RESULT: .*PASSED)
endef

# run_tb_elem <name> [<filelist directory, default tb/core>] [<extra xrun arguments>]
# The per-element SV unit benches (Sec. 18.2 directed tests, block level).
# One core element from the block diagram per target, verified on
# its own against AERO-GARUDA-DS-001. These follow the same SystemVerilog
# convention as the six tb_top benches -- interface + bound SVA, rand/constraint
# stimulus, reference model, covergroup, [PASS]/[FAIL] scoreboard -- so they
# need -64bit for the randomisation library and their top module is tb_top.
#
# Unlike run_tb_top this keeps the log's RESULT and coverage lines, which is
# what actually tells you WHICH check failed rather than only how many did.
# See Docs/guides/CORE_ELEMENT_VERIFICATION.md for the element -> spec section ->
# C-test mapping. The pass line is any "RESULT: ... PASSED": thirteen benches
# print "RESULT: ALL CHECKS PASSED" and tb_clic_ctrl prints "RESULT: PASSED (n
# checks, 0 failed)".
define run_tb_elem
	@mkdir -p $(SIM_DIR)/elem_$(1) && rm -f $(SIM_DIR)/elem_$(1)/run.log; \
	  $(XRUN) -64bit -f $(if $(2),$(2),tb/core)/filelist_$(1).f -top tb_top \
	    -xmlibdirname $(SIM_DIR)/elem_$(1)/xcelium.d \
	    -l $(SIM_DIR)/elem_$(1)/run.log $(3) > /dev/null 2>&1; rc=$$?; \
	  printf "%-26s PASS=%-6s FAIL=%-4s SVA_FAIL=%-4s %s\n" "$(1)" \
	    "$$(grep -c '\[PASS\]' $(SIM_DIR)/elem_$(1)/run.log 2> /dev/null)" \
	    "$$(grep -c '\[FAIL\]' $(SIM_DIR)/elem_$(1)/run.log 2> /dev/null)" \
	    "$$(grep -c '\*E,ASRTST' $(SIM_DIR)/elem_$(1)/run.log 2> /dev/null)" \
	    "$$(grep -hE '^ ?RESULT:' $(SIM_DIR)/elem_$(1)/run.log 2> /dev/null | head -1)"; \
	  grep -hE '\[FAIL\]|\[SVA-FAIL\]|^\*E|^xmelab: \*E' $(SIM_DIR)/elem_$(1)/run.log 2> /dev/null | head -20; \
	  $(call judge,$(SIM_DIR)/elem_$(1)/run.log,^ ?RESULT: .*PASSED)
endef

# run_blk <filelist> <top> <workdir> [<extra xrun arguments>] [<pass line, default ^RESULT: PASSED; - for none>]
# Rev 4.0 block and chip benches (GARUDA-SYS-001; Docs/DECISIONS.md D-4..D-20).
# Every one is self-checking, prints [PASS]/[FAIL] lines and "RESULT:".
define run_blk
	@mkdir -p $(SIM_DIR)/$(3) && rm -f $(SIM_DIR)/$(3)/run.log; \
	  $(XRUN) -64bit -f $(1) -top $(2) -xmlibdirname $(SIM_DIR)/$(3)/xcelium.d \
	    -l $(SIM_DIR)/$(3)/run.log $(4) > /dev/null 2>&1; rc=$$?; \
	  printf "%-14s " "$(3)"; grep -hE "^RESULT:|checks=|TB: .* checks" $(SIM_DIR)/$(3)/run.log 2> /dev/null | tr '\n' ' '; \
	  n=$$(grep -c '\*E,ASRTST' $(SIM_DIR)/$(3)/run.log 2> /dev/null); \
	  [ "$${n:-0}" = 0 ] && echo || echo " ** $$n ASSERTION FAILURE(S), not counted in RESULT"; \
	  grep -hE "\[FAIL\]|^xmelab: \*E|^xmvlog: \*E|\*E,ASRTST" $(SIM_DIR)/$(3)/run.log 2> /dev/null | head -10; \
	  $(call judge,$(SIM_DIR)/$(3)/run.log,$(if $(filter -,$(5)),,$(if $(5),$(5),^RESULT: PASSED)))
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
# SEED0 is added to the seed of every random run: the nightly sets it from the date,
# so that each night runs seeds no night before it ran.
SEED0 ?= 0
# UVM_TAG is added to the run directory. The gates set it, so that a gate run of a
# few seeds does not replace the 20-seed coverage databases the chart is made from.
UVM_TAG ?=
UVM_IRUN = $(IRUN152) -64bit -uvm -uvmhome CDNS-1.2 -coverage all -covoverwrite
define run_uvm
	@export PATH=$(dir $(IRUN152)):$$PATH; \
	 D=$(SIM_DIR)/uvm_$(1)$(UVM_TAG); mkdir -p $$D; rm -rf $$D/cov_work $$D/INCA_libs; fail=0; \
	 C="$(UVM_IRUN) -covworkdir $$D/cov_work $(2) -nclibdirname $$D/INCA_libs"; \
	 run() { $$C $$1 +UVM_TESTNAME=$$2 -svseed $$3 -covtest $$4 -l $$D/$$4.log > /dev/null 2>&1; \
	   if grep -q 'RESULT: PASSED' $$D/$$4.log && [ "$$(grep -E '\*[EF],' $$D/$$4.log | grep -vc IMPDLL)" = 0 ] && ! grep -qE 'SVA-FAIL|^\[FAIL\]' $$D/$$4.log; \
	   then echo "uvm_$(1)  $$4 PASS"; else echo "uvm_$(1)  $$4 FAIL"; fail=1; fi; }; \
	 run "-f $(3) -top $(4)" $(5)_reg_test 1 reg_s1; \
	 run -R $(5)_directed_test 1 directed_s1; \
	 s=1; while [ $$s -le $(SEEDS) ]; do n=$$((s+$(SEED0))); run -R $(5)_random_test $$n random_s$$n; s=$$((s+1)); done; \
	 [ $$fail -eq 0 ]
endef

# ---- software both tracks run -------------------------------------------------
.PHONY: sw
sw:
	$(MAKE) -C sw all

# =============================================================================
# make selfcheck_runners: does every runner fail when its test fails?
# (Docs/bugs/archive/BUGS_HISTORY.md TOOL-13, TOOL-14; task 1.1 of the pre-PDK plan.)
#
# The Icarus runner is tried too when iverilog is on PATH. The coverage script
# and the Genus script take minutes per run and are not planted here; their
# verdicts were checked by hand when they were rewritten (Docs/bugs/track_b.md).
#
# The planted bench tb/selfcheck/tb_sc.sv fails on purpose, one way per mode:
# a [FAIL] line, a failed assertion behind RESULT: PASSED, no result line at
# all, $fatal after the result line, and a compile error. Each simulation macro
# runs every mode; it must pass the control mode and fail all the others. The
# UVM macro is given a test name that does not exist. The program runners
# (sanity, ISA regression, chip) are given a cycle budget no program can meet.
# A runner that gives the wrong verdict either way fails this target.
# =============================================================================
SC_FL     = tb/selfcheck/filelist_sc.f
SC_BROKEN = tb/selfcheck/filelist_sc_broken.f
SC_BAD    = fail assert silent fatal broken
SC_OUT    = $(SIM_DIR)/selfcheck

sc_test_broken: ; $(call run_test,$(SC_BROKEN),tb_top,sc_test_broken,^RESULT: PASSED)
sc_unit_broken: ; $(call run_tb_top,sc_broken,tb/selfcheck)
sc_elem_broken: ; $(call run_tb_elem,sc_broken,tb/selfcheck)
sc_blk_broken:  ; $(call run_blk,$(SC_BROKEN),tb_top,sc_blk_broken)
sc_test_%: ; $(call run_test,$(SC_FL),tb_top,sc_test_$*,^RESULT: PASSED,+SC=$*)
sc_unit_%: ; $(call run_tb_top,sc,tb/selfcheck,+SC=$*)
sc_elem_%: ; $(call run_tb_elem,sc,tb/selfcheck,+SC=$*)
sc_blk_%:  ; $(call run_blk,$(SC_FL),tb_top,sc_blk_$*,+SC=$*)

# the UVM macro on the CLIC environment: its three real tests, then three test
# names that do not exist
sc_uvm_pass sc_uvm_fail: SEEDS = 1
sc_uvm_pass: ; $(call run_uvm,sc,-covdut clic_top,tb/clic/uvm/filelist_clic_uvm.f,tb_clic_uvm,clic)
sc_uvm_fail: ; $(call run_uvm,sc,-covdut clic_top,tb/clic/uvm/filelist_clic_uvm.f,tb_clic_uvm,no_such)

# the chip bench with a time budget of one microsecond
sc_chip_fail: ; $(call run_blk,tb/soc/filelist_chip.f,tb_chip,sc_chip_fail,+MODE=basic +TEST=sw/build/t_chip_basic.hex +MAXUS=1)

.PHONY: selfcheck_runners sc_uvm_pass sc_uvm_fail sc_chip_fail
selfcheck_runners: sw isa_tests
	@mkdir -p $(SC_OUT); n=0; bad=0; \
	 try() { want=$$1; shift; n=$$((n+1)); \
	   if "$$@" > $(SC_OUT)/$$n.out 2>&1; then got=pass; else got=fail; fi; \
	   if [ $$got = $$want ]; then printf "  ok     must %-4s  %s\n" $$want "$$*"; \
	   else printf "  WRONG  must %-4s but did %s: %s  (output: $(SC_OUT)/$$n.out)\n" $$want $$got "$$*"; bad=$$((bad+1)); fi; }; \
	 for k in test unit elem blk; do \
	   try pass $(MAKE) -s sc_$${k}_pass; \
	   for m in $(SC_BAD); do try fail $(MAKE) -s sc_$${k}_$$m; done; \
	 done; \
	 try pass $(MAKE) -s sc_uvm_pass; \
	 try fail $(MAKE) -s sc_uvm_fail; \
	 try pass $(MAKE) -s test_chip_basic; \
	 try fail $(MAKE) -s sc_chip_fail; \
	 try pass env RUNDIR=$(SC_OUT)/sanity ./scripts/run_sanity.sh t_loadbranch; \
	 try fail env RUNDIR=$(SC_OUT)/sanity MAXCYC=10 ./scripts/run_sanity.sh t_loadbranch; \
	 try pass env RUNDIR=$(SC_OUT)/regress ./scripts/run_regression.sh add; \
	 try fail env RUNDIR=$(SC_OUT)/regress MAXCYC=10 ./scripts/run_regression.sh add; \
	 try pass python3 scripts/expand_filelist.py $(SC_BROKEN) --defines; \
	 try fail python3 scripts/expand_filelist.py tb/selfcheck/filelist_sc_unknown.f; \
	 if command -v iverilog > /dev/null 2>&1; then \
	   try pass ./scripts/run_sim.sh tb_top +SC=pass; \
	   for m in fail assert silent fatal; do try fail ./scripts/run_sim.sh tb_top +SC=$$m; done; \
	 else echo "  --     Icarus is not on PATH: scripts/run_sim.sh not tried"; fi; \
	 echo "selfcheck_runners: $$n runs, $$bad wrong verdict(s)"; [ $$bad -eq 0 ]
