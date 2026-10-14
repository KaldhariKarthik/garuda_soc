# How to run GARUDA

This file gives the commands for the lab machine (Cadence tools) and for a machine with no
licence. Run section 1 first in each new terminal. `make help` lists every target.
The full verification flow, stage by stage, is in `flow/COMMANDS.md`.

---

## 1. Set up the shell

```bash
cd ~/garuda_soc
source scripts/setup_env.sh
```

Make sure that you see six `OK` lines. No tool is on `PATH` until you do this.

**Caution:** if the licence variable is not set, `xrun` compiles and elaborates, then stops
at simulation with `xmsim: *F,NOLICN`. This looks like a design fault. It is not.

---

## 2. Quick check of the core

```bash
make test_boot     # 6 instructions
make test_c        # a C program: stack, calls, arrays, multiply
```

Each must print `TOHOST=1 -> PASSED`. If one prints `TIMEOUT` or `FAILED`, your change broke
the core.

---

## 3. Full regression

```bash
make regress_all       # core, elements, blocks, sanity, DSU, ISA and chip
make -k regress_all    # the same; continue after a failure
```

A target fails when the simulator fails, when the log reports a failure, or when the pass
marker is missing (`scripts/sim_verdict.sh`).

| Target | What it runs |
|---|---|
| `make test_core` | Core unit smokes and the six constrained-random unit testbenches |
| `make test_elements` | The 14 per-element core testbenches |
| `make test_blocks` | The 15 block testbenches |
| `make test_sanity` | 12 directed core programs, including the hold × flush matrix |
| `make test_dsu` | The DSU against its model (vectors regenerated each run) |
| `make regress` | 64 ISA tests, each with its own check and, for 58, Spike lockstep |
| `make regress_wait` / `make regress_rand SEED=n` | The same with fixed / random bus wait states |
| `make test_chip` | 8 programs on the whole chip, from its pins |
| `make riscv_dv` | Random programs in lockstep with Spike |
| `make uvm_clic` (and `uvm_timers`, `uvm_pwm`, `uvm_gpio`, `uvm_crg`) | UVM environments with coverage |
| `make static` | HAL lint, clock-domain check, X-propagation |
| `make synth` | Genus structural synthesis (latches, drivers) |

### Run some ISA tests only

```bash
./scripts/run_regression.sh add
./scripts/run_regression.sh add sub lw sw
```

---

## 4. Debug a failing ISA test

1. Read the lockstep result. It shows the first instruction where GARUDA and Spike disagree:

   ```bash
   cat sim/regress/<test>.lockstep.txt
   ```

   Only the first divergence is important. Everything after it follows from it.

2. Find the instruction:

   ```bash
   ${RISCV_PREFIX}objdump -d sw/riscv-tests/build/<test>.elf | less
   ```

3. Run the test with a probe. The probes are listed in `Docs/HANDOFF.md` §7.

   ```bash
   xrun -f tb/soc/filelist_boot.f -top tb_boot \
        -xmlibdirname sim/dbg/xcelium.d -l sim/dbg/run.log \
        +HEX=sw/riscv-tests/build/<test>.hex +COMMIT=sim/dbg/commit.log \
        +MAXCYC=2000 +DBGD
   ```

4. For waveforms, add `+WAVES`, then run `simvision sim/dbg/waves.shm &`.

---

## 5. Run your own program on the core

1. Put the C or assembly file in `sw/tests/`.
2. Add its name to `CTESTS` or `ATESTS` in `sw/Makefile`.
3. Build and run it:

   ```bash
   make -C sw all
   xrun -f tb/soc/filelist_boot.f -top tb_boot \
        -xmlibdirname sim/mine/xcelium.d -l sim/mine/run.log \
        +HEX=sw/build/<yourtest>.hex +COMMIT=sim/mine/commit.log +MAXCYC=20000
   ```

The program reports its result with a write to `tohost` (`0x1000_F000` in `tb_boot`):
`1` is pass and `(n<<1)|1` is fail number *n*. In C, return 0 from `main()`; `crt0.S`
writes `tohost`.

**Caution:**
1. Use `lla`, not `la`. The compiler makes position-independent code, and `la` then loads
   address zero. The store goes to address 0, and this looks like a defect in the load unit.
2. Keep `-fno-pic -no-pie -mno-relax`. They are in `sw/Makefile` for this reason.

---

## 6. Without a Cadence licence

These targets use Icarus, Verilator and Yosys. Put the oss-cad-suite `lib/` and `bin/` on
`PATH`, `lib/` first, and set `VERILATOR_ROOT` (`Docs/BUGS.md` TOOL-2, TOOL-3).

```bash
make local_sim      # every block testbench that Icarus can build
make local_lint     # whole-chip Verilator lint
make local_synth    # whole-chip Yosys synthesis and the latch gate
make local          # all three
```

Icarus cannot build `tb_mem_subsystem`, `tb_uart`, `tb_gpio` and `tb_spim`. They still run,
so that a change in that result is reported. These targets do not replace the xrun flow.

Formal proof of `pipe_ctrl` (needs SymbiYosys and z3):

```bash
sby -f flow/2_static/fv_pipe_ctrl/sby/pipe_ctrl.sby
```

---

## 7. Design documents

```bash
make check_docs     # fails if a .docx is older than its .md
make docs           # regenerate the .docx exports (needs pandoc)
python3 tools/garuda_gen.py --check   # generated headers match the yaml
```

---

## 8. Clean up

```bash
make clean                     # simulation outputs
make -C sw clean               # compiled programs
make -C sw/riscv-tests clean
```

Git does not track `sim/`, `sw/build/` or `sw/riscv-tests/build/`. All of it can be made again.
