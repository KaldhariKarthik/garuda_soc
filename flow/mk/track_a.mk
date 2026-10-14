# =============================================================================
# flow/mk/track_a.mk -- Track A (core, DSU, ...) targets on the open-tool flow.
#
#   make -f flow/mk/track_a.mk help
#
# Every run goes through tools/run/garuda_run.py (strict verdict, logs with
# header/footer, xfail classification, history). Results land in
# logs/<blk>/summary/ (committed) and logs/<blk>/raw/ (ignored).
# Environment: tools/run/env.sh (pinned open tools; does not touch Cadence).
# Handbook: Docs/handbook/ (H2 = running, verdicts, logs).
# =============================================================================
SHELL  := /bin/bash
.SHELLFLAGS := -o pipefail -c
ROOT   := $(shell git rev-parse --show-toplevel)
ENV    := cd $(ROOT) && source tools/run/env.sh &&
RUN    := $(ENV) $$PYTHON tools/run/garuda_run.py suite
JOBS   ?= 6
SEED   ?=
SEEDARG = $(if $(SEED),--seed $(SEED),)

VERILATOR_WANT := Verilator 5.052
SPIKE_WANT     := 1.1.1-dev

.PHONY: help check_tools_a sw_open core_units core_elements core_smokes core_isa \
        core_isa_rand core_sanity core_extra core_directed dsu_vectors dsu_model baseline_a \
        baseline_report core_covtests core_rvfi core_cosim core_archtest core_riscv_dv core_stress \
        core_endurance instret_report dsu_mut dsu_units fast_a nightly_a soak_a tier_report \
        dsu_units_spec

help:
	@echo "Track A targets (open tools):"
	@echo "  check_tools_a     check the pinned tool versions (fails on mismatch)"
	@echo "  sw_open           build ISA + sw/tests images with the xPack toolchain"
	@echo "  core_units        6 unit benches"
	@echo "  core_elements     14 element benches"
	@echo "  core_smokes       7 directed smokes"
	@echo "  core_isa          riscv-tests on tb_boot + Spike lockstep"
	@echo "  core_isa_rand     same, random I/D wait states"
	@echo "  core_sanity       12 sanity programs"
	@echo "  core_extra        boot6, ctest1, dsu_flag2"
	@echo "  core_directed     t_core_* directed tests (W1..)"
	@echo "  core_csr          csr_file-level benches (T-12 level stack, ...)"
	@echo "  core_halt         debug halt vs running program with waited stores (RDC-1)"
	@echo "  debug_block       debug block bench (JTAG, DTM, DMI, DM, SBA)"
	@echo "  dsu_units_spec    DSU: six sub-units against the spec (+ 6 negative controls, DSU-18 reproducer)"
	@echo "  debug_chip        chip-level tests through the debug path (tb_chip)"
	@echo "  debug_chip_diag   same, diagnostic reset-edge shim (TB-30): all must pass"
	@echo "  fv_core_trap      formal: trap_ctrl properties (T-13/T-14/TC-1/TC-3)"
	@echo "  core_csr_map      all 4096 CSR addresses: RTL vs contract vs Spike"
	@echo "  fv_core_csr       formal: csr_file properties (C-16 ..)"
	@echo "  fv_core_rdc1      formal: debug halt never breaks a bus transfer (core + DM)"
	@echo "  fv_core           all core formal suites"
	@echo "  dsu_model         DSU vs its model (445 vectors)"
	@echo "  baseline_a        all of the above, keep going; then baseline_report"
	@echo "  selftest_runners  qualify runner, oracle and bug check (planted failures)"
	@echo "  baseline_record   write logs/core/evidence/baseline_<sha>.txt"
	@echo "  bugs_check / bugs_index / bugs_open   bug register"
	@echo "  -- core environment (plan WP5) --"
	@echo "  core_covtests     coverage-closure programs (t_cov_*, t_dsu_ovf_raw xfail DSU-14)"
	@echo "  core_rvfi         5.1: RVFI port vs the commit-log probe"
	@echo "  core_cosim        5.2/5.3: every program in step with Spike (co-simulation)"
	@echo "  core_archtest     5.4: riscv-arch-test 3.10.0, signatures vs Spike"
	@echo "  core_riscv_dv     5.5: riscv-dv (pygen) programs in co-simulation [DV_SEEDS=1-10 regenerates]"
	@echo "  core_stress       5.10: 1000 seeds of reset/halt/WFI/interrupt/fault storms"
	@echo "  core_endurance    5.12: >= 1e9 co-simulation-checked instructions; instret_report"
	@echo "  throughput_a      P0.11 throughput benchmark"
	@echo "  -- DSU --"
	@echo "  dsu_mut           planted DSU defects (each must fail for its reason)"
	@echo "  dsu_units         dsu-verification sub-block benches on the real RTL"
	@echo "  fv_dsu            DSU properties (SBY) + negative controls"
	@echo "  -- coverage / formal --"
	@echo "  cov_a             core + DSU code and functional coverage, reports with waivers"
	@echo "  fv_cov_unreach    formal evidence for the coverage exclusions"
	@echo "  -- regression tiers (H9) --"
	@echo "  fast_a            merge-blocking set (~3 min)"
	@echo "  regress_a         everything above except the nightly extras; regress_a_report"
	@echo "  nightly_a         regress_a + arch-test, stress, riscv-dv, DSU mutants/units/formal"
	@echo "  soak_a            endurance + diversity report"
	@echo "  options: JOBS=$(JOBS)  SEED=<n>"

check_tools_a:
	@$(ENV) set -e; \
	v=$$($$VERILATOR --version); echo "verilator : $$v"; \
	case "$$v" in "$(VERILATOR_WANT)"*) ;; *) echo "FAIL: want $(VERILATOR_WANT)"; exit 1;; esac; \
	vc=$$($$VERILATOR_COV --version 2>&1 | sed -n 1p); echo "verilator_coverage : $$vc"; \
	case "$$vc" in *"5.052"*) ;; *) echo "FAIL: verilator_coverage not 5.052"; exit 1;; esac; \
	s=$$($$SPIKE --help 2>&1 | sed -n 1p); echo "spike     : $$s"; \
	case "$$s" in *"$(SPIKE_WANT)"*) ;; *) echo "FAIL: want spike $(SPIKE_WANT)"; exit 1;; esac; \
	g=$$($$RISCV_BIN/$${RISCV_PREFIX}gcc --version | sed -n 1p); echo "gcc       : $$g"; \
	p=$$($$PYTHON --version); echo "python    : $$p"; \
	$$PYTHON -c 'import tomllib' || { echo "FAIL: python lacks tomllib (need >= 3.11)"; exit 1; }; \
	echo "sby       : $$($$OSS_CAD/bin/sby --version 2>&1 | sed -n 1p)"; \
	echo "yosys     : $$($$OSS_CAD/bin/yosys -V 2>&1 | sed -n 1p)"; \
	T=$${GARUDA_TOOLS:-$$HOME/tools}; \
	for pin in riscv-formal:c992aa61fdfe riscv-arch-test:6e8a45123f14 riscv-dv:0d71c2b666de; do \
	    n=$${pin%%:*}; want=$${pin#*:}; \
	    got=$$(git -C $$T/src/$$n rev-parse --short=12 HEAD 2>/dev/null || echo missing); \
	    echo "$$n : $$got"; [ "$$got" = "$$want" ] || { echo "FAIL: $$n want $$want"; exit 1; }; \
	done; \
	sv=$$($$T/sail/bin/sail_riscv_sim --version 2>&1 | sed -n 1p); echo "sail      : $$sv"; \
	[ "$$sv" = "0.15" ] || { echo "FAIL: want sail 0.15"; exit 1; }; \
	fz=$$($$T/venv-a/bin/python -m pip freeze 2>/dev/null | tr 'A-Z' 'a-z'); \
	for pk in riscof==1.25.3 riscv-config==3.18.3 riscv-isac==0.18.0 pyvsc==0.9.1.10086043874 pyyaml==6.0.3; do \
	    echo "$$fz" | grep -qx "$$pk" || { echo "FAIL: venv-a lacks $$pk"; exit 1; }; \
	done; echo "venv-a    : riscof 1.25.3, riscv-config 3.18.3, riscv-isac 0.18.0, pyvsc, pyyaml 6.0.3"; \
	echo "OK: pinned tools present"

# Images with the open toolchain: env.sh exports RISCV_BIN/RISCV_PREFIX/RISCV_TESTS,
# which sw/toolchain.mk takes as given (P0.7; no command-line overrides needed).
sw_open:
	@$(ENV) set -e; \
	$(MAKE) -s -C sw toolchain; \
	$(MAKE) -s -C sw/riscv-tests; \
	$(MAKE) -s -C sw chip; \
	$(MAKE) -s -C sw $(addprefix build/,$(addsuffix .hex,ctest1 boot6 dsu_flag2 t_loadbranch t_mem \
	    t_clic t_cov t_buserr t_irq t_wfi t_flush t_dsu t_mtip t_hold_flush_matrix t_dsu_b2b \
	    t_core_mret_buserr t_core_wfi_buserr t_core_ctl t_core_ctl_arch t_core_irq_nest t_core_preempt t_perf_mix \
	    t_cov_fault t_cov_csr t_cov_illegal t_cov_dsu t_cov_rereset t_cov_irq t_cov_misfetch t_exc_priority t_dsu_macsat_rd t_dsu_gate t_cov_vplan t_cov_wfi_mti t_dsu_ovf_raw)); \
	echo "ISA images : $$(ls sw/riscv-tests/build/*.hex | wc -l) (elf: $$(ls sw/riscv-tests/build/*.elf | wc -l))"; \
	echo "sw/tests   : $$(ls sw/build/*.hex | wc -l) hex"

core_units:     ; @$(RUN) tb/core/run/units.toml    --jobs $(JOBS) $(SEEDARG)
core_elements:  ; @$(RUN) tb/core/run/elements.toml --jobs $(JOBS) $(SEEDARG)
core_smokes:    ; @$(RUN) tb/core/run/smokes.toml   --jobs $(JOBS) $(SEEDARG)
core_isa:       ; @$(RUN) tb/core/run/isa.toml      --jobs $(JOBS) $(SEEDARG)
core_isa_rand:  ; @$(RUN) tb/core/run/isa_rand.toml --jobs $(JOBS) $(SEEDARG)
core_sanity:    ; @$(RUN) tb/core/run/sanity.toml   --jobs $(JOBS) $(SEEDARG)
core_extra:     ; @$(RUN) tb/core/run/extra.toml    --jobs $(JOBS) $(SEEDARG)
core_directed:  ; @$(RUN) tb/core/run/directed.toml --jobs $(JOBS) $(SEEDARG)
core_covtests:  ; @$(RUN) tb/core/run/covtests.toml --jobs $(JOBS) $(SEEDARG)
core_rvfi:      ; @$(RUN) tb/core/run/rvfi.toml     --jobs $(JOBS) $(SEEDARG)
core_cosim:     ; @$(RUN) tb/core/run/cosim.toml    --jobs $(JOBS) $(SEEDARG)
core_archtest:  ; @$(RUN) tb/core/run/archtest.toml --jobs $(JOBS) $(SEEDARG)
# plan 5.5: riscv-dv (pygen, GARUDA target) programs in step with Spike;
# DV_SEEDS regenerates the programs first (slow: ~1 min per program)
DV_SEEDS ?=
core_riscv_dv:
	@$(if $(DV_SEEDS),$(ENV) $$PYTHON tools/gen/build_riscv_dv.py --seeds $(DV_SEEDS) --jobs $(JOBS) &&) \
	 $(RUN) tb/core/run/riscv_dv.toml --jobs $(JOBS) $(SEEDARG)
# plan 5.12: endurance, >= 1e9 co-simulation-checked instructions + diversity
core_endurance: ; @$(RUN) tb/core/run/endurance.toml --jobs $(JOBS)
instret_report: ; @$(ENV) $$PYTHON tools/run/instret_report.py
# plan 5.10: reset / halt / WFI / interrupt / fault storms, one row per seed
# (tools/gen/gen_stress_manifest.py --seeds 1000)
core_stress:
	@$(RUN) tb/core/run/stress.toml --jobs $(JOBS); r1=$$?; \
	 $(RUN) tb/core/run/stress_halt.toml --jobs $(JOBS); r2=$$?; [ $$r1 -eq 0 ] && [ $$r2 -eq 0 ]
core_csr:       ; @$(RUN) tb/core/run/csr.toml      --jobs $(JOBS) $(SEEDARG)
core_halt:      ; @$(RUN) tb/core/run/halt.toml     --jobs $(JOBS) $(SEEDARG)
debug_block:    ; @$(RUN) tb/debug/run/debug.toml   --jobs $(JOBS) $(SEEDARG)
debug_chip:     ; @$(RUN) tb/debug/run/chip.toml    --jobs $(JOBS) $(SEEDARG)
debug_chip_diag: ; @$(RUN) tb/debug/run/chip_diag.toml --jobs $(JOBS) $(SEEDARG)

# DSU vectors: the generator must write exactly 445 tests and its own
# independent cross-check (DSUModel vs ArchDSU) must read CLEAN.
dsu_vectors:
	@$(ENV) set -e; mkdir -p logs/dsu/raw/vec; \
	$$PYTHON tools/gen/DSU_gen.py --count 400 --seed 1 --outdir logs/dsu/raw/vec > logs/dsu/raw/vec/gen.log 2>&1; \
	grep -qE 'wrote 448 tests' logs/dsu/raw/vec/gen.log || { echo "FAIL: generator did not write 448 tests"; cat logs/dsu/raw/vec/gen.log; exit 1; }; \
	grep -qE 'cross-check *: CLEAN' logs/dsu/raw/vec/gen.log || { echo "FAIL: DSUModel vs ArchDSU not CLEAN"; exit 1; }; \
	mkdir -p logs/dsu/raw/vec_clamp; \
	$$PYTHON tools/gen/DSU_gen.py --clamp-walk 600 --seed 2 --outdir logs/dsu/raw/vec_clamp > logs/dsu/raw/vec_clamp/gen.log 2>&1; \
	grep -qE 'wrote 33368 tests' logs/dsu/raw/vec_clamp/gen.log || { echo "FAIL: clamp walk did not write 33368 tests"; exit 1; }; \
	grep -qE 'cross-check *: CLEAN' logs/dsu/raw/vec_clamp/gen.log || { echo "FAIL: clamp walk oracles not CLEAN"; exit 1; }; \
	mkdir -p logs/dsu/raw/vec10k; \
	$$PYTHON tools/gen/DSU_gen.py --count 10000 --seed 7 --outdir logs/dsu/raw/vec10k > logs/dsu/raw/vec10k/gen.log 2>&1; \
	grep -qE 'wrote 10048 tests' logs/dsu/raw/vec10k/gen.log || { echo "FAIL: 10k set did not write 10048 tests"; exit 1; }; \
	grep -qE 'cross-check *: CLEAN' logs/dsu/raw/vec10k/gen.log || { echo "FAIL: 10k set oracles not CLEAN"; exit 1; }; \
	for a in 0 1 2; do mkdir -p logs/dsu/raw/vec_ovf$$a; \
	  $$PYTHON tools/gen/DSU_gen.py --ovf-walk $$a --outdir logs/dsu/raw/vec_ovf$$a > logs/dsu/raw/vec_ovf$$a/gen.log 2>&1; \
	  grep -qE 'wrote 65544 tests' logs/dsu/raw/vec_ovf$$a/gen.log || { echo "FAIL: ovf walk $$a did not write 65544 tests"; exit 1; }; \
	  grep -qE 'cross-check *: CLEAN' logs/dsu/raw/vec_ovf$$a/gen.log || { echo "FAIL: ovf walk $$a oracles not CLEAN"; exit 1; }; done; \
	echo "dsu vectors: 448 + clamp walk 33368 + 10048 random (F09.TC2) + 3 x 65544 overflow walks (F10.COV5), cross-check CLEAN"

dsu_model: dsu_vectors
	@$(RUN) tb/dsu/run/dsu.toml $(SEEDARG)

# Gate A baseline: every suite, keep going, then one report.
baseline_a: check_tools_a sw_open
	-@$(MAKE) -s -f flow/mk/track_a.mk core_units core_elements core_smokes core_isa \
	    core_isa_rand core_sanity core_extra core_directed core_csr core_halt dsu_model debug_block
	@$(MAKE) -s -f flow/mk/track_a.mk baseline_report

baseline_report:
	@$(ENV) for f in logs/core/summary/{units,elements,smokes,isa,isa_rand,sanity,extra,directed,csr,halt}.txt logs/dsu/summary/model.txt logs/debug/summary/block.txt; do \
	    [ -f "$$f" ] && { echo "== $$f"; tail -4 "$$f"; }; done

# ---- runner qualification (Gate A): every planted failure must be caught ----
#  1 selftest      : planted FAIL/BLOCKED outcomes + SVA liveness (rc must be 0)
#  2 selftest_xpass: a stale xfail entry must make the suite fail (rc must be 1)
#  3 lockstep_negctl.py: N0 match, N2..N5 caught; prepares N1
#  4 negctl_prog   : N1 corrupted image must FAIL
#  5 selftest_reason: an expected FAIL for the wrong reason must not count (rc must be 1)
#  6 negctl_t12 / negctl_preempt: the T-12 / PREEMPT_DIS programs on mutant RTL
#    must FAIL, each with its own named reason (fail_reason)
#  7 negctl_elem   : element benches on a mutant of their DUT must FAIL (named reason)
.PHONY: selftest_runners
selftest_runners:
	@$(ENV) set -e; \
	$$PYTHON tools/run/garuda_run.py suite tb/core/selftest/selftest.toml --jobs $(JOBS); \
	if $$PYTHON tools/run/garuda_run.py suite tb/core/selftest/selftest_xpass.toml > logs/flow/summary/selftest_xpass.out 2>&1; \
	then echo "FAIL: a stale xfail entry did not fail the suite"; exit 1; \
	else echo "[selftest_xpass] stale xfail entry rejected as required"; fi; \
	if $$PYTHON tools/run/garuda_run.py suite tb/core/selftest/selftest_reason.toml > logs/flow/summary/selftest_reason.out 2>&1; \
	then echo "FAIL: an expected FAIL with the wrong reason was accepted"; exit 1; \
	elif grep -q 'UNEXPECTED *wrong_reason' logs/flow/summary/selftest_reason.out; \
	then echo "[selftest_reason] expected FAIL with the wrong reason rejected as required"; \
	else echo "FAIL: selftest_reason failed for another reason (see logs/flow/summary/selftest_reason.out)"; exit 1; fi; \
	$$PYTHON tb/core/selftest/lockstep_negctl.py; \
	$$PYTHON tools/run/garuda_run.py suite tb/core/selftest/negctl_prog.toml; \
	$$PYTHON tools/run/garuda_run.py suite tb/core/selftest/negctl_t12.toml; \
	$$PYTHON tools/run/garuda_run.py suite tb/core/selftest/negctl_preempt.toml; \
	$$PYTHON tools/run/garuda_run.py suite tb/core/selftest/negctl_elem.toml; \
	$$PYTHON tools/run/garuda_run.py suite tb/core/selftest/negctl_cosim.toml --jobs 6; \
	bash tools/bugs/selftest_bugs.sh; \
	$$PYTHON tools/run/garuda_fv.py tb/core/selftest/fv_selftest.toml; \
	echo "selftest_runners: PASS (every planted failure caught)"

# ---- CSR existence against the contract (tools/csr_map.py, Design_Docs/regs/core_csr.yaml) ----
.PHONY: core_csr_map
core_csr_map:
	@$(ENV) set -e; D=logs/core/raw/csrmap_img; rm -rf $$D; mkdir -p $$D; \
	$$PYTHON tools/csr_map.py gen $$D/csr_sweep.S; \
	$$RISCV_BIN/$${RISCV_PREFIX}gcc -march=rv32im_zicsr -mabi=ilp32 -mno-relax -fno-pic -static -nostdlib \
	    -nostartfiles -Wa,--no-warn -T sw/common/link.ld -no-pie -Wl,--no-warn-rwx-segments \
	    $$D/csr_sweep.S -o $$D/csr_sweep.elf; \
	$$RISCV_BIN/$${RISCV_PREFIX}objcopy -O binary $$D/csr_sweep.elf $$D/csr_sweep.bin; \
	$$PYTHON tools/elf2hex.py $$D/csr_sweep.bin $$D/csr_sweep.hex > /dev/null; \
	$$PYTHON tools/run/garuda_run.py suite tb/core/run/csr_map.toml; \
	$$SPIKE --isa=rv32i_zmmul_zicsr_zifencei_zicntr --pmpregions=0 --triggers=0 -m0x10000000:0x40000 \
	    --disable-dtb --priv=m --pc=0x10000000 --log-commits -l $$D/csr_sweep.elf > /dev/null 2> $$D/spike.log; \
	$$PYTHON tools/csr_map.py diff $$D/csr_sweep.elf logs/core/raw/csr_map/csr_sweep.commit.log $$D/spike.log \
	    $$RISCV_BIN/$${RISCV_PREFIX}nm | tee logs/core/summary/csr_map_diff.txt

# ---- formal (SymbiYosys; result classes Docs/handbook/H6_formal.md) ----
.PHONY: fv_core_trap fv_core_csr fv_core_rdc1 fv_core
fv_core_trap: ; @$(ENV) $$PYTHON tools/run/garuda_fv.py tb/core/formal/core_trap.toml --jobs 4
fv_core_csr:  ; @$(ENV) $$PYTHON tools/run/garuda_fv.py tb/core/formal/csr_file.toml --jobs 4
fv_core_rdc1: ; @$(ENV) $$PYTHON tools/run/garuda_fv.py tb/core/formal/rdc1.toml --jobs 4
fv_dsu:        ; @$(ENV) $$PYTHON tools/run/garuda_fv.py tb/dsu/formal/dsu.toml --jobs 4
fv_cov_unreach: ; @$(ENV) $$PYTHON tools/run/garuda_fv.py tb/core/formal/cov_unreach.toml --jobs 2
fv_core: fv_core_trap fv_core_csr fv_core_rdc1 fv_cov_unreach

# ---- bug register (Docs/bugs/<blk>.md -> generated Docs/BUGS.md) ----
.PHONY: bugs_check bugs_index bugs_open
freeze_a:   ; @$(ENV) $$PYTHON tools/run/freeze.py
bugs_check: ; @$(ENV) $$PYTHON tools/bugs/bugs.py check
bugs_index: ; @$(ENV) $$PYTHON tools/bugs/bugs.py index
bugs_open:  ; @$(ENV) $$PYTHON tools/bugs/bugs.py open

# ---- Gate A evidence: baseline record from the summaries ----
.PHONY: baseline_record
baseline_record:
	@$(ENV) $$PYTHON tools/run/baseline_record.py --notes logs/core/evidence/baseline_notes_b90b481.txt > /dev/null && \
	grep -E "design SHA|classification" logs/core/evidence/baseline_$$(git rev-parse --short=12 HEAD).txt

# ---- everything Track A owns, one command (keeps going, then one report) ----
# ---- coverage (E8/E9/D5, H5): every core and DSU suite in coverage mode, then the
# reports (design code per metric per module, design functional bins, testbench
# code, waivers with reasons). Only passing runs count.
COV_CORE_SUITES = units elements smokes isa isa_rand sanity extra directed csr halt csr_map covtests
.PHONY: cov_core cov_dsu cov_core_report cov_dsu_report cov_a
cov_core:
	-@$(ENV) for s in $(COV_CORE_SUITES); do \
	    $$PYTHON tools/run/garuda_run.py suite tb/core/run/$$s.toml --coverage --jobs $(JOBS) | tail -1; done
cov_dsu:
	-@$(ENV) $$PYTHON tools/run/garuda_run.py suite tb/dsu/run/dsu.toml --coverage | tail -1
cov_core_report:
	@$(ENV) $$PYTHON tools/cov/cov_report.py tb/core/cov/cov.toml
cov_dsu_report:
	@$(ENV) $$PYTHON tools/cov/cov_report.py tb/dsu/cov/cov.toml
cov_a: cov_core cov_dsu
	-@$(MAKE) -s -f flow/mk/track_a.mk cov_core_report > /dev/null
	@$(MAKE) -s -f flow/mk/track_a.mk cov_dsu_report > /dev/null; \
	grep -h "^verdict\|^TOTAL" logs/core/summary/cov_core.txt logs/dsu/summary/cov_dsu.txt

# ---- P0.11: simulation throughput (normal and coverage build, one run at a time) ----
.PHONY: throughput_a
throughput_a:
	@$(ENV) $$PYTHON tools/run/throughput.py

.PHONY: regress_a regress_a_report
regress_a: check_tools_a sw_open
	-@$(MAKE) -s -f flow/mk/track_a.mk core_units core_elements core_smokes core_isa core_isa_rand \
	    core_sanity core_extra core_directed core_covtests core_rvfi core_cosim core_csr core_halt core_csr_map dsu_model \
	    debug_block debug_chip debug_chip_diag dsu_units_spec fv_core selftest_runners JOBS=$(JOBS)
	@$(MAKE) -s -f flow/mk/track_a.mk regress_a_report

# ---- regression tiers (plan 1.4 / E12; times measured 2026-10-11, H9) ---------
# fast_a     merge-blocking, 2 min 43 s on 16 jobs (measured): unit/element benches, ISA, sanity,
#            directed + coverage programs, DSU model, trap formal, runner self-tests
# nightly_a  regress_a + arch-test, 1000-seed stress, riscv-dv, DSU planted
#            defects, DSU formal (~1.5 h)
# soak_a     the 1e9-instruction endurance + diversity report, riscv-formal (hours)
fast_a: check_tools_a sw_open
	-@$(MAKE) -s -f flow/mk/track_a.mk core_units core_elements core_isa core_sanity core_directed \
	    core_covtests dsu_model dsu_units_spec fv_core_trap selftest_runners JOBS=$(JOBS)
	@$(MAKE) -s -f flow/mk/track_a.mk tier_report TIER_SUITES="$(FAST_SUITES)"
nightly_a: regress_a
	-@$(MAKE) -s -f flow/mk/track_a.mk core_archtest core_stress core_riscv_dv dsu_mut dsu_units dsu_units_spec fv_dsu JOBS=$(JOBS)
	@$(MAKE) -s -f flow/mk/track_a.mk tier_report TIER_SUITES="$(NIGHTLY_SUITES)"
soak_a:
	-@$(MAKE) -s -f flow/mk/track_a.mk core_endurance JOBS=$(JOBS)
	@$(MAKE) -s -f flow/mk/track_a.mk tier_report TIER_SUITES="logs/core/summary/endurance.tsv"
	@$(MAKE) -s -f flow/mk/track_a.mk instret_report
dsu_mut:  ; @$(RUN) tb/dsu/run/dsu_mut.toml --jobs $(JOBS)
dsu_units: ; @$(RUN) tb/dsu/run/units.toml --jobs $(JOBS)
dsu_units_spec: ; @$(RUN) tb/dsu/run/units_spec.toml --jobs $(JOBS)
FAST_SUITES = $(addprefix logs/core/summary/,units.tsv elements.tsv isa.tsv sanity.tsv directed.tsv covtests.tsv fv_trap.tsv) \
              logs/dsu/summary/model.tsv \
              logs/flow/summary/selftest.tsv
NIGHTLY_SUITES = $(addprefix logs/core/summary/,archtest.tsv stress.tsv stress_halt.tsv riscv_dv.tsv) \
                 logs/dsu/summary/dsu_mut.tsv logs/dsu/summary/units.tsv logs/dsu/summary/fv_dsu.tsv
# one line per suite; exit 1 on a missing suite or any UNEXPECTED / XPASS row
tier_report:
	@bad=0; for f in $(TIER_SUITES); do \
	    [ -f "$$f" ] || { printf '%-26s %s\n' "$$f" "NOT RUN"; bad=1; continue; }; \
	    awk -F'\t' -v f="$$(basename $$(dirname $$(dirname $$f)))/$$(basename $$f .tsv)" \
	      'NR==2{for(i=1;i<=NF;i++) if($$i=="class") c=i} NR>2{n++; if($$c=="OK") ok++; else if($$c ~ /^X(FAIL|BLOCK):/) x++; else bad++} \
	       END{printf "%-26s %4d tests: %4d OK, %3d expected-fail (bug ID), %d UNEXPECTED\n", f, n, ok, x, bad; exit (bad > 0)}' "$$f" || bad=1; \
	done; if [ $$bad = 0 ]; then echo "tier: PASS"; else echo "tier: FAIL (see above)"; exit 1; fi

# The report is the verdict of regress_a (which keeps going past failing suites):
# it exits 1 if any suite is missing or has an UNEXPECTED/XPASS row, or the bug
# register check fails.
regress_a_report:
	@$(ENV) printf '%-26s %s\n' SUITE RESULT; bad=0; \
	for f in logs/core/summary/{units,elements,smokes,isa,isa_rand,sanity,extra,directed,covtests,rvfi,cosim,csr,halt,csr_map}.tsv \
	         logs/dsu/summary/model.tsv logs/debug/summary/{block,chip,chip_diag}.tsv logs/dsu/summary/units_spec.tsv \
	         logs/core/summary/{fv_trap,fv_csr,fv_rdc1,fv_cov}.tsv \
	         logs/flow/summary/{selftest,negctl_prog,negctl_t12,negctl_preempt,negctl_elem,negctl_cosim,fv_selftest}.tsv; do \
	    [ -f "$$f" ] || { printf '%-26s %s\n' "$$f" "NOT RUN"; bad=1; continue; }; \
	    awk -F'\t' -v f="$$(basename $$(dirname $$(dirname $$f)))/$$(basename $$f .tsv)" \
	      'NR==2{for(i=1;i<=NF;i++) if($$i=="class") c=i} NR>2{n++; if($$c=="OK") ok++; else if($$c ~ /^X(FAIL|BLOCK):/) x++; else bad++} \
	       END{printf "%-26s %3d tests: %3d OK, %3d expected-fail (bug ID), %d UNEXPECTED\n", f, n, ok, x, bad; exit (bad > 0)}' "$$f" || bad=1; \
	done; grep -h "Gate A\|selftest_runners: PASS" logs/flow/summary/*.txt 2>/dev/null | head -2; \
	$$PYTHON tools/bugs/bugs.py check | tail -1; $$PYTHON tools/bugs/bugs.py check > /dev/null || bad=1; \
	if [ $$bad = 0 ]; then echo "regress_a: PASS"; else echo "regress_a: FAIL (see above)"; exit 1; fi
