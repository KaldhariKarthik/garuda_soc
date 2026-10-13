# Formal runs (JasperGold)

One directory per block: `flow/formal/<blk>/<name>.tcl`, the file list or environment
beside it, and `<name>.result.txt` with the tool's own summary. A script is run from the
repository root and never edited by the person who runs it for someone else.

## The tool on this machine (plan task 4.1, checked 2026-10-14)

JasperGold Apps 2022.09p002 at `/home/install/JASPER`; launcher `/home/install/JASPER/bin/jg`,
not on PATH. Rocky Linux 8.10 is not on its list of systems, so every run needs
`-allow_unsupported_OS`. The licence server is the one of the simulators
(`scripts/local_env.sh`).

Each app was started in batch on a five-line design with one assertion and one cover
(`sim/jg_apps/`, not kept) and had to prove the assertion:

| App | Option | Licence feature taken | Starts and proves |
|---|---|---|---|
| Formal property verification | `-fpv` | `jasper_papp` | yes |
| Unreachability | `-unr` | `jasper_papp` | yes |
| Coverage | `-cov` | `jasper_pcov` | yes |
| Connectivity | `-conn` | `jasper_papp` | yes |
| Clock-domain crossing | `-cdc` | `jasper_papp` | yes |
| X-propagation | `-xprop` | `jasper_papp` | yes |
| Superlint | `-superlint` | `jasper_papp` | yes |
| Sequential equivalence | `-sec` | `jasper_papp` | yes |
| Control and status registers | `-csr` | `jasper_papp` | yes |
| Low power | `-lpv` | none | no: does not start within 150 s |

So the plan's tasks that depend on an app can go ahead as written: 3.4 (clock-domain and
the `tck` to `hclk` handshake), 4.3 and 4.4 (properties and unreachability of the five
blocks), 5.7 (core), 7.2 (connectivity). Starting an app is not the same as its flow
working on GARUDA: each is confirmed when its first real run is recorded here.

## By hand

```bash
source scripts/setup_env.sh
/home/install/JASPER/bin/jg -allow_unsupported_OS -fpv -batch -no_jges \
    -proj sim/jg_core/jgproject flow/formal/core/pipe_ctrl_core.tcl
#   -batch and -no_gui cannot be given together; leave -batch out for the window
#   the project directory (-proj) holds the session log: jgproject/sessionLogs/
```

Two traps met on the first runs. `reset -expression` takes simple pin expressions only,
one per pin (`{!a} {!b}`), not `{!a || !b}`. Inside JasperGold `exec python3 ...` fails
with "undefined symbol: _Py_LegacyLocaleDetected", because the tool puts its own
libraries on `LD_LIBRARY_PATH`; call `exec env -u LD_LIBRARY_PATH python3 ...`.

## Runs recorded

| Block | Script | Result | Date |
|---|---|---|---|
| Core, `pipe_ctrl` properties on the whole core | `core/pipe_ctrl_core.tcl` | 9 of 9 assertions proven in every environment; with the real DSU and AHB-legal slaves all 13 hold-by-register and hold-against-flush cells are reachable | 2026-10-14 |
| Coverage waivers of the five closed blocks (task 4.4) | `./flow/formal/unr_block.sh <gpio\|pwm\|timers\|clic\|crg>` | 920 of 942 waivers confirmed, 0 reachable, 22 not checked (below); `<blk>_unr.result.txt` | 2026-10-14 |

### Waivers against JasperGold (task 4.4)

`unr_block.sh` runs three things for a block and compares them in `tools/gen/unr_check.py`:
IMC's detailed report of the block's merged UVM runs (it gives each of IMC's block numbers
its source line), the coverage app with every input free (`unr_block.tcl`), and the
property app for the waivers that say a property can never trigger (`vacuity_block.tcl`).

| Block | Waivers | Confirmed | Reachable | Not checked |
|---|---|---|---|---|
| GPIO | 666 | 657 | 0 | 9 |
| PWM | 60 | 51 | 0 | 9 |
| Timers | 93 | 92 | 0 | 1 |
| CLIC | 68 | 68 | 0 | 0 |
| Clock and reset | 55 | 52 | 0 | 3 |

The 22 not checked, and why:

- 16 are inside a property module (ports of `*_sva` tied to a constant, and two guard
  expressions of the divider's checker). The run asks about the design and leaves the
  property modules out.
- 6 are the shim's two simulation-only checks under `` `ifndef SYNTHESIS `` (the stop on a
  parameter out of range, the report of an IP that held PREADY low), in the GPIO and in the
  PWM. JasperGold builds with SYNTHESIS defined, as the chip is built, so the code is not there.

These 22 stand on their written reason alone.

Things that went wrong on the way, kept here so they are not repeated:

- The unreachability app (`-unr`) wants the simulator's coverage database, read ours
  (irun 15.2) and then found no item to work on. The coverage app needs no database.
- With the checker side off, the coverage app's "unprocessed" list is every item. The first
  version of `unr_check.py` read it as a verdict and confirmed everything.
- JasperGold holds the resets off after the reset state, so every statement in a reset
  branch comes out "unreachable, caused by reset". That is not a verdict; the checker
  reports it as RESET ONLY and does not confirm the waiver.
- Property names carry the top module (`clic_top.u_clic_sva.g_n[7].a_winner_max_level`);
  coverage items do not (`u_gpio.s_gpio_out[45]`).

The checker is tested by planting a wrong waiver, and each of these must come out
REACHABLE with exit status 1: a toggle waiver on `paddr_i[2]` of the GPIO, a block waiver
on block 12 of `garuda_gpio_top.u_gpio`, an assertion waiver on
`clic_top.u_clic_sva.g_n[8] a_winner_max_level` (`WAIVERS=<file> RESULT=<file> ./flow/formal/unr_block.sh clic`).

The clocks are given at one ratio per block (pclk at half of hclk; for the reset
controller hclk at half of the always-on clock). The waived items are read-data bits that
are zero in every register, tied-off ports and logic of pins that do not exist; none
depends on the ratio.
