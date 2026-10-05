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
        test_debug test_blocks test_chip test_chip_basic test_chip_irq test_chip_wdt test_chip_flash test_chip_uart test_chip_periph test_chip_integ \
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
	  printf "%-22s PASS=%-5s FAIL=%-4s SVA_FAIL=%s\n" "$(1)" \
	    "$$(grep -c '\[PASS\]' $(SIM_DIR)/unit_$(1)/run.log)" \
	    "$$(grep -c '\[FAIL\]' $(SIM_DIR)/unit_$(1)/run.log)" \
	    "$$(grep -c '\*E,ASRTST' $(SIM_DIR)/unit_$(1)/run.log)"
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
	  printf "%-26s PASS=%-6s FAIL=%-4s SVA_FAIL=%-4s %s\n" "$(1)" \
	    "$$(grep -c '\[PASS\]' $(SIM_DIR)/elem_$(1)/run.log)" \
	    "$$(grep -c '\[FAIL\]' $(SIM_DIR)/elem_$(1)/run.log)" \
	    "$$(grep -c '\*E,ASRTST' $(SIM_DIR)/elem_$(1)/run.log)" \
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
	  printf "%-14s " "$(3)"; grep -hE "^RESULT:|checks=|TB: .* checks" $(SIM_DIR)/$(3)/run.log | tr '\n' ' '; \
	  n=$$(grep -c '\*E,ASRTST' $(SIM_DIR)/$(3)/run.log); \
	  [ "$$n" = 0 ] && echo || echo " ** $$n ASSERTION FAILURE(S), not counted in RESULT"; \
	  grep -hE "\[FAIL\]|^xmelab: \*E|^xmvlog: \*E|\*E,ASRTST" $(SIM_DIR)/$(3)/run.log | head -10
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
test_chip_integ: ; $(call run_blk,$(CHIP_FL),tb_chip,chip_integ,+MODE=basic +TEST=sw/build/t_chip_integ.hex +MAXUS=4000)
test_chip: sw test_chip_basic test_chip_irq test_chip_wdt test_chip_flash test_chip_uart test_chip_periph test_chip_integ test_chip_jtag

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

# =============================================================================
# Static checks (stage 1): rerun on every change to rtl/.
#   static_lint   HAL lint on the whole chip; fails on any error that is not in
#                 flow/2_static/hal_waivers.txt (matched by rule and file:line)
#   static_cdc    HAL clock-domain check on debug_top, the one async boundary
#   static_xprop  all eight chip programs with X-propagation (xrun -xprop F)
# HAL is the Incisive 15.2 one: the Xcelium 22.09 HAL does not run here.
# =============================================================================
IRUN152 ?= /home/install/INCISIVE152/tools/bin/irun
.PHONY: static static_lint static_cdc static_xprop
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
	 [ $$new -eq 0 ] && grep -q 'Analysis complete' $(SIM_DIR)/static/hal.log

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
# UVM block environments (stage 2). Run under irun 15.2 so the coverage opens in
# IMC. irun prints one tool error on every UVM run, "ncsim: *E,IMPDLL" (it cannot
# build its own DPI export stub on this machine); the simulation is unaffected
# and that one line is ignored here. Any other error fails the run.
# The Incisive tools must be first on PATH for these runs: with Xcelium first,
# irun 15.2 writes a coverage model that IMC 15.2 cannot load.
#   make uvm_clic            register test, directed test, random test x SEEDS
#   make uvm_clic SEEDS=50
#   make uvm_timers          the same for the timers and the watchdog
#   make uvm_pwm             the same for the PWM
#   make uvm_gpio            the same for the GPIO
#   make uvm_crg             the same for the clock divider and the reset controller
# =============================================================================
SEEDS ?= 20
UVM_IRUN = $(IRUN152) -64bit -uvm -uvmhome CDNS-1.2 -coverage all -covoverwrite
.PHONY: uvm_clic
uvm_clic:                                        ## CLIC UVM environment, with coverage
	@export PATH=$(dir $(IRUN152)):$$PATH; \
	 D=$(SIM_DIR)/uvm_clic; mkdir -p $$D; rm -rf $$D/cov_work $$D/INCA_libs; fail=0; \
	 C="$(UVM_IRUN) -covworkdir $$D/cov_work -covdut clic_top -nclibdirname $$D/INCA_libs"; \
	 run() { $$C $$1 +UVM_TESTNAME=$$2 -svseed $$3 -covtest $$4 -l $$D/$$4.log > /dev/null 2>&1; \
	   if grep -q 'RESULT: PASSED' $$D/$$4.log && [ "$$(grep -E '\*[EF],' $$D/$$4.log | grep -vc IMPDLL)" = 0 ] && ! grep -q 'SVA-FAIL' $$D/$$4.log; \
	   then echo "uvm_clic  $$4 PASS"; else echo "uvm_clic  $$4 FAIL"; fail=1; fi; }; \
	 run "-f tb/clic/uvm/filelist_clic_uvm.f -top tb_clic_uvm" clic_reg_test 1 reg_s1; \
	 run -R clic_directed_test 1 directed_s1; \
	 s=1; while [ $$s -le $(SEEDS) ]; do run -R clic_random_test $$s random_s$$s; s=$$((s+1)); done; \
	 [ $$fail -eq 0 ]

.PHONY: uvm_timers
uvm_timers:                                      ## timers and watchdog UVM environment, with coverage
	@export PATH=$(dir $(IRUN152)):$$PATH; \
	 D=$(SIM_DIR)/uvm_timers; mkdir -p $$D; rm -rf $$D/cov_work $$D/INCA_libs; fail=0; \
	 C="$(UVM_IRUN) -covworkdir $$D/cov_work -covdut timers_top -nclibdirname $$D/INCA_libs"; \
	 run() { $$C $$1 +UVM_TESTNAME=$$2 -svseed $$3 -covtest $$4 -l $$D/$$4.log > /dev/null 2>&1; \
	   if grep -q 'RESULT: PASSED' $$D/$$4.log && [ "$$(grep -E '\*[EF],' $$D/$$4.log | grep -vc IMPDLL)" = 0 ] && ! grep -q 'SVA-FAIL' $$D/$$4.log; \
	   then echo "uvm_timers  $$4 PASS"; else echo "uvm_timers  $$4 FAIL"; fail=1; fi; }; \
	 run "-f tb/timers/uvm/filelist_timers_uvm.f -top tb_timers_uvm" tmr_reg_test 1 reg_s1; \
	 run -R tmr_directed_test 1 directed_s1; \
	 s=1; while [ $$s -le $(SEEDS) ]; do run -R tmr_random_test $$s random_s$$s; s=$$((s+1)); done; \
	 [ $$fail -eq 0 ]

.PHONY: uvm_pwm
uvm_pwm:                                      ## PWM UVM environment, with coverage
	@export PATH=$(dir $(IRUN152)):$$PATH; \
	 D=$(SIM_DIR)/uvm_pwm; mkdir -p $$D; rm -rf $$D/cov_work $$D/INCA_libs; fail=0; \
	 C="$(UVM_IRUN) -covworkdir $$D/cov_work -covdut garuda_pwm_top -nclibdirname $$D/INCA_libs"; \
	 run() { $$C $$1 +UVM_TESTNAME=$$2 -svseed $$3 -covtest $$4 -l $$D/$$4.log > /dev/null 2>&1; \
	   if grep -q 'RESULT: PASSED' $$D/$$4.log && [ "$$(grep -E '\*[EF],' $$D/$$4.log | grep -vc IMPDLL)" = 0 ] && ! grep -q 'SVA-FAIL' $$D/$$4.log; \
	   then echo "uvm_pwm  $$4 PASS"; else echo "uvm_pwm  $$4 FAIL"; fail=1; fi; }; \
	 run "-f tb/pwm/uvm/filelist_pwm_uvm.f -top tb_pwm_uvm" pwm_reg_test 1 reg_s1; \
	 run -R pwm_directed_test 1 directed_s1; \
	 s=1; while [ $$s -le $(SEEDS) ]; do run -R pwm_random_test $$s random_s$$s; s=$$((s+1)); done; \
	 [ $$fail -eq 0 ]

.PHONY: uvm_gpio
uvm_gpio:                                      ## GPIO UVM environment, with coverage
	@export PATH=$(dir $(IRUN152)):$$PATH; \
	 D=$(SIM_DIR)/uvm_gpio; mkdir -p $$D; rm -rf $$D/cov_work $$D/INCA_libs; fail=0; \
	 C="$(UVM_IRUN) -covworkdir $$D/cov_work -covdut garuda_gpio_top -nclibdirname $$D/INCA_libs"; \
	 run() { $$C $$1 +UVM_TESTNAME=$$2 -svseed $$3 -covtest $$4 -l $$D/$$4.log > /dev/null 2>&1; \
	   if grep -q 'RESULT: PASSED' $$D/$$4.log && [ "$$(grep -E '\*[EF],' $$D/$$4.log | grep -vc IMPDLL)" = 0 ] && ! grep -q 'SVA-FAIL' $$D/$$4.log; \
	   then echo "uvm_gpio  $$4 PASS"; else echo "uvm_gpio  $$4 FAIL"; fail=1; fi; }; \
	 run "-f tb/gpio/uvm/filelist_gpio_uvm.f -top tb_gpio_uvm" gpio_reg_test 1 reg_s1; \
	 run -R gpio_directed_test 1 directed_s1; \
	 s=1; while [ $$s -le $(SEEDS) ]; do run -R gpio_random_test $$s random_s$$s; s=$$((s+1)); done; \
	 [ $$fail -eq 0 ]

.PHONY: uvm_crg
uvm_crg:                                      ## clock and reset UVM environment, with coverage
	@export PATH=$(dir $(IRUN152)):$$PATH; \
	 D=$(SIM_DIR)/uvm_crg; mkdir -p $$D; rm -rf $$D/cov_work $$D/INCA_libs; fail=0; \
	 C="$(UVM_IRUN) -covworkdir $$D/cov_work -covdut clk_div -covdut reset_ctrl -nclibdirname $$D/INCA_libs"; \
	 run() { $$C $$1 +UVM_TESTNAME=$$2 -svseed $$3 -covtest $$4 -l $$D/$$4.log > /dev/null 2>&1; \
	   if grep -q 'RESULT: PASSED' $$D/$$4.log && [ "$$(grep -E '\*[EF],' $$D/$$4.log | grep -vc IMPDLL)" = 0 ] && ! grep -q 'SVA-FAIL' $$D/$$4.log; \
	   then echo "uvm_crg  $$4 PASS"; else echo "uvm_crg  $$4 FAIL"; fail=1; fi; }; \
	 run "-f tb/clk_div/uvm/filelist_crg_uvm.f -top tb_crg_uvm" crg_reg_test 1 reg_s1; \
	 run -R crg_directed_test 1 directed_s1; \
	 s=1; while [ $$s -le $(SEEDS) ]; do run -R crg_random_test $$s random_s$$s; s=$$((s+1)); done; \
	 [ $$fail -eq 0 ]

# =============================================================================
# riscv-dv: random instruction programs on the core, each compared with Spike
# (stage 3). The generator is at ~/external/riscv-dv; the GARUDA target and the
# list of tests are in tb/core/riscv_dv/. By hand: flow/COMMANDS.md.
#   make riscv_dv                    every test in the list x DV_SEEDS seeds
#   make riscv_dv DV_SEEDS=20
#   make riscv_dv DV_TESTS="illegal ebreak" DV_SEEDS=3
# =============================================================================
RISCV_DV_ROOT ?= $(HOME)/external/riscv-dv
RISCV_GNU     ?= /home/vivado/2025.2/Vitis/gnu/riscv/linux_toolchain/lin64/bin/riscv64-amd-linux-gnu
SPIKE         ?= $(HOME)/external/spike-inst/bin/spike
DV_SEEDS ?= 5
DV_TESTS ?=
DV_MAXCYC ?= 600000
.PHONY: riscv_dv
riscv_dv:                                        ## random programs in lockstep with Spike
	@export RISCV_DV_ROOT=$(RISCV_DV_ROOT); D=$(SIM_DIR)/riscv_dv; mkdir -p $$D/asm; rm -f $$D/.fail; \
	 $(XRUN) -64bit -access +rwc -f $(RISCV_DV_ROOT)/files.f +incdir+tb/core/riscv_dv/target +incdir+$(RISCV_DV_ROOT)/user_extension \
	    -q -sv -uvm -uvmhome CDNS-1.2 -vlog_ext +.vh -elaborate -xmlibdirpath $$D -l $$D/compile.log > /dev/null 2>&1; \
	 if grep -qE '\*[EF],' $$D/compile.log; then echo "riscv_dv: generator did not compile, see $$D/compile.log"; exit 1; fi; \
	 $(XRUN) -f tb/soc/filelist_boot.f -top tb_boot -xmlibdirname $$D/rtl.d -snapshot garuda_boot -elaborate -l $$D/elab.log > /dev/null 2>&1; \
	 if grep -qE '^(xrun|xmelab|xmvlog): \*[EF]' $$D/elab.log; then echo "riscv_dv: RTL did not elaborate, see $$D/elab.log"; exit 1; fi; \
	 printf "%-22s %-9s %-9s %s\n" PROGRAM RTL LOCKSTEP NOTE; \
	 grep -vE '^ *(#|$$)' tb/core/riscv_dv/testlist | while read name gen opts; do \
	   if [ -n "$(DV_TESTS)" ] && ! echo " $(DV_TESTS) " | grep -q " $$name "; then continue; fi; \
	   s=1; while [ $$s -le $(DV_SEEDS) ]; do t=$${name}_s$$s; s=$$((s+1)); \
	     rm -f $$D/asm/$${t}_0.S $$D/asm/$$t.elf $$D/$$t.commit.log $$D/$$t.lockstep.txt; \
	     $(XRUN) -64bit -R -xmlibdirpath $$D +UVM_TESTNAME=$$gen +num_of_tests=1 +start_idx=0 +asm_file_name=$$D/asm/$$t $$opts \
	        -svseed $$((s-1)) -l $$D/$$t.gen.log > /dev/null 2>&1; \
	     if [ ! -s $$D/asm/$${t}_0.S ]; then printf "%-22s %-9s %-9s %s\n" $$t - - "no program generated, see $$D/$$t.gen.log"; echo F >> $$D/.fail; continue; fi; \
	     $(RISCV_GNU)-gcc -march=rv32im_zicsr_zifencei -mabi=ilp32 -mno-relax -fno-pic -static -nostdlib -nostartfiles -Wa,--no-warn \
	        -I$(RISCV_DV_ROOT)/user_extension -T tb/core/riscv_dv/link.ld -no-pie -Wl,--no-warn-rwx-segments -Wl,--build-id=none \
	        $$D/asm/$${t}_0.S -o $$D/asm/$$t.elf > $$D/$$t.build.log 2>&1; \
	     if [ ! -s $$D/asm/$$t.elf ]; then printf "%-22s %-9s %-9s %s\n" $$t - - "did not link, see $$D/$$t.build.log"; echo F >> $$D/.fail; continue; fi; \
	     $(RISCV_GNU)-objcopy -O binary $$D/asm/$$t.elf $$D/asm/$$t.bin; python3 tools/elf2hex.py $$D/asm/$$t.bin $$D/asm/$$t.hex > /dev/null; \
	     th=$$($(RISCV_GNU)-nm $$D/asm/$$t.elf | awk '$$3=="tohost"{print $$1}'); \
	     $(XRUN) -R -xmlibdirname $$D/rtl.d -snapshot garuda_boot -l $$D/$$t.run.log +HEX=$$D/asm/$$t.hex +COMMIT=$$D/$$t.commit.log \
	        +TOHOST=$$th +MAXCYC=$(DV_MAXCYC) +QUIET > /dev/null 2>&1; \
	     if grep -q 'TOHOST=1 -> PASSED' $$D/$$t.run.log && grep -q 'AHB-PROTOCOL: iport=0 dport=0' $$D/$$t.run.log; then r=PASS; else r=FAIL; fi; \
	     ls=$$(python3 tools/lockstep.py --rtl $$D/$$t.commit.log --elf $$D/asm/$$t.elf --spike-log $$D/$$t.spike.log --spike $(SPIKE) --tohost $$th --max 3 2>&1); \
	     rm -f $$D/$$t.spike.log; \
	     if echo "$$ls" | grep -q '^MATCH'; then l=MATCH; note=$$(echo "$$ls" | grep '^MATCH' | sed 's/^MATCH: //'); \
	     else l=DIVERGE; echo "$$ls" > $$D/$$t.lockstep.txt; note="see $$D/$$t.lockstep.txt"; fi; \
	     printf "%-22s %-9s %-9s %s\n" $$t $$r $$l "$$note"; \
	     if [ $$r != PASS ] || [ $$l != MATCH ]; then echo F >> $$D/.fail; fi; \
	   done; done; \
	 if [ -s $$D/.fail ]; then n=$$(wc -l < $$D/.fail); rm -f $$D/.fail; echo "riscv_dv: $$n program(s) FAILED"; exit 1; else echo "riscv_dv: all programs PASSED and MATCH Spike"; fi

# Which CSR addresses exist on the core and which on Spike: all 4096 read on both.
.PHONY: csr_map
csr_map:                                         ## CSR existence, RTL against Spike
	@D=$(SIM_DIR)/csr_map; mkdir -p $$D; python3 tools/csr_map.py gen $$D/csr_sweep.S; \
	 $(RISCV_GNU)-gcc -march=rv32im_zicsr -mabi=ilp32 -mno-relax -fno-pic -static -nostdlib -nostartfiles -Wa,--no-warn \
	    -T sw/common/link.ld -no-pie -Wl,--no-warn-rwx-segments $$D/csr_sweep.S -o $$D/csr_sweep.elf 2> $$D/build.log; \
	 $(RISCV_GNU)-objcopy -O binary $$D/csr_sweep.elf $$D/csr_sweep.bin; python3 tools/elf2hex.py $$D/csr_sweep.bin $$D/csr_sweep.hex > /dev/null; \
	 $(XRUN) -f tb/soc/filelist_boot.f -top tb_boot -xmlibdirname $$D/rtl.d -snapshot garuda_boot -l $$D/run.log \
	    +HEX=$$D/csr_sweep.hex +COMMIT=$$D/commit.log +MAXCYC=400000 +QUIET > /dev/null 2>&1; \
	 grep -q 'TOHOST=1 -> PASSED' $$D/run.log || { echo "csr_map: the sweep did not finish on the RTL, see $$D/run.log"; exit 1; }; \
	 $(SPIKE) --isa=rv32im_zicsr_zifencei_zicntr --pmpregions=0 --triggers=0 -m0x10000000:0x40000 --disable-dtb --priv=m \
	    --pc=0x10000000 --log-commits -l $$D/csr_sweep.elf > /dev/null 2> $$D/spike.log; \
	 python3 tools/csr_map.py diff $$D/csr_sweep.elf $$D/commit.log $$D/spike.log $(RISCV_GNU)-nm

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
# lib FIRST, and export VERILATOR_ROOT (Docs/BUGS.md TOOL-2, TOOL-3).
.PHONY: local local_sim local_lint local_synth

local_sim:                                       ## all block TBs under Icarus
	@./scripts/run_sim.sh all

local_synth:                                     ## Yosys + latch gate
	@./scripts/run_synth.sh garuda_chip_top

# Verilator needs +incdir+, NOT -I with a space: given "-I path" it parses the
# sources that follow as top-module names (Docs/BUGS.md TOOL-2).
local_lint:                                      ## whole-chip Verilator lint
	@set -e; \
	 inc=$$(python3 scripts/expand_filelist.py rtl/soc/filelist_chip.f --incdirs \
	        | sed 's/-I/+incdir+/g'); \
	 src=$$(python3 scripts/expand_filelist.py rtl/soc/filelist_chip.f | tr '\n' ' '); \
	 echo "=== Verilator lint: garuda_chip_top ($$(echo $$src | wc -w) sources) ==="; \
	 verilator --lint-only -sv --timing --top-module garuda_chip_top $$inc $$src

local: local_sim local_lint local_synth
