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
        test_core sw isa_tests test_boot test_c regress regress_wait test_flag2 \
        test_sanity regress_rand coverage test_dsu test_units test_decode_control \
        test_imm_gen test_reg_file test_branch_predict test_hazard_forward_unit \
        test_id_stage test_elements test_alu test_mul32 test_branch_unit \
        test_csr_rw test_clic_ctrl test_lsu test_load_fmt test_memwb \
        test_pc_gen test_prefetch test_iport test_dport test_mem_stage test_if_stage \
        test_crg test_ahb_ic test_bridge test_mem test_dma test_clic test_timers \
        test_apb_shim test_spim test_uart test_i2c test_gpio test_pwm test_spis \
        test_debug test_blocks test_chip test_chip_basic test_chip_irq test_chip_wdt test_chip_flash test_chip_uart test_chip_periph \
        test_chip_jtag elab_chip regress_all synth

help:
	@echo "GARUDA SoC build targets:"
	@echo "  make check_tools     -- verify the selected simulator is on PATH"
	@echo "  make elab_core       -- elaborate core standalone (inert DSU stub)"
	@echo "  make elab_core_dsu   -- elaborate core + REAL DSU (integration)"
	@echo "  make test_core       -- every core unit smoke + the six unit TBs"
	@echo "  make test_units      -- the six constrained-random unit TBs only"
	@echo "  make test_elements   -- the 14 per-element SV core TBs (ALU, MUL,"
	@echo "                          branch, CSR_RW, LSU, load-fmt, D-port, MEM, MEM/WB,"
	@echo "                          PC-gen, prefetch, I-port, IF top, CLIC)"
	@echo "  make test_ex_dsu     -- EX smoke against the real DSU"
	@echo "  make sw              -- build bare-metal tests (boot6, ctest1, dsu_flag2)"
	@echo "  make isa_tests       -- build riscv-tests rv32ui + rv32um"
	@echo "  make test_boot       -- 6-instruction boot smoke through tb_boot"
	@echo "  make test_c          -- first C test (crt0 + stack + .bss + M-ext)"
	@echo "  make test_flag2      -- DSU FLAG-2 compute->read ordering probe"
	@echo "  make test_dsu        -- DSU unit TB vs DSUModel (regenerates vectors)"
	@echo "  make test_sanity     -- Core Sanity TB: IRQ, bus error, WFI, flush, DSU"
	@echo "  make regress         -- full ISA regression + Spike lockstep"
	@echo "  make regress_wait    -- same, with AHB wait states injected"
	@echo "  make regress_rand    -- same, randomised waits 0..8 (SEED=n)"
	@echo "  make coverage        -- functional coverage sweep (code cov: see script)"
	@echo "  ---- Rev 4.0 SoC ----"
	@echo "  make test_blocks     -- every block TB: crg ahb_ic bridge mem dma clic timers debug apb_shim spim uart i2c gpio pwm spis"
	@echo "  make test_chip       -- whole chip from the pins: basic, irq, wdt, jtag"
	@echo "  make elab_chip       -- elaborate garuda_chip_top"
	@echo "  make regress_all     -- everything above plus core, sanity, DSU and ISA"
	@echo "  make synth           -- Genus structural synthesis check (latches, drivers)"
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

# ---- teammate unit TBs (constrained-random, top module is tb_top) ----
# -64bit is required: the SV randomization library is only present as 64-bit
# here, and the default 32-bit invocation dies with
#   *F,RNCNL: ... libz.so.1 ... not a valid ELFCLASS32 library
# These bind to the REAL rtl/core sources via GARUDA_REAL_RTL; the testbenches
# also carry an inlined DUT snapshot for standalone VCS builds.
define run_tb_top
	@mkdir -p $(SIM_DIR)/unit_$(1) && \
	  $(XRUN) -64bit -f tb/core/filelist_$(1).f -top tb_top \
	    -xmlibdirname $(SIM_DIR)/unit_$(1)/xcelium.d \
	    -l $(SIM_DIR)/unit_$(1)/run.log > /dev/null 2>&1; \
	  printf "%-22s PASS=%-5s FAIL=%s\n" "$(1)" \
	    "$$(grep -c '\[PASS\]' $(SIM_DIR)/unit_$(1)/run.log)" \
	    "$$(grep -c '\[FAIL\]' $(SIM_DIR)/unit_$(1)/run.log)"
endef

test_units: test_decode_control test_imm_gen test_reg_file test_branch_predict \
            test_hazard_forward_unit test_id_stage

test_decode_control:      ; $(call run_tb_top,decode_control)
test_imm_gen:             ; $(call run_tb_top,imm_gen)
test_reg_file:            ; $(call run_tb_top,reg_file)
test_branch_predict:      ; $(call run_tb_top,branch_predict)
test_hazard_forward_unit: ; $(call run_tb_top,hazard_forward_unit)
test_id_stage:            ; $(call run_tb_top,id_stage)

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

# ---- per-element SV unit TBs (Sec. 18.2 directed tests, block level) ----
# One core element from the block diagram per target, verified on its own
# against AERO-GARUDA-DS-001. These follow the same SystemVerilog convention
# as the six tb_top TBs above -- interface + bound SVA, rand/constraint
# stimulus, reference model, covergroup, [PASS]/[FAIL] scoreboard -- so they
# need -64bit for the randomisation library and their top module is tb_top.
#
# Unlike run_tb_top this keeps the log's RESULT and coverage lines, which is
# what actually tells you WHICH check failed rather than only how many did.
# See docs/CORE_ELEMENT_VERIFICATION.md for the element -> spec section ->
# C-test mapping.
define run_tb_elem
	@mkdir -p $(SIM_DIR)/elem_$(1) && \
	  $(XRUN) -64bit -f tb/core/filelist_$(1).f -top tb_top \
	    -xmlibdirname $(SIM_DIR)/elem_$(1)/xcelium.d \
	    -l $(SIM_DIR)/elem_$(1)/run.log > /dev/null 2>&1; \
	  printf "%-26s PASS=%-6s FAIL=%-4s %s\n" "$(1)" \
	    "$$(grep -c '\[PASS\]' $(SIM_DIR)/elem_$(1)/run.log)" \
	    "$$(grep -c '\[FAIL\]' $(SIM_DIR)/elem_$(1)/run.log)" \
	    "$$(grep -hE '^ RESULT:' $(SIM_DIR)/elem_$(1)/run.log | head -1)"; \
	  grep -hE '\[FAIL\]|\[SVA-FAIL\]|^\*E|^xmelab: \*E' $(SIM_DIR)/elem_$(1)/run.log | head -20
endef

test_alu:            ; $(call run_tb_elem,alu)
test_mul32:          ; $(call run_tb_elem,mul32)
test_branch_unit:    ; $(call run_tb_elem,branch_unit)
test_csr_rw:         ; $(call run_tb_elem,csr_rw)
test_clic_ctrl:      ; $(call run_tb_elem,clic_ctrl)
test_lsu:            ; $(call run_tb_elem,load_store_unit)
test_load_fmt:       ; $(call run_tb_elem,load_formatter)
test_memwb:          ; $(call run_tb_elem,mem_wb_reg)
test_pc_gen:         ; $(call run_tb_elem,garuda_pc_gen)
test_prefetch:       ; $(call run_tb_elem,garuda_prefetch_buffer)
test_iport:          ; $(call run_tb_elem,garuda_iport_ahb_master)
test_dport:          ; $(call run_tb_elem,d_port_ahb_master)
test_mem_stage:      ; $(call run_tb_elem,mem_stage)
test_if_stage:       ; $(call run_tb_elem,garuda_if_stage_top)

# Every core element with its own TB, in block-diagram order:
# IF -> EX -> MEM -> WB -> CONTROL.
test_elements: test_pc_gen test_prefetch test_iport test_if_stage \
               test_alu test_mul32 test_branch_unit test_csr_rw \
               test_lsu test_load_fmt test_dport test_mem_stage \
               test_memwb test_clic_ctrl

# test_elements is run separately (and by regress_all) - see the help text.
test_core: test_ex test_ex_dsu test_idex test_exmem test_pipe test_csr test_trap test_units

# =============================================================================
# Rev 4.0 block-level testbenches (GARUDA-SYS-001; Docs/DECISIONS.md D-4..D-20)
# Every one is self-checking, prints [PASS]/[FAIL] lines and "RESULT:".
# =============================================================================
define run_blk
	@mkdir -p $(SIM_DIR)/$(3) && \
	  $(XRUN) -64bit -f $(1) -top $(2) -xmlibdirname $(SIM_DIR)/$(3)/xcelium.d \
	    -l $(SIM_DIR)/$(3)/run.log $(4) > /dev/null 2>&1; \
	  printf "%-14s " "$(3)"; grep -hE "^RESULT:|checks=|TB: .* checks" $(SIM_DIR)/$(3)/run.log | tr '\n' ' '; echo; \
	  grep -hE "\[FAIL\]|^xmelab: \*E|^xmvlog: \*E" $(SIM_DIR)/$(3)/run.log | head -10
endef

test_crg:     ; $(call run_blk,tb/clk_div/filelist_crg.f,tb_crg,tb_crg)                 ## 21/22 clock + reset
test_ahb_ic:  ; $(call run_blk,tb/ahb/filelist_ahb_ic.f,tb_ahb_interconnect,tb_ahb_ic)  ## 6 interconnect (4 masters)
test_bridge:  ; $(call run_blk,tb/ahb2apb/filelist_ahb2apb.f,tb_ahb2apb,tb_bridge)      ## 7/8 AHB2APB + fabric
test_mem:     ; $(call run_blk,tb/mem/filelist_mem.f,tb_mem_subsystem,tb_mem)           ## 3/4/5 memories
test_dma:     ; $(call run_blk,tb/dma/filelist_dma_top.f,tb_dma_top,tb_dma)             ## 9 DMA
test_clic:    ; $(call run_blk,tb/clic/filelist_clic.f,tb_clic,tb_clic)                 ## 10 CLIC
test_timers:  ; $(call run_blk,tb/timers/filelist_timers.f,tb_timers,tb_timers)         ## 11 timers + WDT
test_debug:   ; $(call run_blk,tb/debug/filelist_debug.f,tb_debug,tb_debug)             ## 12 debug (JTAG/DM/SBA)
test_apb_shim:; $(call run_blk,tb/common/filelist_shim.f,tb_apb_shim,tb_apb_shim)     ## shared peripheral front end
test_spim:    ; $(call run_blk,tb/spi_master/filelist_spim.f,tb_spim,tb_spim)          ## 13 SPI master + flash
test_uart:    ; $(call run_blk,tb/uart/filelist_uart.f,tb_uart,tb_uart)              ## 16/17/18 UART x3
test_i2c:     ; $(call run_blk,tb/i2c/filelist_i2c.f,tb_i2c,tb_i2c)                 ## 15 I2C master
test_gpio:    ; $(call run_blk,tb/gpio/filelist_gpio.f,tb_gpio,tb_gpio)              ## 19 GPIO
test_pwm:     ; $(call run_blk,tb/pwm/filelist_pwm.f,tb_pwm,tb_pwm)                 ## 20 PWM (in-house)
test_spis:    ; $(call run_blk,tb/spi_slave/filelist_spis.f,tb_spis,tb_spis)        ## 14 SPI slave (in-house)

# Every block, clocks and reset first because everything else assumes them.
test_blocks: test_crg test_ahb_ic test_bridge test_mem test_dma test_clic test_timers test_debug \
             test_apb_shim test_spim test_uart test_i2c test_gpio test_pwm test_spis

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
test_chip: sw test_chip_basic test_chip_irq test_chip_wdt test_chip_flash test_chip_uart test_chip_periph test_chip_jtag

# =============================================================================
# Design documents. The .md is normative; the .docx is an export (see
# Design_Docs/README.md). check_docs fails if an export has fallen behind.
# =============================================================================
.PHONY: docs check_docs pipe_matrix
pipe_matrix:                                  ## which CORE [N-11.2] matrix cells any test reaches
	@./scripts/run_pipe_matrix.sh

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

elab_chip:                                       ## whole-chip elaboration
	$(call run_blk,rtl/soc/filelist_chip.f,garuda_chip_top,elab_chip,-elaborate)

# Everything that is expected to be green, in one command.
regress_all: test_core test_elements test_blocks test_sanity test_dsu regress test_chip

# =============================================================================
# Synthesis check with Cadence Genus (generic mapping, no library): unresolved
# modules, multiple drivers, latches. Structural only - not timing signoff.
# =============================================================================
GENUS ?= /home/install/GENUS211/tools/bin/genus
synth:                                           ## whole chip
	@./scripts/run_genus.sh garuda_chip_top rtl/soc/filelist_chip.f

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

test_sanity: sw
	@./scripts/run_sanity.sh

# DSU unit TB. Vectors are REGENERATED every run: the expected values come from
# DSUModel, so stale vectors would silently test the previous RTL.
DSU_TESTS ?= 400
DSU_SEED  ?= 1
test_dsu:
	@mkdir -p $(SIM_DIR)/dsu
	@python3 tools/gen/DSU_gen.py --count $(DSU_TESTS) --seed $(DSU_SEED) \
	   --outdir $(SIM_DIR)/dsu | tail -1
	@$(XRUN) -64bit -f tb/dsu/filelist_dsu_top.f -top tb_dsu_top \
	   -xmlibdirname $(SIM_DIR)/dsu/xcelium.d -l $(SIM_DIR)/dsu/run.log \
	   +STIM=$(SIM_DIR)/dsu/dsu_stim.mem +EXP=$(SIM_DIR)/dsu/dsu_expected.mem \
	   > /dev/null 2>&1; \
	 grep -E "tests compared|mismatches|RESULT" $(SIM_DIR)/dsu/run.log

coverage: sw isa_tests
	@./scripts/run_coverage.sh

regress: isa_tests
	@./scripts/run_regression.sh

# Core Sanity row 21: randomise I and D wait states per access, 0..8. A fixed
# wait count exercises exactly one timing; randomised counts are what actually
# open and close the stall windows. SEED= replays a failing run exactly.
regress_rand: isa_tests
	@RUNDIR=$(SIM_DIR)/regress_rand MAXCYC=600000 \
	   EXTRA_ARGS="+IWAIT=8 +DWAIT=8 +IRAND=1 +DRAND=1 +SEED=$${SEED:-1}" \
	   ./scripts/run_regression.sh

regress_wait: isa_tests
	@RUNDIR=$(SIM_DIR)/regress_wait EXTRA_ARGS="+IWAIT=2 +DWAIT=3" MAXCYC=400000 \
	   ./scripts/run_regression.sh
