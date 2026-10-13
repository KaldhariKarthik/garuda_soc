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
| GPIO, coverage waivers | `unr_block.tcl`, `tools/gen/unr_check.py` | 545 of 551 toggle waivers confirmed not reachable, 0 reachable; the other 6 are inside a property module (`gpio_unr.result.txt`) | 2026-10-14 |
| PWM, coverage waivers | the same | 48 of 54 toggle waivers confirmed not reachable, 0 reachable; the other 6 are inside a property module (`pwm_unr.result.txt`) | 2026-10-14 |

The waiver check uses the coverage app (`-cov`, stimuli coverage) and not the unreachability
app (`-unr`): the latter wants the simulator's coverage database, read ours (irun 15.2) and
then found no item to work on. The coverage app needs no database. Its "unprocessed" list
is every item when the checker side is off, so it is not a verdict; the first version of
`unr_check.py` read it as one and confirmed everything, which a planted waiver on a bus
address bit showed at once. That planted case is how to test the checker:
a waiver on `paddr_i[2]` must come out REACHABLE.

Still to do for task 4.4: the block and expression waivers (IMC's index numbers do not
exist in JasperGold; they need matching by source line), and the CLIC, the timers and the
clock and reset block, which have more than one clock.

