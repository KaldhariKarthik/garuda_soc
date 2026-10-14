# Bugs: Chip integration (rtl/soc)

Owner: Track B. Index of all blocks: [`Docs/BUGS.md`](../BUGS.md). Process and fields: [`Docs/handbook/H3_bugs.md`](../handbook/H3_bugs.md).
Priorities: P1 the chip does the wrong thing or hangs; P2 a specified feature does not work but there is a workaround; P3 everything else (`flow/0_signoff_criteria.md`).

<!-- tools/bugs/bugs.py parses this table: one row per ID, columns fixed. Run `bugs.py check` before pushing. -->
| ID | Title | Status | Prio | Found-by | Found | Fixed-in | Regression test | Evidence | Formerly |
|---|---|---|---|---|---|---|---|---|---|
| RTL-C1 | first word | FIXED | P3 | whole-chip Verilator lint | 2026-10-03 | legacy | - | HISTORY_2026.md L220 | - |
| INT-1 | The system description listed the SPI slave as block 14 but not in apb.windows, peripheral_functions or dma.assignmen... | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L325 | - |
| INT-2 | CLIC ID 7 reported the machine timer's cause | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L326 | - |
| INT-3 | The SPI slave's interrupt could not be enabled | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L327 | - |
| TB-30 | tb_chip never gives the reset pin a falling edge, so RSTREASON reads EXT only if the simulator makes one at time zero | FIXED | P3 | - | 2026-10-04 | c0dce4d | debug/chip (tb_chip, strict) | Docs/VERIFICATION_LOG_2026-10-11.md | - |
| VER-3 | The Spike lockstep now compares stores, traps and CSR values, not only the PC and register writes | FIXED | - | stage 3 of the flow | 2026-10-04 | legacy | - | HISTORY_2026.md L396 | - |
| TB-21 | the SoC interrupt check asserted behaviour the firmware had disabled | FIXED | P2 | - | legacy | legacy | - | HISTORY_2026.md L1045 | - |
| TB-37 | tb_chip sizes a JTAG image by an X sentinel that 2-state simulators never see | OPEN | P3 | audit F-03 (2026-10-04); Track A W4 chip check | 2026-10-04 | - | debug/chip t_chip_jtag | logs/debug/summary/chip.tsv | audit F-03 (part) |

## Details

### RTL-C1

*From `Docs/BUGS.md` at b90b481, line 220, section "1f. The licence-free local flow — 2026-10-03".*

| ID | Where | Status | Severity | Summary | Found by |
|---|---|---|---|---|---|
| **RTL-C1** | `rtl/dsu/mac_unit.v` | **FIXED** | low (blocked chip-level lint) | Verilator reads a comment whose **first word** is its own name as a lint pragma. A prose paragraph about yosys and the signed casts wrapped such that line 51 began *"Verilator both accept the casts…"*, so Verilator reported `BADVLTPRAGMA: Unknown verilator comment` and **aborted the whole-chip lint** — on a comment. Reworded, with a note not to re-wrap it back. | whole-chip Verilator lint |

### INT-1

*From `Docs/BUGS.md` at b90b481, line 325, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **INT-1** | `Design_Docs/garuda_system.yaml` | FIXED | The system description listed the SPI slave as block 14 but not in `apb.windows`, `peripheral_functions` or `dma.assignment` (channel 4 said "reserved"). The generated map therefore had no SPI slave base, window index or DMA channel, and the chip top and `t_chip_periph` hard-coded window 0. Added; the RTL and test now use the generated names. |

### INT-2

*From `Docs/BUGS.md` at b90b481, line 326, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **INT-2** | CLIC ID map | FIXED, **owner to confirm** | **CLIC ID 7 reported the machine timer's cause.** A CLIC interrupt enters with `mcause = 0x8000_0000 | ID` and the timer with `0x8000_0007`, so "DMA error, channel 0" (the IMU channel) was indistinguishable from a timer tick. A handler written as `if (mcause == 0x80000007) timer();` would push `mtimecmp` away and return with the DMA error still asserted, forever. The DMA error interrupts move from IDs 7..12 to **8..13**; ID 7 is reserved. Changed in the yaml, the generated map and `garuda_soc_top.v`. **The ID tables in the CLIC, DMA and TRM documents still say 7..12 and need the same edit.** Found by `t_chip_integ` step 2. |

### INT-3

*From `Docs/BUGS.md` at b90b481, line 327, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **INT-3** | `rtl/soc/garuda_soc_top.v`, `tools/garuda_gen.py` | FIXED | **The SPI slave's interrupt could not be enabled.** `clic_top`'s default `IE_MASK = 0x007F_9FFE` still excluded IDs 13 and 14 from when the SPI slave had been removed, and the SoC top did not override it. The line was wired and could go pending; `CLICIE[14]` read back 0. The mask is now generated from the ID map (`GARUDA_CLIC_ID_MASK`) and passed in. Found by `t_chip_integ` step 4. |

### TB-30

*From `Docs/BUGS.md` at b90b481, line 371, section "1i. Independent audit on free tools — 2026-10-04/05".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **TB-30** | `tb/soc/tb_chip.sv` | OPEN (testbench) | **`tb_chip` never gives the reset pin a falling edge, so RSTREASON reads EXT only if the simulator makes one at time zero.** `tb/soc/tb_chip.sv:21` starts `ext_rst_n` at 0. EXT is set only by the async branch at `rtl/reset_ctrl/reset_ctrl.v:139-141`, and `aon_clk` (`t1_q`, `rtl/clk_div/clk_div.v:66-69`) stays at 0 while the pin is low. Under Verilator 5.052 the three programs that read RSTREASON fail step 1 (`sw/chip/t_chip_basic.c:37`, `t_chip_wdt.c:25`, `t_chip_flash.c:45`); the four non-JTAG programs that do not read it pass. Xcelium evidently makes the edge (all eight passed on 2026-10-04); TB-22 found that Icarus does not. A copy that starts the pin high and drops it at 0.5 ns passes all seven non-JTAG programs. Same class as TB-22, whose fix covered five block benches but not this one. Silicon clears are level-sensitive: no confirmed RTL defect. Found by: a Verilator run of the stage 6 chip programs, then that diagnostic copy. |

**2026-10-14:** FIXED by Karthik in c0dce4d (tb_chip's reset pin falls). Track A XFAIL:TB-30 rows must go after the rebase.

### VER-3

*From `Docs/BUGS.md` at b90b481, line 396, section "1j. Stages 0 to 5 by the full flow — 2026-10-04 (evening)".*

| ID | Where | Status | Priority | Summary | Found by |
|---|---|---|---|---|---|
| **VER-3** | `tools/lockstep.py`, `tb/soc/tb_boot.v` | DONE | n/a | **The Spike lockstep now compares stores, traps and CSR values, not only the PC and register writes.** The commit log gained three records (`MEM`, `CSR`, `TRAP`; see the header of `tb_boot.v`) and the tool compares each as an ordered stream against what Spike logs. On the 58 tests that are compared with Spike: 24,946 instructions, 2,873 stores (address, size, data), 110 traps (cause, epc, tval) and 1,019 CSR instructions (397 with a value) are identical. Two differences are by specification and are written into the tool or kept out of the test with the reason: mtvec MODE reads 3 on GARUDA (CLIC only), and GARUDA has no software or external interrupt enable in mie and a hardwired misa. Negative control: a store with one data bit changed, a duplicated store, a removed trap, a changed mepc value and a changed mtvec base in an RTL log are each reported as a divergence. Interrupts are still outside the compare: Spike is not told when the RTL takes one. **Random programs:** riscv-dv (`~/external/riscv-dv`, target and test list in `tb/core/riscv_dv/`, `make riscv_dv`) generated 200 programs, ten test types over 20 seeds each (arithmetic corners, random instructions, jump stress, loops, random jumps, load/store stress, illegal instructions, ebreak, misaligned access): all 200 end in PASS on the RTL and match Spike on 2,458,733 instructions, 357,979 stores, 5,614 traps and 210,840 CSR instructions. No RTL defect was found by them. **Two defects of the comparison itself were found and fixed on the way:** it reported MATCH when Spike's log was shorter than the RTL's (Spike's instruction limit charges a whole 5,000-instruction slice per trap and stopped at the first one, so 84 of 241 instructions had been compared), and it compared against a Spike that has PMP and trigger CSRs GARUDA does not have. A short Spike log is now a MISMATCH and Spike is run with `--pmpregions=0 --triggers=0`. The first of these is the defect section 1i records as TOOL-12, found independently in the audit; its other half, that Spike's exit status is not read, is still open. | stage 3 of the flow |

### TB-21

*From `Docs/BUGS.md` at b90b481, line 1045, section "TB-21 — the SoC interrupt check asserted behaviour the firmware had disabled  ·  `FIXED` · **Severity: medium (falsely alarming)**".*

#### TB-21 — the SoC interrupt check asserted behaviour the firmware had disabled  ·  `FIXED` · **Severity: medium (falsely alarming)**

- **Where:** `tb/soc/tb_soc_ahb.sv`, interrupt-path check. Failed **twice**, in
  two different forms, against correct RTL.
- **First form:** sampled `dma_irq[0]` and the CLIC pending bit at the END of the
  run — a point sample of a transient. The firmware polls `SR.COMPLETE` and then
  W1C-clears it, which drops `dma_irq[0]` long before the check runs. Replaced
  with sticky observers.
- **Second form, the real one:** with sticky observers the check *still* failed,
  which proved `dma_irq[0]` was never high at any point. Cause:
  `soc_dma_smoke.S` programs CR with **IE=0 and EIE=0** — stated plainly in its
  own header — because it was written before the CLIC existed and polls instead.
  `dma_irq[n]` is raised only when `SR.COMPLETE` is set **and** `CR.IE=1`, so the
  DMA was correct to raise nothing. The testbench was asserting that hardware
  should do something the software had explicitly switched off.
- **Fix:** assert the correct behaviour (no interrupt raised, no CLIC source
  pending) and add a **continuous** monitor that the DMA's 12 lines equal CLIC
  sources [11:0] every cycle — which proves the wiring without needing an
  interrupt to fire.
- **Coverage gap this exposed, and it is real:** the DMA→CLIC→core interrupt
  path is wired and structurally checked but **never fires in any test**.
  Exercising it end to end needs a boot image with `CR.IE=1`, a CLIC level
  programmed over APB, and an ISR. That test does not exist yet and is the
  single most obvious next thing to write.
- **Lesson:** before asserting that hardware did something, check that the
  software asked it to.

### TB-37

`tb/soc/tb_chip.sv:191-192` fills the image buffer with X and counts words until `img[nwords] !== 32'hx`. Under 2-state Verilator nothing is X, so nwords = 16384 and the JTAG mode streams the whole 64 KB (42.6 ms of simulated time, audit F-03) instead of the program. The test still passes with a large +MAXUS budget. Fix (owner Karthik): size the image from the file (count the lines read, or +NWORDS). TB-30 (reset edge) is the other half of F-03.
