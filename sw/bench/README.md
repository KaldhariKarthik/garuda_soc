# sw/bench: CoreMark and Dhrystone on GARUDA (1-TOPS 5.7, flow stage F6)

| Benchmark | Source | Licence |
|---|---|---|
| CoreMark 1.0 | `coremark/core_*.c`, `coremark.h` from github.com/eembc/coremark at `1f483d5`, unchanged; `core_portme.[ch]` written for GARUDA from its `barebones/` | Apache 2.0 (`coremark/LICENSE.md`) |
| Dhrystone 2.2 | `dhrystone/dhrystone*.{c,h}` from riscv-tests `benchmarks/dhrystone` at `ec8e5a2`, unchanged; `util.h` and `sys/*.h` are GARUDA stand-ins | riscv-tests BSD (`dhrystone/LICENSE.riscv-tests`) |

## What is special about GARUDA

- **RV32I + Zmmul, M-mode, no C, no FPU.** Built with `-march=rv32i_zmmul_zicsr -O2`. Divide and
  remainder are software (`rt/bench_rt.c`), and the build fails if a compressed or divide
  instruction reaches an image.
- **No console in tb_boot.** `printf` writes into a 16 KB block at `0x1003_0000`
  (`.benchres`, `rt/bench_rt.h`). The bench dumps it at the end with `+SIGFILE`, and
  `tools/bench_report.py` prints the text, checks the self-check lines and gives the score.
- **Registers are not reset** (CORE spec, ID stage), so `rt/crt0_bench.S` zeroes x1..x31 before
  anything else. Without it the RTL saves and reloads X where Spike has 0.
- **Timing is mcycle at a notional 1 MHz**: CoreMark's ticks per second and Dhrystone's HZ are
  both 1 000 000, so "per second" means "per MHz". CoreMark needs 10 notional seconds
  (10 M cycles) to call a run valid; `CM_ITER` is set for that.

## Two images per benchmark

| Image | Timer | Used for |
|---|---|---|
| `build/coremark.hex`, `build/dhrystone.hex` | real `mcycle` and `minstret` | the score |
| `build/coremark_ls.hex`, `build/dhrystone_ls.hex` | fake: each read adds `0x0100_0000` | Spike lockstep: a real `mcycle` read differs between RTL and Spike by design, the fake one is the same on both |

Both run the benchmark's own self-check (CoreMark's CRCs, Dhrystone's "should be" values).

## Run (tcsh, from the repo root)

The commands with their expected lines are in `flow/COMMANDS.md`, G5 rows. In short:
`make -C sw/bench`, then one `xrun -R` per image on the tb_boot snapshot with
`+HEX=... +SIGFILE=... +SIGBEGIN=10030000 +SIGEND=10034000`, then
`python3 tools/bench_report.py <sigfile>`; for the `_ls` images also `tools/lockstep.py`.

This is a simulated score at zero wait states, not an EEMBC-certified CoreMark.
