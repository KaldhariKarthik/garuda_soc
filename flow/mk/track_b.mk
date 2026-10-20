# =============================================================
# GARUDA SoC -- make targets of track B
# flow/mk/track_b.mk, included by the top-level Makefile.
#
# Peripherals, clocks and resets, the chip top, static checks, the
# UVM block environments, synthesis and the licence-free local flow.
# Edited by the owner of track B only. Macros and tool paths are in
# flow/mk/common.mk; track A's targets are in flow/mk/track_a.mk.
# =============================================================

.PHONY: help_b test_crg test_clic test_timers test_apb_shim test_spim test_uart \
        test_i2c test_gpio test_pwm test_spis test_blocks_b \
        test_chip test_chip_basic test_chip_irq test_chip_wdt test_chip_flash \
        test_chip_uart test_chip_periph test_chip_integ test_chip_jtag elab_chip \
        docs check_docs static static_lint static_cdc static_xprop \
        uvm_clic uvm_timers uvm_pwm uvm_gpio uvm_crg uvm_spis uvm_i2c uvm_b \
        synth local local_sim local_lint local_synth uvm_local gate_b

help_b:
	@echo "  ---- track B: peripherals, clocks and resets, chip, flow ----"
	@echo "  make test_blocks_b   -- block TBs: crg clic timers apb_shim spim uart i2c gpio pwm spis"
	@echo "  make test_chip       -- whole chip from the pins: basic, irq, wdt, flash, uart, periph, integ, jtag"
	@echo "  make elab_chip       -- elaborate garuda_chip_top"
	@echo "  make static          -- HAL lint, clock-domain check, chip tests with X-propagation"
	@echo "  make uvm_clic        -- CLIC UVM environment with coverage (SEEDS=n); also"
	@echo "                          uvm_timers uvm_pwm uvm_gpio uvm_crg, and uvm_b for all five"
	@echo "  make synth           -- Genus structural synthesis check (latches, drivers)"
	@echo "  make local           -- licence-free flow: Icarus, Verilator lint, Yosys"
	@echo "  make uvm_local       -- the UVM environments under Verilator (no licence, no coverage)"
	@echo "  make cov_chart       -- coverage of every block from IMC, into Docs/coverage/"
	@echo "  make check_docs      -- are any .docx stale against their .md?"
	@echo "  make gate_b          -- the subset to pass before a push of track B"

# =============================================================================
# Block-level testbenches of track B. Clocks and reset first because everything
# else assumes them.
# =============================================================================
test_crg:     ; $(call run_blk,tb/clk_div/filelist_crg.f,tb_crg,tb_crg)                 ## 21/22 clock + reset
test_clic:    ; $(call run_blk,tb/clic/filelist_clic.f,tb_clic,tb_clic)                 ## 10 CLIC
test_timers:  ; $(call run_blk,tb/timers/filelist_timers.f,tb_timers,tb_timers)         ## 11 timers + WDT
test_apb_shim:; $(call run_blk,tb/common/filelist_shim.f,tb_apb_shim,tb_apb_shim)     ## shared peripheral front end
test_spim:    ; $(call run_blk,tb/spi_master/filelist_spim.f,tb_spim,tb_spim)          ## 13 SPI master + flash
test_uart:    ; $(call run_blk,tb/uart/filelist_uart.f,tb_uart,tb_uart)              ## 16/17/18 UART x3
test_i2c:     ; $(call run_blk,tb/i2c/filelist_i2c.f,tb_i2c,tb_i2c)                 ## 15 I2C master
test_gpio:    ; $(call run_blk,tb/gpio/filelist_gpio.f,tb_gpio,tb_gpio)              ## 19 GPIO
test_pwm:     ; $(call run_blk,tb/pwm/filelist_pwm.f,tb_pwm,tb_pwm)                 ## 20 PWM (in-house)
test_spis:    ; $(call run_blk,tb/spi_slave/filelist_spis.f,tb_spis,tb_spis)        ## 14 SPI slave (in-house)

BLOCKS_B = test_crg test_clic test_timers test_apb_shim test_spim test_uart test_i2c \
           test_gpio test_pwm test_spis
test_blocks_b: $(BLOCKS_B)

# =============================================================================
# Whole chip (garuda_chip_top) from the pins, real Boot ROM, boot_sel = 1:
#   basic  boot path, ILOCK, precise bus faults, DMA R-9
#   irq    DMA completion via CLIC, machine timer, WDT warning (WFI + clock gate)
#   wdt    a real watchdog reset: RSTREASON = WDT, DSRAM survives
#   jtag   halt -> load ISRAM over JTAG SBA -> mailbox -> resume -> run
# =============================================================================
CHIP_FL = tb/soc/filelist_chip.f
test_chip_basic: ; $(call run_blk,$(CHIP_FL),tb_chip,chip_basic,+MODE=basic +TEST=sw/build/t_chip_basic.hex)
test_chip_irq:   ; $(call run_blk,$(CHIP_FL),tb_chip,chip_irq,+MODE=irq +TEST=sw/build/t_chip_irq.hex)
test_chip_wdt:   ; $(call run_blk,$(CHIP_FL),tb_chip,chip_wdt,+MODE=wdt +TEST=sw/build/t_chip_wdt.hex)
test_chip_jtag:  ; $(call run_blk,$(CHIP_FL),tb_chip,chip_jtag,+MODE=jtag +TEST=sw/build/t_chip_jtag.hex +MAXUS=1500)
test_chip_flash: ; $(call run_blk,$(CHIP_FL),tb_chip,chip_flash,+MODE=flash +TEST=sw/build/flash.hex +MAXUS=3000)
test_chip_uart:  ; $(call run_blk,$(CHIP_FL),tb_chip,chip_uart,+MODE=basic +TEST=sw/build/t_chip_uart.hex)
test_chip_periph:; $(call run_blk,$(CHIP_FL),tb_chip,chip_periph,+MODE=basic +TEST=sw/build/t_chip_periph.hex +MAXUS=1200)
test_chip_integ: ; $(call run_blk,$(CHIP_FL),tb_chip,chip_integ,+MODE=basic +TEST=sw/build/t_chip_integ.hex +MAXUS=4000)
test_chip: sw test_chip_basic test_chip_irq test_chip_wdt test_chip_flash test_chip_uart test_chip_periph test_chip_integ test_chip_jtag

elab_chip:                                       ## whole-chip elaboration
	$(call run_blk,rtl/soc/filelist_chip.f,garuda_chip_top,elab_chip,-elaborate,-)

# =============================================================================
# Design documents. The .md is normative; the .docx is an export (see
# Design_Docs/README.md). check_docs fails if an export has fallen behind.
# =============================================================================
check_docs:                                   ## are any .docx stale against their .md?
	@python3 tools/check_docs.py --check

docs:                                         ## regenerate the .docx exports (needs pandoc)
	@command -v pandoc >/dev/null || { \
	  echo "pandoc not installed - the .md files remain normative, see Design_Docs/README.md"; \
	  exit 1; }
	@for f in Design_Docs/*.md; do \
	  [ "$$(basename $$f)" = "README.md" ] && continue; \
	  echo "  pandoc $$f"; \
	  pandoc -f gfm -t docx -o "$${f%.md}.docx" "$$f"; \
	done
	@python3 tools/check_docs.py --report

# =============================================================================
# Static checks (stage 1): rerun on every change to rtl/.
#   static_lint   HAL lint on the whole chip; fails on any error that is not in
#                 flow/2_static/hal_waivers.txt (matched by rule and file:line)
#   static_cdc    HAL clock-domain check on debug_top, the one async boundary
#   static_xprop  all eight chip programs with X-propagation (xrun -xprop F)
# HAL is the Incisive 15.2 one: the Xcelium 22.09 HAL does not run here.
# =============================================================================
static: static_lint static_cdc static_xprop      ## lint + clock-domain check + X-propagation

static_lint:
	@mkdir -p $(SIM_DIR)/static
	@$(IRUN152) -hal -64bit -f rtl/soc/filelist_chip.f -top garuda_chip_top -define SYNTHESIS \
	    -nclibdirname $(SIM_DIR)/static/INCA_libs -l $(SIM_DIR)/static/hal.log -f flow/2_static/hal.f > /dev/null 2>&1; \
	 rm -f hal.design_facts; \
	 n=0; new=0; \
	 for e in $$(grep -E 'hal[a-z]*: \*E,' $(SIM_DIR)/static/hal.log | sed -E 's/^hal[a-z]*: \*E,([A-Z0-9]+) \(\.\/([^,]*),([0-9]+).*/\1@\2:\3/'); do \
	   n=$$((n+1)); r=$${e%%@*}; fl=$${e#*@}; \
	   if grep -A1 -E "^  $$r " flow/2_static/hal_waivers.txt | grep -qF "$$fl" || \
	      { [ "$$r" = UNRCHS ] && grep -qE '^  UNRCHS +same line' flow/2_static/hal_waivers.txt; }; then :; \
	   else new=$$((new+1)); echo "  NOT WAIVED: $$r $$fl"; fi; \
	 done; \
	 echo "static_lint   HAL errors=$$n  not waived=$$new  (log: $(SIM_DIR)/static/hal.log)"; \
	 python3 tools/hal_baseline.py --check $(SIM_DIR)/static/hal.log; b=$$?; \
	 [ $$new -eq 0 ] && grep -q 'Analysis complete' $(SIM_DIR)/static/hal.log && [ $$b -eq 0 ]

# make static_lint_selfcheck: does the baseline gate fail when a count rises? It lowers one
# number of a COPY of the baseline by one and expects tools/hal_baseline.py to refuse.
.PHONY: static_lint_selfcheck
static_lint_selfcheck:
	@if [ ! -s $(SIM_DIR)/static/hal.log ]; then \
	   echo "static_lint_selfcheck: no $(SIM_DIR)/static/hal.log; run make static_lint first"; exit 1; fi; \
	 cp flow/2_static/hal_baseline.txt $(SIM_DIR)/hal_baseline.planted; \
	 awk 'BEGIN{d=0} /^W TIELOG /{ $$3=$$3-1; d=1 } {print}' $(SIM_DIR)/hal_baseline.planted > $(SIM_DIR)/hal_baseline.planted2; \
	 HAL_BASELINE=$(SIM_DIR)/hal_baseline.planted2 python3 tools/hal_baseline.py --check $(SIM_DIR)/static/hal.log > $(SIM_DIR)/hal_selfcheck.out 2>&1; \
	 if [ $$? -ne 0 ] && grep -q "RISEN" $(SIM_DIR)/hal_selfcheck.out; then echo "static_lint_selfcheck: ok, a rise of one finding fails the check"; \
	 else echo "static_lint_selfcheck: WRONG, the check did not fail on a rise"; exit 1; fi

static_cdc:
	@mkdir -p $(SIM_DIR)/static_cdc_debug
	@$(IRUN152) -hal -64bit -f rtl/third_party/timescale.f rtl/debug/jtag_tap.v rtl/debug/dtm.v \
	    rtl/debug/dmi_cdc.v rtl/debug/sba_master.v rtl/debug/debug_module.v rtl/debug/debug_top.v \
	    -incdir rtl/include -top debug_top -define SYNTHESIS \
	    -nclibdirname $(SIM_DIR)/static_cdc_debug/INCA_libs -l $(SIM_DIR)/static_cdc_debug/hal_cdc.log \
	    -halargs "-check CLOCKDOMAIN" > /dev/null 2>&1; \
	 rm -f hal.design_facts; \
	 c=$$(grep -cE '\*E,CLKDMN' $(SIM_DIR)/static_cdc_debug/hal_cdc.log); \
	 y=$$(grep -cE 'INSYNC' $(SIM_DIR)/static_cdc_debug/hal_cdc.log); \
	 echo "static_cdc    unsynchronised crossings=$$c (5 waived: the DMI payload)  synchronisers found=$$y"; \
	 [ $$c -le 5 ]

static_xprop: sw
	@mkdir -p $(SIM_DIR)/xprop; fail=0; \
	 for t in "basic:+MODE=basic +TEST=sw/build/t_chip_basic.hex" "irq:+MODE=irq +TEST=sw/build/t_chip_irq.hex" \
	          "wdt:+MODE=wdt +TEST=sw/build/t_chip_wdt.hex" "jtag:+MODE=jtag +TEST=sw/build/t_chip_jtag.hex +MAXUS=1500" \
	          "flash:+MODE=flash +TEST=sw/build/flash.hex +MAXUS=3000" "uart:+MODE=basic +TEST=sw/build/t_chip_uart.hex" \
	          "periph:+MODE=basic +TEST=sw/build/t_chip_periph.hex +MAXUS=1200" "integ:+MODE=basic +TEST=sw/build/t_chip_integ.hex +MAXUS=4000"; do \
	   n=$${t%%:*}; a=$${t#*:}; \
	   $(XRUN) -64bit -f tb/soc/filelist_chip.f -top tb_chip -xprop F $$a \
	       -xmlibdirname $(SIM_DIR)/xprop/xcelium.d -l $(SIM_DIR)/xprop/chip_$$n.log > /dev/null 2>&1; \
	   if grep -q 'RESULT: PASSED' $(SIM_DIR)/xprop/chip_$$n.log && ! grep -qE '\*[EF],' $(SIM_DIR)/xprop/chip_$$n.log; \
	   then echo "static_xprop  chip_$$n PASS"; else echo "static_xprop  chip_$$n FAIL"; fail=1; fi; \
	 done; [ $$fail -eq 0 ]

# =============================================================================
# UVM block environments (stage 2), with coverage, on irun 15.2. The macro and
# its notes are in flow/mk/common.mk (run_uvm).
#   make uvm_clic            register test, directed test, random test x SEEDS
#   make uvm_clic SEEDS=50
# =============================================================================
uvm_clic:                                        ## CLIC UVM environment, with coverage
	$(call run_uvm,clic,-covdut clic_top,tb/clic/uvm/filelist_clic_uvm.f,tb_clic_uvm,clic)

uvm_timers:                                      ## timers and watchdog UVM environment, with coverage
	$(call run_uvm,timers,-covdut timers_top,tb/timers/uvm/filelist_timers_uvm.f,tb_timers_uvm,tmr)

uvm_pwm:                                         ## PWM UVM environment, with coverage
	$(call run_uvm,pwm,-covdut garuda_pwm_top,tb/pwm/uvm/filelist_pwm_uvm.f,tb_pwm_uvm,pwm)

uvm_spis:                                        ## SPI slave UVM environment, with coverage
	$(call run_uvm,spis,-covdut garuda_spis_top,tb/spi_slave/uvm/filelist_spis_uvm.f,tb_spis_uvm,spis)

uvm_i2c:                                         ## I2C UVM environment, with coverage
	$(call run_uvm,i2c,-covdut garuda_i2c_top,tb/i2c/uvm/filelist_i2c_uvm.f,tb_i2c_uvm,i2c)

uvm_uart:                                        ## UART UVM environment, with coverage
	$(call run_uvm,uart,-covfile flow/cov/uart_uvm_dut.ccf,tb/uart/uvm/filelist_uart_uvm.f,tb_uart_uvm,uart)

uvm_gpio:                                        ## GPIO UVM environment, with coverage
	$(call run_uvm,gpio,-covdut garuda_gpio_top,tb/gpio/uvm/filelist_gpio_uvm.f,tb_gpio_uvm,gpio)

uvm_crg:                                         ## clock and reset UVM environment, with coverage
	$(call run_uvm,crg,-covdut clk_div -covdut reset_ctrl,tb/clk_div/uvm/filelist_crg_uvm.f,tb_crg_uvm,crg)

UVM_B = uvm_clic uvm_timers uvm_pwm uvm_gpio uvm_crg uvm_spis uvm_i2c uvm_uart
uvm_b: $(UVM_B)                                  ## the five UVM environments of track B

# =============================================================================
# Synthesis check with Cadence Genus (generic mapping, no library): unresolved
# modules, multiple drivers, latches. Structural only - not timing signoff.
# =============================================================================
synth:                                           ## whole chip
	@./scripts/run_genus.sh garuda_chip_top rtl/soc/filelist_chip.f

# =============================================================================
# Licence-free local flow (Icarus + Yosys + Verilator)
# =============================================================================
# These targets need no Cadence licence, no 28 nm library and no RISC-V
# toolchain, so they run on a laptop. They are NOT a substitute for the xrun
# signoff flow above: Icarus cannot build four of the block testbenches at all
# (three are vendored third-party PULP RTL), and nothing here says anything
# about timing. What they do give is a regression that anyone can reproduce
# from a clean checkout, which is the thing the project did not have.
#
#   make local_sim     every block testbench Icarus can build, with a summary
#   make local_lint    whole-chip Verilator lint
#   make local_synth   whole-chip Yosys synthesis + the latch gate
#   make local         all three, in that order
#
# Install: unpack the YosysHQ oss-cad-suite and put BOTH lib/ and bin/ on PATH,
# lib FIRST, and export VERILATOR_ROOT (Docs/bugs/archive/BUGS_HISTORY.md TOOL-2, TOOL-3).
local_sim:                                       ## all block TBs under Icarus
	@./scripts/run_sim.sh all

local_synth:                                     ## Yosys + latch gate
	@./scripts/run_synth.sh garuda_chip_top

# Verilator needs +incdir+, NOT -I with a space: given "-I path" it parses the
# sources that follow as top-module names (Docs/bugs/archive/BUGS_HISTORY.md TOOL-2).
local_lint:                                      ## whole-chip Verilator lint
	@set -e; \
	 inc=$$(python3 scripts/expand_filelist.py rtl/soc/filelist_chip.f --incdirs \
	        | sed 's/-I/+incdir+/g'); \
	 def=$$(python3 scripts/expand_filelist.py rtl/soc/filelist_chip.f --defines); \
	 src=$$(python3 scripts/expand_filelist.py rtl/soc/filelist_chip.f | tr '\n' ' '); \
	 echo "=== Verilator lint: garuda_chip_top ($$(echo $$src | wc -w) sources) ==="; \
	 verilator --lint-only -sv --timing --top-module garuda_chip_top flow/2_static/verilator_waivers.vlt $$inc $$def $$src; \
	 echo "local_lint: no warning that is not accepted in flow/2_static/verilator_waivers.vlt"

# The UVM environments under Verilator with the IEEE UVM library (no coverage;
# see the header of the script). One environment at a time, two compiler jobs.
uvm_local:                                       ## every UVM environment under Verilator
	@./scripts/run_uvm_local.sh all

local: local_sim local_lint local_synth

# =============================================================================
# Coverage of every block, and the chart (Docs/coverage/COVERAGE_BY_BLOCK.md).
#   make cov_runs    every test of flow/regress/garuda.vsif under irun 15.2 with
#                    coverage, COV_JOBS at a time (the same runs vManager makes)
#   make cov_chart   those runs, the five UVM environments, then IMC merges and
#                    reports, then the chart. Every number in it is IMC's.
#   make cov_report  only the last two steps, on the databases already there
# By hand: flow/COMMANDS.md, "Coverage of every block".
# =============================================================================
COV_JOBS ?= 6
.PHONY: cov_runs cov_chart cov_report
cov_runs: sw isa_tests
	@rm -rf $(SIM_DIR)/run_test; mkdir -p $(SIM_DIR)/run_test; \
	 grep -oE 'test [a-zA-Z0-9_]+ *\{\}' flow/regress/garuda.vsif | awk '{print $$2}' > $(SIM_DIR)/run_test/tests.txt; \
	 xargs -P $(COV_JOBS) -I{} sh -c 'flow/regress/run_test.sh {} > $(SIM_DIR)/run_test/{}.out 2>&1' < $(SIM_DIR)/run_test/tests.txt; \
	 n=$$(wc -l < $(SIM_DIR)/run_test/tests.txt); p=$$(grep -l 'GARUDA_RESULT: PASS' $(SIM_DIR)/run_test/*.out | wc -l); \
	 echo "cov_runs: $$p of $$n runs passed"; \
	 for f in $(SIM_DIR)/run_test/*.out; do grep -q 'GARUDA_RESULT: PASS' $$f || echo "  NOT PASSED: $$f"; done; \
	 [ $$p -eq $$n ]

cov_report:
	@python3 tools/gen/cov_chart.py collect && python3 tools/gen/cov_chart.py report

cov_chart: cov_runs uvm_b uvm_dma cov_report

# =============================================================================
# make check_tree: nothing that must stay out of a public repository is tracked
# (libraries, PDK files, layouts, licence files, the licence server address),
# and no bug ID is defined twice. tools/check_tree.py; part of both gates.
# make check_tree_selfcheck plants a .lib and checks that the check fails.
# =============================================================================
.PHONY: check_tree check_tree_selfcheck
# make check_applicability: every own RTL module has a row in Docs/coverage/APPLICABILITY.md and every
# "not applicable" has its reason (tools/gen/applicability.py).
.PHONY: check_applicability applicability
check_applicability:
	@python3 tools/gen/applicability.py --check
applicability:
	@python3 tools/gen/applicability.py

check_tree:
	@python3 tools/check_tree.py && python3 tools/gen/applicability.py --check

check_tree_selfcheck:
	@f=flow/planted_for_check_tree.lib; echo "library (planted) { }" > $$f; git add -N $$f; \
	 if python3 tools/check_tree.py > /dev/null; then r=1; echo "check_tree_selfcheck: WRONG, a tracked .lib was not reported"; \
	 else r=0; echo "check_tree_selfcheck: ok, a planted .lib fails the check"; fi; \
	 git reset -q -- $$f; rm -f $$f; exit $$r

# Everything of track B that regress_all runs.
REGRESS_B = test_blocks_b test_chip

# =============================================================================
# The gate of track B: pass it before every push. A subset that runs in under
# ten minutes; the nightly runs everything. The five UVM environments run with
# GATE_SEEDS random seeds each instead of 20. -k: every part runs, so one
# failure does not hide another.
# =============================================================================
GATE_SEEDS ?= 3
GATE_B = check_tree static_lint test_blocks_b test_chip uvm_b
gate_b:
	@if $(MAKE) --no-print-directory -k $(GATE_B) SEEDS=$(GATE_SEEDS) UVM_TAG=_gate; \
	 then echo "gate_b: PASS"; else echo "gate_b: FAIL"; exit 1; fi

# The nightly run of this track: scripts/nightly.sh (plan task 1.4). It writes its page
# under flow/nightly/ and never commits.
.PHONY: nightly_b
nightly_b:
	@./scripts/nightly.sh b

# Coverage waivers of the five closed blocks against JasperGold (plan task 4.4).
# Each block's UVM runs must exist (make uvm_b). Fails if a waived item is reachable.
.PHONY: unr_waivers
unr_waivers:
	@rc=0; for b in clic timers crg pwm gpio; do \
	   ./flow/formal/unr_block.sh $$b > $(SIM_DIR)/unr_$$b.out 2>&1 || rc=1; \
	   echo "$$b: $$(awk '/^(toggle|block|expression|assertion)/ {t+=$$2; c+=$$3; r+=$$4} END {printf "%d waivers, %d confirmed, %d reachable", t, c, r}' $(SIM_DIR)/unr_$$b.out)"; \
	 done; exit $$rc

# The timing constraints load in Genus and clock every flop, in each of the four
# clock ratios (plan task 3.2). flow/constraints/exceptions.md has every exception.
.PHONY: sdc_check
sdc_check:
	@rc=0; for d in 2 4 8 16; do ./scripts/run_sdc_check.sh $$d > sim/sdc_check_$$d.out 2>&1 || rc=1; tail -1 sim/sdc_check_$$d.out; done; exit $$rc

