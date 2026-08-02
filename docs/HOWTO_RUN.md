# How to run GARUDA yourself

Everything here is reproducible from a fresh terminal. Run the commands in order
the first time; after that, jump to whichever section you need.

---

## 0. Set up the shell (do this every new terminal)

```bash
cd ~/garuda_soc
source scripts/setup_env.sh
```

You should see six `OK` lines. **Nothing works without this** — no tool is on
`PATH` by default, and the Cadence license variable is not set globally.

The failure mode if you forget: `xrun` compiles and elaborates perfectly, then
dies at simulation with `xmsim: *F,NOLICN`. It looks like a design problem and
is not.

---

## 1. The 30-second check: does the CPU still work?

```bash
make test_boot     # 6 instructions, the smallest possible program
make test_c        # a real C program: stack, function calls, arrays, multiply
```

Expected:

```
*** TOHOST=1 -> PASSED (5 instructions retired) ***
*** TOHOST=1 -> PASSED (98 instructions retired) ***
```

If either says `TIMEOUT` or `FAILED`, something you changed broke the core.

---

## 2. The full instruction test suite

```bash
make isa_tests     # compile the RISC-V test programs (once, or after edits)
make regress       # run them all
```

This runs every test twice over, two independent ways:

- **TOHOST** — the test checks its own answers and reports pass/fail itself.
- **LOCKSTEP** — we run the identical program on Spike (the reference RISC-V
  simulator) and compare *every single instruction*. Any disagreement is a bug.

Both must say `PASS` / `MATCH`. A test can pass its own check and still diverge
from Spike — that is exactly the class of bug the self-checks miss, which is why
both columns exist.

Expected tail:

```
PASS=51 FAIL=11
```

### Run just one test

```bash
./scripts/run_regression.sh add
./scripts/run_regression.sh add sub lw sw
```

### Run with slow memory

```bash
make regress_wait      # injects 2 wait states on instruction fetch, 3 on data
```

Real memory is not instant. This proves the bus logic survives being made to
wait — it is how three of the four bugs found so far were exposed.

---

## 3. When a test fails: how to actually debug it

**Step 1 — what does lockstep say?**

```bash
cat sim/regress/<testname>.lockstep.txt
```

It prints the *first* instruction where GARUDA and Spike disagree, with the
three instructions before it for context:

```
DIVERGE at instruction 135 of 143
  ok   pc=10000234  x12=10000540      <- these three were correct
  ok   pc=10000238  (no gpr write)
  spike  pc=1000023c  x14=aabbccdd    <- what SHOULD have happened
  rtl    pc=1000023c  x14=00000617    <- what GARUDA did
```

Only the first divergence matters. Everything after it is downstream of the same
bug.

**Step 2 — what instruction is that?**

```bash
$RISCV_PREFIX'objdump' -d sw/riscv-tests/build/<testname>.elf | less
# then search for the pc, e.g. /1000023c
```

**Step 3 — watch the hardware do it.** `tb_boot` has built-in probes, switched
on with plusargs:

| Plusarg | Shows |
|---|---|
| `+DBGBUS` | instruction fetch: bus address, data, and each pipeline stage |
| `+DBGTRAP` | why a trap fired: cause, illegal-instruction flags |
| `+DBGD` | data bus: every load/store, address phase and data phase |
| `+DBGM` | the MEM stage and the writeback handshake |
| `+DBGACC` | DSU accumulator contents |

```bash
xrun -f tb/soc/filelist_boot.f -top tb_boot \
     -xmlibdirname sim/dbg/xcelium.d -l sim/dbg/run.log \
     +HEX=sw/riscv-tests/build/sw.hex +COMMIT=sim/dbg/commit.log \
     +MAXCYC=2000 +DBGD
```

**Step 4 — waveforms**, if the printouts are not enough. Add `+WAVES`, then:

```bash
simvision sim/dbg/waves.shm &
```

---

## 4. Run your own program on the CPU

Write C or assembly, drop it in `sw/tests/`, add its name to `CTESTS` or
`ATESTS` in `sw/Makefile`, then:

```bash
make -C sw all
xrun -f tb/soc/filelist_boot.f -top tb_boot \
     -xmlibdirname sim/mine/xcelium.d -l sim/mine/run.log \
     +HEX=sw/build/<yourtest>.hex +COMMIT=sim/mine/commit.log +MAXCYC=20000
```

Your program signals its result by writing to `tohost` (`0x1000F000`):
`1` = pass, `(n<<1)|1` = fail number *n*. For C, just `return 0;` from `main()`
— `crt0.S` does the rest.

### Two traps that will cost you an afternoon

1. **Use `lla`, never `la`.** The compiler defaults to position-independent
   code, where `la` becomes a load through a table that is empty on bare metal.
   Your address silently becomes **zero**. The CPU executes it perfectly and the
   program writes to address 0. It looks exactly like a broken load unit.
2. **Keep `-fno-pic -no-pie -mno-relax`** in the flags. They are in `sw/Makefile`
   for this reason.

---

## 5. The unit tests (individual blocks)

```bash
make test_core     # all seven: EX, ID/EX forwarding, EX/MEM, pipeline
                   # control, CSR file, trap control, EX+real DSU
```

---

## 6. The DSU (the accelerator)

```bash
make test_flag2    # compute-then-read ordering probe
```

This one currently **demonstrates a known issue**, it does not pass. See
`docs/VERIFICATION_LOG_2026-07-29.md`, FLAG-C.

---

## 7. Cleaning up

```bash
make clean                 # simulation outputs
make -C sw clean           # compiled test programs
make -C sw/riscv-tests clean
```

Nothing under `sim/`, `sw/build/` or `sw/riscv-tests/build/` is tracked by git —
all of it regenerates.

---

## Quick reference

| Command | What it does |
|---|---|
| `source scripts/setup_env.sh` | **required first, every terminal** |
| `make help` | list all targets |
| `make test_boot` | 6-instruction smoke test |
| `make test_c` | C program test |
| `make regress` | full instruction suite + Spike lockstep |
| `make regress_wait` | same, with slow memory |
| `make test_core` | the seven block-level unit tests |
| `make test_flag2` | DSU ordering probe |
| `./scripts/run_regression.sh add sub` | run named tests only |
