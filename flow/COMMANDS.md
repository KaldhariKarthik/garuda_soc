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

Each block plan is written feature by feature from the block's specification:
every register and field, mode, error path, corner case and cross-block
interaction. A feature row carries its check method (sim, formal, static, chip
level), an owner and a priority; under it are the named checks, coverage items
and tests, and what checks it today. The criteria a block has to meet are in
`flow/0_signoff_criteria.md`. Where a specification is silent or disagrees with
the RTL the row says so (`Docs/BUGS.md` AUD-12).

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

## UVM environment for a block (stage 2), by hand: the CLIC

```bash
D=sim/uvm_clic; mkdir -p $D
U="-64bit -uvm -uvmhome CDNS-1.2 -coverage all -covoverwrite -covworkdir $D/cov_work -covdut clic_top -nclibdirname $D/INCA_libs"

# compile once and run the register-model test (reset values, bit bash, aliasing)
irun $U -f tb/clic/uvm/filelist_clic_uvm.f -top tb_clic_uvm \
     +UVM_TESTNAME=clic_reg_test -svseed 1 -covtest reg_s1 -l $D/reg_s1.log
# the directed corners, then the random test with a seed (-R reuses the compile)
irun $U -R +UVM_TESTNAME=clic_directed_test -svseed 1 -covtest directed_s1 -l $D/directed_s1.log
irun $U -R +UVM_TESTNAME=clic_random_test   -svseed 7 -covtest random_s7   -l $D/random_s7.log

grep -E 'RESULT|UVM_ERROR :|clic_scoreboard|APB protocol' $D/random_s7.log
```

Look for `RESULT: PASSED`, `UVM_ERROR : 0`, the scoreboard line with 0
mismatches and `APB protocol checker: 0 violations`. irun prints one tool
error on every UVM run, `ncsim: *E,IMPDLL`; it does not affect the simulation
(`Docs/BUGS.md` TOOL-16). The whole regression, 22 runs: `make uvm_clic`
(`SEEDS=50` for more seeds).

Coverage, with the waivers and their reasons:

```bash
imc -execcmd "merge $D/cov_work/scope/reg_s1 $D/cov_work/scope/directed_s1 $D/cov_work/scope/random_s* -out $D/cov_work/scope/all -overwrite -initial_model union_all"
imc -load $D/cov_work/scope/all &          # GUI
imc -exec flow/cov/clic_report.tcl         # text: applies the waivers, writes sim/uvm_clic/code_cov.txt and func_cov.txt
```

What the pieces are: `tb/uvm/apb/` the APB agent every block reuses;
`Design_Docs/regs/clic.rdl` the register description and
`tools/gen/gen_ral.py` the generator of the register model; `tb/clic/uvm/` the
source agent, the reference model (written from the spec, never from the RTL),
the scoreboard, the covergroups named in the plan, the sequences and tests;
`rtl/clic/clic_sva.sv` the properties, bound to the RTL in every simulation.

### The same for the PWM

```bash
python3 tools/gen/gen_ral.py Design_Docs/regs/pwm.rdl tb/pwm/uvm/pwm_reg_pkg.sv     # only after editing the .rdl

D=sim/uvm_pwm; mkdir -p $D
U="-64bit -uvm -uvmhome CDNS-1.2 -coverage all -covoverwrite -covworkdir $D/cov_work -covdut garuda_pwm_top -nclibdirname $D/INCA_libs"

irun $U -f tb/pwm/uvm/filelist_pwm_uvm.f -top tb_pwm_uvm \
     +UVM_TESTNAME=pwm_reg_test -svseed 1 -covtest reg_s1 -l $D/reg_s1.log
irun $U -R +UVM_TESTNAME=pwm_directed_test -svseed 1 -covtest directed_s1 -l $D/directed_s1.log
irun $U -R +UVM_TESTNAME=pwm_random_test   -svseed 7 -covtest random_s7   -l $D/random_s7.log

grep -E 'RESULT|UVM_ERROR :|pwm_scoreboard|APB protocol' $D/random_s7.log

imc -execcmd "merge $D/cov_work/scope/reg_s1 $D/cov_work/scope/directed_s1 $D/cov_work/scope/random_s* -out $D/cov_work/scope/all -overwrite -initial_model union_all"
imc -exec flow/cov/pwm_report.tcl          # writes sim/uvm_pwm/code_cov.txt, func_cov.txt, holes.txt
```

The scoreboard line also counts "frames and pulses measured". Those are the
high time and the length of every undisturbed frame, counted on the four pins
and compared with DUTY x (PRESCALE + 1) and PERIOD x (PRESCALE + 1) straight
from the registers. That check does not use the model's counter, and it is the
one that found the stalled prescaler (`Docs/BUGS.md` PWM-4). The directed test
is long (1.7 million cycles) because it runs whole frames at PERIOD 0xFFFF and
at PRESCALE 0xFFFF. All 22 runs: `make uvm_pwm`.

The interrupt and register-port properties of this block are not in
`rtl/pwm/pwm_sva.sv` but in `rtl/common/garuda_apb_shim_sva.sv`: they are bound
to the shim, so the same properties check every peripheral window.

### The same for the GPIO

```bash
python3 tools/gen/gen_ral.py Design_Docs/regs/gpio.rdl tb/gpio/uvm/gpio_reg_pkg.sv   # only after editing the .rdl

D=sim/uvm_gpio; mkdir -p $D
U="-64bit -uvm -uvmhome CDNS-1.2 -coverage all -covoverwrite -covworkdir $D/cov_work -covdut garuda_gpio_top -nclibdirname $D/INCA_libs"

irun $U -f tb/gpio/uvm/filelist_gpio_uvm.f -top tb_gpio_uvm \
     +UVM_TESTNAME=gpio_reg_test -svseed 1 -covtest reg_s1 -l $D/reg_s1.log
irun $U -R +UVM_TESTNAME=gpio_directed_test -svseed 1 -covtest directed_s1 -l $D/directed_s1.log
irun $U -R +UVM_TESTNAME=gpio_random_test   -svseed 7 -covtest random_s7   -l $D/random_s7.log

grep -E 'RESULT|UVM_ERROR :|gpio_scoreboard|APB protocol' $D/random_s7.log

imc -execcmd "merge $D/cov_work/scope/reg_s1 $D/cov_work/scope/directed_s1 $D/cov_work/scope/random_s* -out $D/cov_work/scope/all -overwrite -initial_model union_all"
imc -exec flow/cov/gpio_report.tcl         # writes sim/uvm_gpio/code_cov.txt, func_cov.txt, holes.txt
```

This block has a second agent: the pad driver, which plays the outside world on
the two pins while the APB agent plays the firmware. The bench top stands in
for the pad cells (they are at the chip top). The scoreboard line ends with
what was checked "from the pads alone": settled pad levels against PADIN reads,
and pad edges against the interrupt line, with no model of the synchroniser in
between. The vendored block and the specification disagree in five places
(`Docs/BUGS.md` GPIO-2); the model follows the block and each place is marked
in `tb/gpio/uvm/gpio_env_pkg.sv`. All 22 runs: `make uvm_gpio`.

### The same for the clock divider and the reset controller

The two modules are verified together, connected as in the chip. There are two
design units to cover, so `-covdut` is given twice.

```bash
python3 tools/gen/gen_ral.py Design_Docs/regs/crg.rdl tb/clk_div/uvm/crg_reg_pkg.sv   # only after editing the .rdl

D=sim/uvm_crg; mkdir -p $D
U="-64bit -uvm -uvmhome CDNS-1.2 -coverage all -covoverwrite -covworkdir $D/cov_work -covdut clk_div -covdut reset_ctrl -nclibdirname $D/INCA_libs"

irun $U -f tb/clk_div/uvm/filelist_crg_uvm.f -top tb_crg_uvm \
     +UVM_TESTNAME=crg_reg_test -svseed 1 -covtest reg_s1 -l $D/reg_s1.log
irun $U -R +UVM_TESTNAME=crg_directed_test -svseed 1 -covtest directed_s1 -l $D/directed_s1.log
irun $U -R +UVM_TESTNAME=crg_random_test   -svseed 7 -covtest random_s7   -l $D/random_s7.log

grep -E 'RESULT|UVM_ERROR :|crg_scoreboard|APB protocol' $D/random_s7.log

imc -execcmd "merge $D/cov_work/scope/reg_s1 $D/cov_work/scope/directed_s1 $D/cov_work/scope/random_s* -out $D/cov_work/scope/all -overwrite -initial_model union_all"
imc -exec flow/cov/crg_report.tcl          # writes sim/uvm_crg/code_cov.txt, func_cov.txt, holes.txt
```

This environment is different in kind from the register blocks. Most of what it
checks is not a value but a time: the width of every clock pulse, two edges
falling at the same instant, the length of a reset. Those checks are properties
bound to the two modules (`rtl/clk_div/clk_div_sva.sv`,
`rtl/reset_ctrl/reset_ctrl_sva.sv`) and written with `$realtime`; they also run
in every chip simulation. The scoreboard line counts the resets it measured on
the pins. The APB agent here runs on the pclk and preset_n that come out of the
block under test, and a test can assert the reset pin at any instant, also with
the reference clock stopped. All 22 runs: `make uvm_crg`.

### The same for the timers and the watchdog

Only the names change. The register model is generated first; the generated
file is in the tree, so this step is needed only after editing the `.rdl`.

```bash
python3 tools/gen/gen_ral.py Design_Docs/regs/timers.rdl tb/timers/uvm/timers_reg_pkg.sv

D=sim/uvm_timers; mkdir -p $D
U="-64bit -uvm -uvmhome CDNS-1.2 -coverage all -covoverwrite -covworkdir $D/cov_work -covdut timers_top -nclibdirname $D/INCA_libs"

irun $U -f tb/timers/uvm/filelist_timers_uvm.f -top tb_timers_uvm \
     +UVM_TESTNAME=tmr_reg_test -svseed 1 -covtest reg_s1 -l $D/reg_s1.log
irun $U -R +UVM_TESTNAME=tmr_directed_test -svseed 1 -covtest directed_s1 -l $D/directed_s1.log
irun $U -R +UVM_TESTNAME=tmr_random_test   -svseed 7 -covtest random_s7   -l $D/random_s7.log

grep -E 'RESULT|UVM_ERROR :|tmr_scoreboard|APB protocol' $D/random_s7.log

imc -execcmd "merge $D/cov_work/scope/reg_s1 $D/cov_work/scope/directed_s1 $D/cov_work/scope/random_s* -out $D/cov_work/scope/all -overwrite -initial_model union_all"
imc -exec flow/cov/timers_report.tcl       # writes sim/uvm_timers/code_cov.txt, func_cov.txt, assert.txt
```

The scoreboard line counts hclk cycles, because this model is stepped once per
hclk cycle and compares `mtip`, the warning and the reset request in every one
of them, as well as every read. "watchdog resets seen" above 0 is expected: the
tests let the watchdog expire on purpose. All 22 runs: `make uvm_timers`.

Two things in this bench are worth reading. `tb_timers_uvm.sv` makes hclk and
pclk in one `initial` block with blocking assignments; a divider written
`pclk <= ~pclk` gives a different `WDTVAL` read by one count (`Docs/BUGS.md`
SIM-1). And the reset controller is replaced by a ten-line stand-in, because a
watchdog expiry resets the block under test in the middle of a run.

## Random instruction programs on the core (stage 3), by hand: riscv-dv

riscv-dv is the open-source random instruction generator (a UVM program that
writes assembly). It is cloned at `~/external/riscv-dv`. What it may generate
for GARUDA is `tb/core/riscv_dv/target/riscv_core_setting.sv`; the tests and
their options are `tb/core/riscv_dv/testlist`. One program, start to finish:

```bash
export RISCV_DV_ROOT=~/external/riscv-dv
G=/home/vivado/2025.2/Vitis/gnu/riscv/linux_toolchain/lin64/bin/riscv64-amd-linux-gnu
D=sim/riscv_dv; mkdir -p $D/asm

# 1. compile the generator (once)
xrun -64bit -access +rwc -f $RISCV_DV_ROOT/files.f +incdir+tb/core/riscv_dv/target \
     +incdir+$RISCV_DV_ROOT/user_extension -q -sv -uvm -uvmhome CDNS-1.2 -vlog_ext +.vh \
     -elaborate -xmlibdirpath $D -l $D/compile.log

# 2. generate one program: the "loop" test, seed 7  ->  $D/asm/loop_s7_0.S
xrun -64bit -R -xmlibdirpath $D +UVM_TESTNAME=riscv_instr_base_test +num_of_tests=1 +start_idx=0 \
     +asm_file_name=$D/asm/loop_s7 +instr_cnt=5000 +num_of_sub_program=5 +directed_instr_1=riscv_loop_instr,20 \
     -svseed 7 -l $D/loop_s7.gen.log

# 3. assemble and link it for the GARUDA memory map; find where tohost landed
$G-gcc -march=rv32im_zicsr_zifencei -mabi=ilp32 -mno-relax -fno-pic -static -nostdlib -nostartfiles \
     -Wa,--no-warn -I$RISCV_DV_ROOT/user_extension -T tb/core/riscv_dv/link.ld -no-pie \
     -Wl,--no-warn-rwx-segments -Wl,--build-id=none $D/asm/loop_s7_0.S -o $D/asm/loop_s7.elf
$G-objcopy -O binary $D/asm/loop_s7.elf $D/asm/loop_s7.bin
python3 tools/elf2hex.py $D/asm/loop_s7.bin $D/asm/loop_s7.hex
TH=$($G-nm $D/asm/loop_s7.elf | awk '$3=="tohost"{print $1}'); echo $TH

# 4. run it on the core (the same bench as the ISA tests)
xrun -f tb/soc/filelist_boot.f -top tb_boot -xmlibdirname $D/rtl.d -snapshot garuda_boot -elaborate -l $D/elab.log
xrun -R -xmlibdirname $D/rtl.d -snapshot garuda_boot -l $D/loop_s7.run.log \
     +HEX=$D/asm/loop_s7.hex +COMMIT=$D/loop_s7.commit.log +TOHOST=$TH +MAXCYC=600000 +QUIET

# 5. run it on Spike and compare
python3 tools/lockstep.py --rtl $D/loop_s7.commit.log --elf $D/asm/loop_s7.elf \
     --spike-log $D/loop_s7.spike.log --spike $SPIKE --tohost $TH
```

Step 4 ends with `TOHOST=1 -> PASSED` and `AHB-PROTOCOL: iport=0 dport=0
violations`; step 5 with `MATCH: n instructions identical; s stores, t traps,
c CSR instructions (v with a value) identical`. A `DIVERGE` prints the first
instruction, store, trap or CSR value where the RTL and Spike differ, with the
three instructions before it. All ten tests over several seeds:
`make riscv_dv` (`DV_SEEDS=20`, `DV_TESTS="illegal ebreak"`).

Which CSR addresses exist on the core and which on Spike is a separate,
exhaustive test, because a random program meets such an address by chance:

```bash
make csr_map        # reads all 4096 addresses on both; prints the two maps and every difference with its reason
```

What is compared and what is not: every retired PC and register write, every
store (address, size, data), every trap (cause, epc, tval) and the value of
every CSR an instruction writes. Not compared: anything with an interrupt
(Spike is not told when one is taken), and DIV/REM, which GARUDA runs in a
software handler; riscv-dv is told not to generate those four.

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
`TOHOST=1 -> PASSED`, and `MATCH: n instructions identical; s stores, t traps, c CSR instructions identical` from the lockstep;
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
benches, DSU, 64 ISA tests, sanity), `integ` (stage 5), `soc` (stage 6).
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
| 3 Block/IP | `make uvm_clic uvm_timers uvm_pwm uvm_gpio uvm_crg` | the UVM environment of each block done so far: register test, directed test, 20 random seeds, with coverage (irun 15.2) |
| 1 Static | `make static` | lint, clock-domain check and X-propagation on the whole chip |
| 4 CPU core | `make test_core test_elements` | unit and element benches |
| 4 CPU core | `make regress` | 64 ISA tests; 58 are also compared with Spike: PC, register writes, stores, traps and CSR values |
| 4 CPU core | `make regress_rand SEED=3` | the same under random bus waits |
| 4 CPU core | `make riscv_dv DV_SEEDS=20` | 200 random programs from riscv-dv, each compared with Spike |
| 4 CPU core | `make csr_map` | which of the 4096 CSR addresses exist on the core and on Spike |
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
