# =============================================================
# GARUDA SoC -- make targets of track A
# flow/mk/track_a.mk, included by the top-level Makefile.
#
# Core, DSU, AHB interconnect, AHB2APB bridge, DMA, debug, memories.
# Edited by the owner of track A only. Macros and tool paths are in
# flow/mk/common.mk; track B's targets are in flow/mk/track_b.mk.
# =============================================================

.PHONY: help_a elab_core elab_core_dsu \
        test_ex test_ex_dsu test_idex test_exmem test_pipe test_csr test_trap \
        test_core isa_tests test_boot test_c regress regress_wait test_flag2 \
        test_sanity regress_rand coverage test_dsu test_units test_decode_control \
        test_imm_gen test_reg_file test_branch_predict test_hazard_forward_unit \
        test_id_stage test_elements test_alu test_mul32 test_branch_unit \
        test_csr_rw test_clic_ctrl test_lsu test_load_fmt test_memwb \
        test_pc_gen test_prefetch test_iport test_dport test_mem_stage test_if_stage \
        test_ahb_ic test_bridge test_mem test_dma test_debug test_blocks_a \
        pipe_matrix riscv_dv csr_map gate_a

help_a:
	@echo "  ---- track A: core, DSU, bus, DMA, debug, memories ----"
	@echo "  make elab_core       -- elaborate core standalone (inert DSU stub)"
	@echo "  make elab_core_dsu   -- elaborate core + REAL DSU (integration)"
	@echo "  make test_core       -- every core unit smoke + the six unit TBs"
	@echo "  make test_units      -- the six constrained-random unit TBs only"
	@echo "  make test_elements   -- the 14 per-element SV core TBs (ALU, MUL,"
	@echo "                          branch, CSR_RW, LSU, load-fmt, D-port, MEM, MEM/WB,"
	@echo "                          PC-gen, prefetch, I-port, IF top, CLIC)"
	@echo "  make test_ex_dsu     -- EX smoke against the real DSU"
	@echo "  make isa_tests       -- build riscv-tests rv32ui + rv32um"
	@echo "  make test_boot       -- 6-instruction boot smoke through tb_boot"
	@echo "  make test_c          -- first C test (crt0 + stack + .bss + M-ext)"
	@echo "  make test_flag2      -- DSU FLAG-2 compute->read ordering probe (closed: DSU-3/DSU-4)"
	@echo "  make test_dsu        -- DSU unit TB vs DSUModel (regenerates vectors)"
	@echo "  make test_sanity     -- Core Sanity TB: IRQ, bus error, WFI, flush, DSU"
	@echo "  make regress         -- full ISA regression + Spike lockstep"
	@echo "  make regress_wait    -- same, with AHB wait states injected"
	@echo "  make regress_rand    -- same, randomised waits 0..8 (SEED=n)"
	@echo "  make coverage        -- functional coverage sweep (code cov: see script)"
	@echo "  make test_blocks_a   -- block TBs: ahb_ic bridge mem dma debug"
	@echo "  make riscv_dv        -- random programs in lockstep with Spike (DV_SEEDS=n)"
	@echo "  make csr_map         -- CSR existence, RTL against Spike"
	@echo "  make gate_a          -- the subset to pass before a push of track A"

# ---- elaboration ----
elab_core:
	$(call run_test,rtl/core/filelist_core.f,garuda_core_top,elab_core,-)

elab_core_dsu:
	$(call run_test,rtl/core/filelist_core_dsu.f,garuda_core_top,elab_core_dsu,-)

# ---- the six constrained-random unit TBs (top module is tb_top) ----
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

# ---- per-element SV unit TBs ----
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

# ---- block-level testbenches of track A ----
test_ahb_ic:  ; $(call run_blk,tb/ahb/filelist_ahb_ic.f,tb_ahb_interconnect,tb_ahb_ic)  ## 6 interconnect (4 masters)
test_bridge:  ; $(call run_blk,tb/ahb2apb/filelist_ahb2apb.f,tb_ahb2apb,tb_bridge)      ## 7/8 AHB2APB + fabric
test_mem:     ; $(call run_blk,tb/mem/filelist_mem.f,tb_mem_subsystem,tb_mem)           ## 3/4/5 memories
test_dma:     ; $(call run_blk,tb/dma/filelist_dma_top.f,tb_dma_top,tb_dma)             ## 9 DMA
test_debug:   ; $(call run_blk,tb/debug/filelist_debug.f,tb_debug,tb_debug)             ## 12 debug (JTAG/DM/SBA)

BLOCKS_A = test_ahb_ic test_bridge test_mem test_dma test_debug
test_blocks_a: $(BLOCKS_A)

pipe_matrix:                                  ## which CORE [N-11.2] matrix cells any test reaches
	@./scripts/run_pipe_matrix.sh

# =============================================================================
# riscv-dv: random instruction programs on the core, each compared with Spike
# (stage 3). The generator is at ~/external/riscv-dv; the GARUDA target and the
# list of tests are in tb/core/riscv_dv/. By hand: flow/COMMANDS.md.
#   make riscv_dv                    every test in the list x DV_SEEDS seeds
#   make riscv_dv DV_SEEDS=20
#   make riscv_dv DV_TESTS="illegal ebreak" DV_SEEDS=3
# =============================================================================
DV_SEEDS ?= 5
DV_TESTS ?=
DV_MAXCYC ?= 600000
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

# =============================================================================
# Software + full-pipeline flows on the core
# =============================================================================
isa_tests:
	$(MAKE) -C sw/riscv-tests all

BOOT_ARGS = -f tb/soc/filelist_boot.f -top tb_boot

# boot_run <log name> <hex> <commit log name> <plusargs> <lines to show>
# One program on tb_boot. Passes only on the bench's own "TOHOST=1 -> PASSED"
# with a clean exit and no error line (Docs/BUGS.md TOOL-13): the grep that shows
# the result used to be the recipe's exit status, and it matches FAILED as well.
define boot_run
	@mkdir -p $(SIM_DIR)/tb_boot && rm -f $(SIM_DIR)/tb_boot/$(1).log; \
	 $(XRUN) $(BOOT_ARGS) -xmlibdirname $(SIM_DIR)/tb_boot/xcelium.d \
	   -l $(SIM_DIR)/tb_boot/$(1).log \
	   +HEX=$(2) +COMMIT=$(SIM_DIR)/tb_boot/$(3) $(4) > /dev/null 2>&1; rc=$$?; \
	 grep -E "$(5)" $(SIM_DIR)/tb_boot/$(1).log 2> /dev/null | head -40; \
	 $(call judge,$(SIM_DIR)/tb_boot/$(1).log,TOHOST=1 -> PASSED)
endef

test_boot: sw
	$(call boot_run,run,sw/build/boot6.hex,commit.log,+MAXCYC=2000,TOHOST|PASSED|FAILED|TIMEOUT)

test_c: sw
	$(call boot_run,ctest1,sw/build/ctest1.hex,ctest1.commit.log,+MAXCYC=20000 +QUIET,TOHOST|PASSED|FAILED|TIMEOUT)

test_flag2: sw
	$(call boot_run,flag2,sw/build/dsu_flag2.hex,flag2.commit.log,+MAXCYC=2000 +DBGACC,ACC:|TOHOST|PASSED|FAILED|TIMEOUT)

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
	@rm -f $(SIM_DIR)/dsu/run.log; \
	 $(XRUN) -64bit -f tb/dsu/filelist_dsu_top.f -top tb_dsu_top \
	   -xmlibdirname $(SIM_DIR)/dsu/xcelium.d -l $(SIM_DIR)/dsu/run.log \
	   +STIM=$(SIM_DIR)/dsu/dsu_stim.mem +EXP=$(SIM_DIR)/dsu/dsu_expected.mem \
	   > /dev/null 2>&1; rc=$$?; \
	 grep -E "tests compared|mismatches|RESULT" $(SIM_DIR)/dsu/run.log 2> /dev/null; \
	 $(call judge,$(SIM_DIR)/dsu/run.log,RESULT +: PASSED)

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

# Everything of track A that regress_all runs, in the order it has always run.
REGRESS_A = test_core test_elements test_blocks_a test_sanity test_dsu regress

# =============================================================================
# The gate of track A: pass it before every push. A subset that runs in a few
# minutes; the nightly runs everything. -k: every part runs, so one failure
# does not hide another.
# =============================================================================
GATE_A = check_tree test_core test_elements test_blocks_a test_sanity test_dsu regress csr_map
gate_a:
	@if $(MAKE) --no-print-directory -k $(GATE_A); \
	 then echo "gate_a: PASS"; else echo "gate_a: FAIL"; exit 1; fi
