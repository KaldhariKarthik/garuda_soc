# GARUDA verification flow: the commands, stage by stage

Every shell starts with:

```bash
cd ~/garuda_soc
source scripts/setup_env.sh
export GARUDA_ROOT=$PWD
export PATH=/home/install/INCISIVE152/tools/bin:$PATH     # irun, hal, imc 15.2
```

Coverage is collected with **irun 15.2** because IMC and vManager on this machine
are 15.2 and cannot read an Xcelium 22.09 database. Xcelium (`xrun`, the `make`
targets) is the fast day-to-day simulator; both read the same filelists.

---

## Stage 1: vPlan (vPlanner)

One plan per block, next to its bench, and one top-level plan:

```bash
vplanner -standalone &        # File > Open, pick a plan, then File > Save As <same name>.vplanx
```

| Plan | File |
|---|---|
| Top level, the six stages | `flow/1_vplan/garuda_soc.csv` |
| A block | `tb/<block>/GARUDA_<BLOCK>_vplan.csv`, e.g. `tb/pwm/GARUDA_PWM_vplan.csv`, `tb/uart/GARUDA_UART_vplan.csv`, `tb/core/GARUDA_CORE_vplan.csv` |

Each block plan is that block's specification, sections 2 (requirements), 10
(assertions) and 11 (verification plan), in vPlanner form: every requirement, the
tests planned for it, where each test lives in the bench and its result, the
assertions, the merged coverage per module, and a last section with what the
2026-10-04 flow run added. A planned test with no check in the bench is marked
`NOT IMPLEMENTED`.

A note-by-note traceability list (every `[N-x.y]` in every spec against the check
that cites it) is in `flow/1_vplan/traceability/spec_notes.csv`:

```bash
python3 tools/gen/gen_vplan_csv.py --unchecked | less
```

## Stage 2: Static (HAL lint, HAL clock-domain checks, NCBrowse)

```bash
# lint, whole chip
irun -hal -64bit -f rtl/soc/filelist_chip.f -top garuda_chip_top -define SYNTHESIS \
     -nclibdirname sim/static/INCA_libs -l sim/static/hal.log -f flow/2_static/hal.f

# browse the messages
ncbrowse -64bit -cdslib sim/static/INCA_libs/irun.lnx8664.15.20.nc/cds.lib \
         -hdlvar sim/static/INCA_libs/irun.lnx8664.15.20.nc/hdl.var \
         -sortby severity -sortby category -sortby tag sim/static/hal.log &

# clock-domain crossings: the debug block, where tck and hclk are both ports
irun -hal -64bit -f rtl/third_party/timescale.f rtl/debug/jtag_tap.v rtl/debug/dtm.v \
     rtl/debug/dmi_cdc.v rtl/debug/sba_master.v rtl/debug/debug_module.v rtl/debug/debug_top.v \
     -incdir rtl/include -top debug_top -define SYNTHESIS \
     -nclibdirname sim/static_cdc_debug/INCA_libs -l sim/static_cdc_debug/hal_cdc.log \
     -halargs "-check CLOCKDOMAIN"
grep -E 'CLKDMN|INSYNC' sim/static_cdc_debug/hal_cdc.log
```

- Rules switched off and why: `flow/2_static/hal.f`.
- What is left and why it is accepted: `flow/2_static/hal_waivers.txt`.
- Formal (IFV) is set up in `flow/2_static/fv_pipe_ctrl/` but there is no
  `Incisive_Formal_Verifier` licence on the server, so it does not run.

## One block by hand: plan, lint, simulate, coverage

The same four commands for any block; only the names in the table change.
Shown for the SPI master.

```bash
mkdir -p sim/manual

# 1 plan
vplanner -standalone &        # File > Open > tb/spi_master/GARUDA_SPIM_vplan.csv

# 2 lint the block
irun -hal -64bit -f rtl/third_party/timescale.f -f rtl/spi_master/filelist.f \
     -top garuda_spim_top -define SYNTHESIS -f flow/2_static/hal.f \
     -nclibdirname sim/manual/INCA_hal_spim -l sim/manual/hal_spim.log
grep -E 'hal[a-z]*: \*E,' sim/manual/hal_spim.log        # the errors; compare with hal_waivers.txt

# 3 simulate with coverage
irun -64bit -f tb/spi_master/filelist_spim.f -top tb_spim \
     -coverage all -covoverwrite -covworkdir sim/manual/cov_work -covtest spim \
     -nclibdirname sim/manual/INCA_spim -l sim/manual/spim.log
grep -E 'PASS|FAIL|RESULT' sim/manual/spim.log | tail -5

# 4 coverage
imc -load sim/manual/cov_work/scope/spim &                # GUI
imc -load sim/manual/cov_work/scope/spim -execcmd \
    "report -summary -inst tb_spim.dut... -metrics block:expression:toggle:fsm -out sim/manual/spim_cov.txt"
```

| Block | Lint: filelist, `-top` | Simulate: filelist, `-top` | `-covtest` |
|---|---|---|---|
| Clock divider | `rtl/clk_div/filelist.f`, `clk_div` | `tb/clk_div/filelist_crg.f`, `tb_crg` | `crg` |
| Reset controller | `rtl/reset_ctrl/filelist.f`, `reset_ctrl` | same bench | `crg` |
| Memories | `rtl/mem/filelist.f`, `-top isram_top -top dsram_top -top bootrom_top` | `tb/mem/filelist_mem.f`, `tb_mem_subsystem` | `mem` |
| DMA | `rtl/dma/filelist.f`, `dma_top` | `tb/dma/filelist_dma_top.f`, `tb_dma_top` | `dma` |
| CLIC | `rtl/clic/filelist.f`, `clic_top` | `tb/clic/filelist_clic.f`, `tb_clic` | `clic` |
| Timers, watchdog | `rtl/timers/filelist.f`, `timers_top` | `tb/timers/filelist_timers.f`, `tb_timers` | `timers` |
| Debug | `rtl/debug/filelist.f`, `debug_top` | `tb/debug/filelist_debug.f`, `tb_debug` | `debug` |
| SPI master | `rtl/spi_master/filelist.f`, `garuda_spim_top` | `tb/spi_master/filelist_spim.f`, `tb_spim` | `spim` |
| SPI slave | `rtl/spi_slave/filelist.f`, `garuda_spis_top` | `tb/spi_slave/filelist_spis.f`, `tb_spis` | `spis` |
| I2C | `rtl/i2c/filelist.f`, `garuda_i2c_top` | `tb/i2c/filelist_i2c.f`, `tb_i2c` | `i2c` |
| UART | `rtl/uart/filelist.f`, `garuda_uart_top` | `tb/uart/filelist_uart.f`, `tb_uart` | `uart` |
| GPIO | `rtl/gpio/filelist.f`, `garuda_gpio_top` | `tb/gpio/filelist_gpio.f`, `tb_gpio` | `gpio` |
| PWM | `rtl/pwm/filelist.f`, `garuda_pwm_top` | `tb/pwm/filelist_pwm.f`, `tb_pwm` | `pwm` |
| AHB interconnect | `rtl/ahb/filelist.f`, `ahb_interconnect` | `tb/ahb/filelist_ahb_ic.f`, `tb_ahb_interconnect` | `ahb` |
| AHB to APB bridge | `rtl/ahb2apb/filelist.f`, `ahb2apb_bridge` | `tb/ahb2apb/filelist_ahb2apb.f`, `tb_ahb2apb` | `bridge` |
| APB shim | linted inside every peripheral | `tb/common/filelist_shim.f`, `tb_apb_shim` | `shim` |
| DSU | `rtl/dsu/filelist.f`, `dsu_top` | `make test_dsu` (stimulus is generated first) | |

Lint errors to expect on a block linted alone, all listed in
`flow/2_static/hal_waivers.txt`: SPI master 3 and I2C 1 (vendored IP), debug 5
(the JTAG crossing), DMA, timers and bridge 1 each (hclk/pclk seen as unrelated
ports). Every other block: 0 errors.

## Stages 4, 5 and 6 by hand: one test of each kind

Same `irun` as for a block; what changes is the filelist, the top and the
plus-arguments. `C` only saves retyping the coverage options.

```bash
C="-64bit -coverage all -covoverwrite -covworkdir sim/manual/cov_work"

# ---- stage 4: CPU core ------------------------------------------------------
# a unit bench (any tb/core/filelist_<unit>.f; the top is always tb_top)
irun $C -f tb/core/filelist_decode_control.f -top tb_top -covtest unit_decode_control \
     -nclibdirname sim/manual/INCA_unit -l sim/manual/unit_decode_control.log

# an ISA test on the core, then the same program on Spike, compared instruction by instruction
irun $C -f tb/soc/filelist_boot_cov.f -top tb_boot -covtest isa_add \
     +HEX=sw/riscv-tests/build/add.hex +COMMIT=sim/manual/add_commit.log \
     +COVTAG=sim/manual/add_fcov +MAXCYC=100000 +QUIET \
     -nclibdirname sim/manual/INCA_boot -l sim/manual/isa_add.log
python3 tools/lockstep.py --rtl sim/manual/add_commit.log --elf sw/riscv-tests/build/add.elf \
     --spike-log sim/manual/add_spike.log --spike $SPIKE --max 3

# a directed program: the hold-versus-flush matrix, with interrupts and bus waits
irun $C -f tb/soc/filelist_boot_cov.f -top tb_boot -covtest san_matrix \
     +HEX=sw/build/t_hold_flush_matrix.hex +COMMIT=sim/manual/matrix_commit.log \
     +COVTAG=sim/manual/matrix_fcov +MAXCYC=400000 +QUIET +IRQ_EVERY=61 +DWAIT=2 +DRAND=1 +SEED=3 \
     -nclibdirname sim/manual/INCA_boot -l sim/manual/san_matrix.log

# the DSU against its model: generate the vectors, then run
python3 tools/gen/DSU_gen.py --count 400 --seed 1 --outdir sim/manual
irun $C -f tb/dsu/filelist_dsu_top.f -top tb_dsu_top -covtest dsu \
     +STIM=sim/manual/dsu_stim.mem +EXP=sim/manual/dsu_expected.mem \
     -nclibdirname sim/manual/INCA_dsu -l sim/manual/dsu.log

# ---- stage 5: integration ---------------------------------------------------
python3 tools/garuda_gen.py --check          # map headers match the system description (silent = ok)
irun -64bit -elaborate -f rtl/soc/filelist_chip.f -top garuda_chip_top \
     -nclibdirname sim/manual/INCA_elab -l sim/manual/elab_chip.log      # whole chip elaborates
irun $C -f tb/ahb/filelist_ahb_ic.f -top tb_ahb_interconnect -covtest ahb \
     -nclibdirname sim/manual/INCA_ahb -l sim/manual/ahb.log             # bus fabric
irun $C -f tb/soc/filelist_chip.f -top tb_chip -covtest chip_integ \
     +MODE=basic +TEST=sw/build/t_chip_integ.hex +MAXUS=4000 \
     -nclibdirname sim/manual/INCA_chip -l sim/manual/chip_integ.log     # every wire between blocks

# ---- stage 6: the chip from its pins ----------------------------------------
irun $C -f tb/soc/filelist_chip.f -top tb_chip -covtest chip_basic \
     +MODE=basic +TEST=sw/build/t_chip_basic.hex \
     -nclibdirname sim/manual/INCA_chip -l sim/manual/chip_basic.log

# coverage of everything run so far, merged
imc -execcmd "merge sim/manual/cov_work/scope/* -out sim/manual/cov_work/scope/all -overwrite -initial_model union_all"
imc -load sim/manual/cov_work/scope/all &
```

What to look for: unit bench `ALL CHECKS PASSED`; ISA and directed programs
`TOHOST=1 -> PASSED`, and `MATCH: n instructions identical` from the lockstep;
DSU `mismatches : 0`; chip tests `RESULT: PASSED`.

The other chip programs, same command with these arguments:

| Test | Plus-arguments |
|---|---|
| irq | `+MODE=irq +TEST=sw/build/t_chip_irq.hex` |
| wdt | `+MODE=wdt +TEST=sw/build/t_chip_wdt.hex` |
| flash | `+MODE=flash +TEST=sw/build/flash.hex +MAXUS=3000` |
| uart | `+MODE=basic +TEST=sw/build/t_chip_uart.hex` |
| periph | `+MODE=basic +TEST=sw/build/t_chip_periph.hex +MAXUS=1200` |
| jtag | `+MODE=jtag +TEST=sw/build/t_chip_jtag.hex +MAXUS=1500` |

The other directed core programs (`+HEX=sw/build/<name>.hex`): `t_flush`
`+IWAIT=3 +IRAND=1 +SEED=7`; `t_buserr` `+ERR_EN=1 +ERR_BASE=10020000
+ERR_SIZE=1000`; `t_irq` `+IRQ_AT=300`; `t_wfi` `+IRQ_AT=400`; `t_clic`
`+IRQ_EVERY=40 +IRQ_SWEEP=1`; `t_mtip` `+MTIP_AT=300`; the rest need none.

Running all 119 tests one by one is what the regression below is for.

## Stages 3 to 6: simulation with coverage (vManager, irun, IMC, SimVision)

One test by hand (this is exactly what vManager runs):

```bash
flow/regress/run_test.sh tb_uart              # stage 3, a block
flow/regress/run_test.sh unit_decode_control  # stage 4, a core unit bench
flow/regress/run_test.sh isa_add              # stage 4, ISA test + Spike lockstep
flow/regress/run_test.sh san_t_hold_flush_matrix
flow/regress/run_test.sh tb_ahb_ic            # stage 5, integration
flow/regress/run_test.sh chip_integ           # stage 6, the chip from the pins
```

The whole regression through vManager:

```bash
vmanager -local sim/vm_db &                   # GUI: Regression > Launch > flow/regress/garuda.vsif
# or without the GUI (119 runs, 8 at a time, about 8 minutes):
vmanager -local $PWD/sim/vm_db -execcmd "launch -wait flow/regress/garuda.vsif"
# the batch client can sit idle after the last run; count the results and Ctrl-C:
cat sim/vm_sessions/*/chain_0/run_*/local_log.log | grep -c 'GARUDA_RESULT: PASS'    # 119
cat sim/vm_sessions/*/chain_0/run_*/local_log.log | grep    'GARUDA_RESULT: FAIL'    # nothing
```

Groups in `flow/regress/garuda.vsif`: `block` (stage 3), `core` (stage 4: unit
benches, DSU, 63 ISA tests, sanity), `integ` (stage 5), `soc` (stage 6).
A run fails on any simulator error (assertion failures included), any `[FAIL]`
line, or a missing pass marker.

Merged coverage in IMC:

```bash
flow/regress/merge_cov.sh                     # merges every run of the latest session
imc -load sim/cov_merged/merged &             # GUI
less sim/cov_merged/summary.txt               # per-instance code coverage
less sim/cov_merged/functional.txt            # covergroups
```

Mirafra's UVM environment on the SPI master (Xcelium only; UVM 1.2):

```bash
export MIRAFRA_SPIM=~/external/mirafra/pulpino__spi_master__ip_verification
xrun -64bit -uvm -uvmhome CDNS-1.2 -sv -scu -timescale 1ns/1ps -access +r \
     -f rtl/spi_master/filelist.f -f tb/spi_master/uvm_mirafra/verif.f \
     -top hvl_top -top hdl_top \
     +UVM_TESTNAME=pulpino_spi_master_ip_basic_write_reg_test +UVM_VERBOSITY=UVM_MEDIUM \
     -xmlibdirname sim/uvm_spim/xcelium.d -l sim/uvm_spim/basic_write_reg.log
grep -E '^UVM_(ERROR|FATAL) :' sim/uvm_spim/basic_write_reg.log
```

Change `+UVM_TESTNAME` for another test (the names are the files in
`$MIRAFRA_SPIM/src/dv/hvl_top/test/`); add `-gui` for SimVision. The DUT is
`garuda_spim_top`, in `tb/spi_master/uvm_mirafra/hdl_top.sv`. Results of all 51
tests are in `sim/uvm_spim/all_tests.txt`: 16 clean, 35 flagged by the environment's
write-path-only scoreboard, identical to the same run on Mirafra's own RTL
(`Docs/BUGS.md` VIP-1).

Waveforms for one test in SimVision (Xcelium):

```bash
xrun -64bit -f tb/uart/filelist_uart.f -top tb_uart -access +rwc -gui &
xrun -64bit -f tb/soc/filelist_chip.f -top tb_chip -access +rwc -gui \
     +MODE=basic +TEST=sw/build/t_chip_integ.hex +MAXUS=4000 +TRAPLOG &
```

The same suites on Xcelium, quickly:

| Stage | Command | What it runs |
|---|---|---|
| 3 Block/IP | `make test_blocks` | 15 block benches |
| 4 CPU core | `make test_core test_elements` | unit and element benches |
| 4 CPU core | `make regress` | 63 ISA tests; 57 are also compared with Spike instruction by instruction |
| 4 CPU core | `make regress_rand SEED=3` | the same under random bus waits |
| 4 CPU core | `make test_sanity` | 12 directed programs, incl. the hold × flush matrix |
| 4 CPU core | `make pipe_matrix` | which hold × flush cells the programs reach |
| 4 CPU core | `make test_dsu` | DSU against its model |
| 5 Integration | `make test_ahb_ic test_bridge test_apb_shim elab_chip` | bus fabric, whole-chip elaboration |
| 6 SoC top | `make test_chip` | 8 programs from the pins |
| all | `make regress_all` | everything above |

Any `SVA_FAIL` other than 0, or `** n ASSERTION FAILURE(S)`, is a failure.

Debug aids in the chip bench: `+TRAPLOG` prints every trap (cause, pc, tval), and a
program can leave a breadcrumb with `csrw mscratch, n`, which the bench prints on a
timeout.

---

## Where the results are written down

- `Docs/BUGS.md` section 1h: every defect found on 2026-10-04, the tool or test
  that found it, and its status.
- `flow/2_static/hal_waivers.txt`: the lint and clock-domain items accepted.
