# GARUDA — licence-free local regression, 2026-10-03

**What this is.** A record of what was actually run on one Windows laptop with
no Cadence licence, no 28 nm library and no RISC-V toolchain, and what each
number traces to. Every figure below came from a command written out beside it,
starting from a wiped `sim/`.

**What it is not.** Signoff. Signoff is Xcelium 22.09 for function, Incisive
15.20 for coverage, and Genus against the 28 nm library for synthesis. Nothing
here replaces any of them, nothing here says anything about timing, and four of
the sixteen block testbenches cannot be built by Icarus at all.

**Why it exists.** Before today, no claim in this repository could be checked
without the lab. `sim/` is gitignored and was empty; the newest evidence in the
tree was 16 days old, and one of the six testbenches that produced it had since
been deleted. The point of this flow is that a reviewer with no licence can
reproduce the README's numbers from a clean checkout.

---

## Tool versions

| Tool | Version |
|---|---|
| Icarus Verilog | 14.0 (devel) s20260301-500-g2e81fcccb-dirty |
| Yosys | 0.69+185 (git sha1 fb1a2fdae-dirty) |
| Verilator | 5.053 devel rev v5.052-119-g014c9820d |

From the YosysHQ `oss-cad-suite` 2026-10-02 Windows x64 build. Put **both**
`lib/` and `bin/` on `PATH`, `lib` first, and export `VERILATOR_ROOT`
(`TOOL-3`, `TOOL-2`).

---

## 1. Block regression — `./scripts/run_sim.sh all`

`run_sim.sh` previously supported 5 tops out of 15. It now drives every block
testbench plus a new protocol-checker self-test, from the **same `.f` filelists
the Makefile's `xrun` leg consumes** — so a local run and a lab run build the
same source list. The moment a second flow gets its own hand-written source
list, it starts building different RTL from the one that was simulated, and the
divergence is silent.

| Testbench | Checks | Failures | Verdict |
|---|---:|---:|---|
| `tb_ahb_checker_selftest` | 6 | 0 | PASSED |
| `tb_apb_checker_selftest` | 35 | 0 | PASSED |
| `tb_crg` | 43 | 0 | PASSED |
| `tb_ahb_interconnect` | 802 | 0 | PASSED |
| `tb_ahb2apb` | 22 | 0 | PASSED |
| `tb_dma_top` | 25 | 0 | PASSED |
| `tb_clic` | 17 | 0 | PASSED |
| `tb_timers` | 23 | 0 | PASSED |
| `tb_debug` | 25 | 0 | PASSED |
| `tb_apb_shim` | 25 | 0 | PASSED |
| `tb_i2c` | 44 | 0 | PASSED |
| `tb_pwm` | 28 | 0 | PASSED |
| `tb_spis` | 34 | 0 | PASSED |
| `tb_dsu_top` | 90 vectors | 0 | PASSED |
| **14 ran** | **1,219** | **0** | **PASSED** |

Two of those testbenches are the protocol checkers' own negative controls, and
they are listed first on purpose: a clean run from an unproven checker is worth
nothing, so they are the two results everything below depends on.

`tb_dsu_top` needs generated stimulus first:
`python3 tools/gen/DSU_gen.py --outdir sim/dsu`. Without it the testbench prints
`FATAL: no stimulus` and stops, which is the correct behaviour — it does not
report a hollow pass. Note the generator's default `--outdir` is `.`, which
drops three build products into the repo root where `.gitignore` does **not**
cover them.

### Not buildable by Icarus

Not design defects, and not testbench defects either. Each is still built and
run on every regression, and the summary says so if one starts passing — a skip
list nobody re-tests becomes a list of tests nobody runs, which is this
project's own recurring defect (`TOOL-4`, `TB-11`, `TOOL-5`).

| Testbench | Why |
|---|---|
| `tb_mem_subsystem` | tb line 100, `reg [7:0] shadow [bit [31:0]]` — associative array keyed by a packed type |
| `tb_uart` | third-party `pulp/apb_uart_sv` `uart_rx.sv:171`, "This assignment requires an explicit cast" |
| `tb_gpio` | third-party `pulp/apb_gpio` `apb_gpio.sv:131`, variable index in a constant expression |
| `tb_spim` | third-party `pulp/axi_spi_master` compiles, but 12 × "sorry: constant selects in `always_*` not fully supported" mis-models tx/rx, and the run then spins with no simulation-time advance |

Three of the four are in vendored RTL this project does not own.

### Numbers this reproduces, and one it corrects

Six figures quoted in `README.md` are confirmed exactly: `tb_ahb_ic` **802**,
`tb_bridge` **20**, `tb_clic` **15**, `tb_crg` **43**, `tb_dma` **25**,
`tb_debug` **25**. `tb_timers` measures **23**, which is `HANDOFF.md`'s figure,
not README's 22.

The older on-disk log saying 796 was from an earlier revision of
`tb_ahb_interconnect`. The README number was right; the log was stale.

**Still unverified:** README's `tb_mem` 18/18. That testbench is one of the four
Icarus cannot build, and the stale on-disk log for it says 25, so the two
figures disagree and neither can be checked here. It needs one xrun run to
settle; the README row is left as it stands rather than guessed at.

**The "1,007 self-checking assertions" headline is unreproducible** and should
be retired. It was `27+37+33+25+796+89`, and the 89 came from
`tb/soc/tb_soc_ahb.sv`, deleted in `36e9630`. Today's figure is **1,219** across
14 testbenches, and it can be regenerated on demand.

---

## 2. Whole-chip lint — Verilator

Chip-level lint was recorded as impossible, per `RTL_LOG_2026-09-16.md:320`:
*"Lint is per-block only, not whole-chip … there is no chip-level lint."* It now
runs over all **108** sources of `rtl/soc/filelist_chip.f`. Two defects were
blocking it; both are fixed, both described in §4.

**No source errors; 22 warnings.** Verilator still exits non-zero because
warnings are fatal by default — its only `%Error` line is the
"Exiting due to 22 warning(s)" summary.

| Class | Count | Note |
|---|---:|---|
| `WIDTHEXPAND` | 13 | |
| `CASEINCOMPLETE` | 5 | all five in vendored PULP RTL (`apb_spi_master`, `axi_spi_master`, `apb_gpio`) |
| `WIDTHTRUNC` | 3 | |
| `LATCH` | 1 | `core_clk_gate.en_l` — the intended ICG enable latch, see §3 |

None is a new functional defect. They are a real backlog that now has a
baseline, which is what a lint target is for.

---

## 3. Whole-chip synthesis — Yosys, `./scripts/run_synth.sh`

Whole-chip Yosys synthesis **did not run at all** before today: it stopped at
`spi_master_clkgen.sv:13` from the moment the vendored PULP SPI master joined
the build. Fixed per §4.

| Metric | Value |
|---|---:|
| Cells, `garuda_chip_top` incl. submodules | **71,819** |
| Flip-flops | **7,029** |
| Latches | **1** (expected, see below) |
| `check -assert` | passes |

**README's "50,535 cells, zero latches" is stale.** It dates from 2026-09-16 and
predates I²C, GPIO, PWM, the SPI slave and `pipe_ctrl_sva`. The cell count is
not comparable and should be replaced rather than adjusted.

**On the latch.** There is exactly one, `core_clk_gate.en_l`. That is an
integrated clock gate: the enable latch *is* the cell. `HANDOFF.md`'s Genus
figure also reports 1 latch, and it is this one, so the two flows agree.
README's "zero latches" was never right — the gate that produced it was broken,
see §4.

---

## 4. Defects found in the flow itself

Four, all in tooling, all fixed. These matter more than the numbers above,
because each one was making a check report a result it had not measured.

1. **The latch gate reported "No latches inferred" while the netlist contained
   one.** `run_synth.sh` grepped its own log for a pattern that never matched
   the text Yosys writes. It now reads the object list Yosys emits via
   `select -list`, refuses to report anything if that file is absent, and allows
   the clock-gate latch **by name** so any other latch still fails the run.

   Proven by injecting a live latch into `clk_div`: the gate exits 1 and names
   it; reverted, it exits 0. An earlier attempt at that control was itself
   invalid — Yosys optimised the injected latch away because nothing read it, so
   the control had to be made observable before it meant anything. Note that
   grepping the log is unreliable in *both* directions: the "Latch inferred"
   warning also fires for latches that are subsequently deleted.

2. **`expand_filelist.py` emitted CRLF.** Every path it printed arrived with a
   trailing CR attached, and a shell does not word-split on CR. Icarus tolerates
   a stray CR in a filename, which is why the Icarus flow never noticed;
   Verilator reports the path as a module it cannot find. This is what made the
   expanded filelist look unusable for lint and kept chip-level lint a manual,
   per-block job. It applied to every invocation on Windows regardless of the
   filelist's own line endings.

3. **`expand_filelist.py --yosys` emitted `read_verilog` without `-sv`,** so
   Yosys's Verilog-2005 front end rejected `input logic clk` at
   `spi_master_clkgen.sv:13` and whole-chip synthesis failed outright. Now
   flagged per file, so Verilog-2005 sources keep being parsed as Verilog-2005.

4. **`run_sim.sh` could report two runs added together.** Per-testbench results
   accumulate through a file, because the loop runs in a subshell, and that file
   was not deleted first — the same class as a stale `.vvp`. It is now removed
   before every run. The runner also deletes each `.vvp` before building and
   gates on the compile's real exit code, so a stale binary cannot be reported
   as a pass, and it caps each testbench on wall-clock time, killing any orphan
   the cap leaves behind (on Windows `timeout` returns 124 while the native
   child survives, and an orphan spinning in a zero-delay loop takes a core for
   the rest of the session).

---

## 5. TB-22 — a reset held low from time 0 never reaches the design

The finding with the widest reach, and the reason the local flow produced
nothing before today.

A Verilog asynchronous reset is **edge sensitive in simulation**:
`always @(posedge clk or negedge rst_n)` is not evaluated merely because
`rst_n` is already low when the run starts. Five testbenches declared their
reset `= 0`, so no `negedge` ever occurred, and every flop whose only reset was
that signal stayed X for the whole simulation. In `clk_div` that flop is
`pclk_q`, and `pclk_q <= ~pclk_q` keeps X forever — so `pclk` and `preset_n`
never resolved, and `tb_crg` sat at `@(posedge preset_n)` having executed
**zero checks**, while still printing its banner.

Measured under Icarus: *neither* `reg a = 0;` *nor* `initial a = 0;` produces
the `negedge`, because the `always` block is not armed until after time 0. The
reset must be declared de-asserted and then asserted at time 0.

In silicon a reset pin is level sensitive and this cannot happen. It is a
simulation artefact, so the fix belongs in the testbench.

| Testbench | Before | After |
|---|---|---|
| `tb_crg` | stalled, 0 checks | **43**, 0 fail |
| `tb_ahb2apb` | stalled after 1 check | **20**, 0 fail |
| `tb_timers` | stalled, 0 checks | **23**, 0 fail |
| `tb_debug` | 25 checks, **15 fail** | 25, **0 fail** |
| `tb_dsu_top` | no stimulus | **90** vectors, 0 fail |

`tb_debug` is the instructive one: it did not hang, it *failed*, and all 15
failures were in DMI-dependent checks whose flops were X. A reader would have
gone looking for a bug in the debug module.

---

## 6. TB-15 — the AHB error-cancel false positive, closed

`ahb_lite_checker.v`'s `v_retract` counter flagged the AMBA-legal error cancel.
IHI 0033A §5.1.3 lets a master abandon the remaining transfers of a burst when a
slave responds ERROR; the first ERROR cycle is HRESP high with HREADY low, which
is inside the window the checker polices for address-phase stability.
`dma_ahb_master` does exactly this, so the check would have fired the first time
a SoC-level test drove a bus error into a DMA transfer.

Fixed, and the legal cancels are now **counted** rather than ignored — an
exemption that silently swallows traffic is indistinguishable from one that is
swallowing a real defect.

Verified by `tb/ahb/tb_ahb_checker_selftest.sv`, a new negative control for the
checker, which had none, against `ORACLES.md`'s own rule that *"a clean report
from a checker that has not been shown to fail is worth nothing."* It drives the
monitor's taps directly, so the corner is hit deterministically rather than
hoped for, with two scenarios differing in one bit of history:

| Scenario | Pre-fix | Post-fix |
|---|---|---|
| A: wait state **with** ERROR, then IDLE (legal cancel) | `v_retract=1` — false positive | `v_retract=0`, `n_err_cancel=1` |
| B: plain wait state, then IDLE (genuine retraction) | `v_retract=1` | `v_retract=1` — still caught |

Scenario B is the part that matters: without it, deleting the check altogether
would also have "passed".

**Also fixed in the checker:** `viol()` took its message as `[8*72-1:0]`, and a
Verilog string argument narrower than the literal passed to it drops the
*leading* characters silently. Three of the eighteen messages overflowed; the
two-cycle-ERROR message lost 17 characters off the front, so the log named no
rule at all. Widened to 96.

---

## 6b. The APB protocol checker

`Docs/HANDOFF.md` section 11 step 3 said to write this before the bridge. The
bridge, the shim and all seven peripherals shipped without it; the nearest thing
that existed was one rule inside `tb/ahb2apb/apb_slave_model.v`, which lives in
a **responder** and so was checking the bus it was also driving.

`tb/common/apb_checker.v` is a passive monitor with ten per-rule counters,
Verilog-2001 and no SVA so it compiles under both xrun 22.09 and irun 15.20
without an assertion licence. Verilator lint: **0 warnings**.

Its negative control, `tb/common/tb_apb_checker_selftest.v`, is **35 checks**.
Every rule is fired one at a time by an injected violation, and each scenario
also requires `v_total == 1` so that the injection fires *that* rule and nothing
else — a checker whose rules cross-trigger reports three violations for one
defect. Legal traffic, including the cases closest to the rules (back-to-back
accesses through SETUP, wait states, PSLVERR inside its access), must be silent
*and* must leave a non-zero access count: a clean report from a checker that saw
no traffic is treated as a failure here.

Bound so far, with the check counts it added:

| Testbench | Where bound | APB accesses seen | Checks |
|---|---|---:|---|
| `tb_ahb2apb` | the four modelled windows (1, 5, 9, 11) | 2 per window | 20 → 22 |
| `tb_apb_shim` | **both** sides — upstream bus, and the APB the shim generates out to the wrapped IP | 21 / 2 | 22 → 25 |
| `tb_clic` | the CLIC config port | 257 | 15 → 17 |
| `tb_i2c` | the I²C config port | 22,276 | 42 → 44 |
| `tb_pwm` | the PWM config port | 42 | 26 → 28 |
| `tb_spis` | the SPI-slave config port | 117 | 32 → 34 |

All six are clean. The shim's downstream port is the one worth noting: the shim
generates its own APB out to the IP it wraps, and nothing in this project had
ever looked at whether that bus was legal.

The access counts are quoted because they are the evidence that a binding is
looking at anything. `tb_i2c`'s 22,276 are mostly status polling, which is the
point: the protocol on that port had never been observed at all, and it has now
been watched across twenty-two thousand accesses. Every binding asserts a
non-zero count, so a silent checker fails rather than passes.

### Two things it found immediately

**A defect in itself (`TB-24`).** On the first bind the access counter triggered
on PENABLE's falling edge without also requiring the slave's own PSEL — and APB
fans a *shared* PENABLE out to every window, so each per-slave checker was
counting the whole bus. The tell was windows 1 and 11 reporting byte-identical
totals for two different windows. The self-test had missed it because it drives
a single PSEL, which is the same blind spot as checking a per-slave rule on a
single-slave bus. Fixed, and scenario M added; with the fix reverted, scenario M
fails, so it discriminates.

**A deviation in the bridge (`APB-1`).** On the 16-pclk timeout
`ahb2apb_apb_fsm.v:97-101` drops PSEL and PENABLE with PREADY still low. APB has
no abort. Measured on `tb_ahb2apb`'s deliberately-hanging window 2: a PREADY
stall of exactly 16 cycles, one abandoned access, one violation — while
`[N-7.15] 16-pclk PREADY timeout -> ERROR` passes, so it is intended. The
alternative is hanging AHB, and therefore the core, forever on a slave that is
already broken. **It is a reasonable trade-off that no document in the
repository mentioned**, so it is recorded for an owner ruling rather than
changed. The checker stays strict so the next occurrence is still reported.

Related and benign: the per-window APB divider keeps PENABLE high for extra
pclk cycles after PREADY, which is also past the strict end of an access. Rather
than exempting that silently, the checker takes `EXTEND_MAX` — 0 (strict) by
default, and window 11 binds with 1 because it runs /2. The stretch is reported
either way, and measured at exactly 1 cycle as predicted.

---

## 7. What this flow still cannot tell you

- **Nothing about timing.** No SDC exists (`AUD-4`), and Yosys here is generic
  structural synthesis. The 28 nm library, the SRAM/ROM macros and the pad ring
  are all absent from the tree.
- **Nothing about coverage.** That needs Incisive 15.20, and
  `run_coverage.sh` still collects from none of the 15 block testbenches.
- **Nothing that needs firmware.** `tb_chip`, `tb_boot`, `test_sanity` and the
  ISA regression all need a hex image, so the RISC-V toolchain is a hard
  prerequisite. `sw/build/` is empty.
- **Nothing about the 14 core element testbenches.** Icarus has no
  concurrent-assertion support, so **13 of 14 do not parse**; the one that does,
  `tb_clic_ctrl`, is also the only one with no SVA. Verilator parses them and
  then **segfaults** on 13 of 14 (exit 139), so its "0 errors" cannot be trusted
  either. `ELEM-1..6` is therefore **not locally verifiable** — see `ELEM-4` in
  `BUGS.md` for what was changed by inspection and what still needs xrun.
- **No gate-level simulation**, and no formal for `AUD-8`.

---

## 8. Reproducing this

```sh
# both lib and bin on PATH, lib first; VERILATOR_ROOT exported
python3 tools/gen/DSU_gen.py --outdir sim/dsu     # tb_dsu_top's stimulus
make local          # = local_sim + local_lint + local_synth
```

`make` is not installed on the machine this was run on, so the three recipes
were executed directly as `./scripts/run_sim.sh all`,
`./scripts/run_synth.sh garuda_chip_top`, and the Verilator command in the
`local_lint` recipe. **The Makefile targets themselves are therefore
unexercised** and should be run once on a host that has `make`.
