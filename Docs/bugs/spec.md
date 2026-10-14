# Bugs: Specifications across documents (AUD, SPEC)

Owner: owner of each spec. Index of all blocks: [`Docs/BUGS.md`](../BUGS.md). Process and fields: [`Docs/handbook/H3_bugs.md`](../handbook/H3_bugs.md).
Priorities: P1 the chip does the wrong thing or hangs; P2 a specified feature does not work but there is a workaround; P3 everything else (`flow/0_signoff_criteria.md`).

<!-- tools/bugs/bugs.py parses this table: one row per ID, columns fixed. Run `bugs.py check` before pushing. -->
| ID | Title | Status | Prio | Found-by | Found | Fixed-in | Regression test | Evidence | Formerly |
|---|---|---|---|---|---|---|---|---|---|
| AUD-1 | ten blocks marked rtl: missing that all exist | FIXED | - | - | 2026-09-26 | legacy | - | HISTORY_2026.md L139 | - |
| AUD-2 | Two incompatible window numberings | FIXED | - | - | 2026-09-26 | legacy | - | HISTORY_2026.md L140 | - |
| AUD-3 | entirely by hclk | FIXED | - | - | 2026-09-26 | legacy | - | HISTORY_2026.md L141 | - |
| AUD-4 | selectable | OPEN | P3 | - | 2026-09-26 | - | - | HISTORY_2026.md L142 | - |
| AUD-5 | 64 | FIXED | - | - | 2026-09-26 | legacy | - | HISTORY_2026.md L143 | - |
| AUD-6 | Comments still described the pre-ADR-0001 clock plan — "one 200 MHz domain", "200/100 MHz crossing", "TRM 100 MHz clock" | FIXED | - | - | 2026-09-26 | legacy | - | HISTORY_2026.md L144 | - |
| AUD-7 | required | FIXED | - | - | 2026-09-26 | legacy | - | HISTORY_2026.md L145 | - |
| AUD-9 | The DSU's port names diverge from its spec wholesale, and from the house style | OPEN | P3 | - | 2026-09-26 | - | - | HISTORY_2026.md L148 | - |
| AUD-10 | A second, hand-maintained source of truth | FIXED | - | - | 2026-09-26 | legacy | - | HISTORY_2026.md L149 | - |
| AUD-8 | sw/tests/t_hold_flush_matrix.S constructs 19 hold-versus-flush cells and checks architectural state | CLOSED | - | - | 2026-09-26 | legacy | - | HISTORY_2026.md L341 | - |
| AUD-11 | Each specification's planned tests and assertions were checked against what the benches actually do | OPEN | P3 | - | 2026-10-04 | - | - | HISTORY_2026.md L342 | - |
| AUD-12 | Found while writing the feature-level plans (stage 0): 512 features, of which 27 are places where a specification is ... | RULING-NEEDED | P2 | reading every spec feature by feature for the plans | 2026-10-04 | - | - | HISTORY_2026.md L394 | - |
| AUD-13 | Two things about PSLVERR are decided block by block and written nowhere | IN-PROGRESS | P3 | writing the PWM reference model from the specification | 2026-10-04 | - | dma/block tb_dma_top (two AUD-13 checks) | logs/dma/evidence/AUD-13_before.txt, AUD-13_after.txt | - |
| AUD-14 | garuda_soc_top.v header comment still maps DMA errors to CLIC IDs 7-12 (INT-2 moved them to 8-13; ID 7 = machine timer) | IN-PROGRESS | P3 | external plan review (Fresh AHB/APB/DMA plan 2026-10-13), checked against RTL (Fresh DMA-CON-02) | 2026-10-13 | - | - | rtl/soc/garuda_soc_top.v:25 vs :272-278 | - |

## Details

### AUD-1

*From `Docs/BUGS.md` at b90b481, line 139, section "1d. Doc-vs-RTL audit — 2026-09-26".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **AUD-1** | `garuda_system.yaml` | FIXED | The SSOT's `blocks:` table described a chip from three weeks ago: **ten blocks marked `rtl: missing` that all exist** (isram, bootrom, dsram, apb_fabric, ahb2apb, clic, timers, debug, clk_div, reset_ctrl) and **seven marked `rtl: sourced_ip` that are all implemented**. Block 14 still said "dropped for pin budget" after ADR-0020 Rev 2 restored it. Every document calls this file normative. `tools/garuda_gen.py` does not read `blocks:`, which is why nothing caught it. |

### AUD-2

*From `Docs/BUGS.md` at b90b481, line 140, section "1d. Doc-vs-RTL audit — 2026-09-26".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **AUD-2** | AHB2APB §6 + 4 specs | FIXED | **Two incompatible window numberings.** The AHB2APB window table was 0-based (`window 0 = 0x4000_1000`); the RTL decodes `win = haddr[15:12]`, so window *n* is at `0x4000_0000 + 0x1000n` — 1-based. DMA, CLIC, TIMERS and CLKRST each inherited the error and stated a window one lower than the hardware's. Base addresses were right everywhere; only the index was wrong. CLIC's "window 9" was `reset_ctrl`'s. |

### AUD-3

*From `Docs/BUGS.md` at b90b481, line 141, section "1d. Doc-vs-RTL audit — 2026-09-26".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **AUD-3** | `dma_apb_slave.v`, `timers_apb.v` | **FIXED 2026-09-26** | Both are clocked **entirely by hclk**, while ADR-0002 Rev 2, `apb.clock: pclk` and both specs' §4/§5 say the APB side is pclk. `dma_top` even takes `pclk_i`/`preset_n_i` and discards them. Not a functional bug — pclk edges are a subset of hclk edges (D-5) — but PRDATA is combinational out of hclk registers, so it can move mid-access and the bridge's effective setup window is **4 ns, not 8**; and these flops run at 250 MHz, which is the power ADR-0002 Rev 2 restored pclk to save. **Migrated.** The APB side is now pclk with the registers still hclk, and PRDATA is registered on pclk so it holds for the whole access phase — the 4 ns hop is now local to each block instead of crossing to the bridge. `tb_timers` gained a monitor counting mid-access PRDATA movement: **3 against the old RTL, 0 against the new**, so the test discriminates. Synthesis after: 7712 flops (+65), still 1 latch, 0 unresolved. |

### AUD-4

*From `Docs/BUGS.md` at b90b481, line 142, section "1d. Doc-vs-RTL audit — 2026-09-26".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **AUD-4** | PHYS §5 SDC | **OPEN** ([N-5.3]) | The SDC sketch will not elaborate: it constrains `[get_ports refclk_i]` (the pin is `refclk`), and `u_clk_div/u_clkdiv_toggle_hclk/Q` and `..._pclk/Q` (the flops are `t1_q` and `pclk_q`). Substantively, it declares a fixed `-divide_by 2` while `clk_div` implements a **selectable** ÷2/÷4/÷8/÷16 mux — and ADR-0001 makes ÷4 the timing fallback, so the other ratios need constraining too. `aon_clk` (D-14) is absent entirely. |

### AUD-5

*From `Docs/BUGS.md` at b90b481, line 143, section "1d. Doc-vs-RTL audit — 2026-09-26".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **AUD-5** | MEM §8.3, §8.5 | FIXED | Boot-time and ROM estimates predated a working boot path. §8.6 assumed 32 SCLK per word; it is **64** (command + address precede every word), so a 64 KiB image is **~67 ms, not 26**. The ROM is **820 bytes**, not ~500. Both now carry the measured figures. [N-8.7]'s "no document has verified the sourced IP" is also stale — GARUDA-SPIM-SPEC-001 now does. |

### AUD-6

*From `Docs/BUGS.md` at b90b481, line 144, section "1d. Doc-vs-RTL audit — 2026-09-26".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **AUD-6** | `ahb_interconnect.v`, `mul32.v` | FIXED | Comments still described the pre-ADR-0001 clock plan — "one 200 MHz domain", "200/100 MHz crossing", "TRM 100 MHz clock". The plan has been 500 → 250 → 125 since ADR-0001. |

### AUD-7

*From `Docs/BUGS.md` at b90b481, line 145, section "1d. Doc-vs-RTL audit — 2026-09-26".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **AUD-7** | `garuda_soc_top.v` | FIXED | `dma_req_i[4]` was commented "ch4 is spare", citing DMA [N-6.4] — which now says the opposite: channel 4 serves the SPI slave and is **required** (ADR-0020 Rev 2). The tie-off itself is still correct because `rtl/spi_slave/` does not exist; the comment now says that, and names un-tying it as the work item. |

### AUD-9

*From `Docs/BUGS.md` at b90b481, line 148, section "1d. Doc-vs-RTL audit — 2026-09-26".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **AUD-9** | DSU §5 vs `rtl/dsu/` | **OPEN** | **The DSU's port names diverge from its spec wholesale, and from the house style.** Spec §5 names `dsu_busy_o`, `dsu_result_o`, `dsu_illegal_o`, `dsu_acc_o`, `dsu_ovf_o`; the RTL has `dsu_busy`, `dsu_rd_data`, `illegal_instr`, `dsu_overflow`. Internal names the spec uses — `dsu_idle`, `dsu_interlock`, `dsu_decode`, `dsu_taps` — do not exist either. The DSU is also **the only block in the chip with no `_i`/`_o` suffixes**. Nothing is functionally wrong; the cost is that the spec cannot be read against the code. Decide which way to converge — renaming the RTL touches the core/DSU interface, so it is not free. |

### AUD-10

*From `Docs/BUGS.md` at b90b481, line 149, section "1d. Doc-vs-RTL audit — 2026-09-26".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **AUD-10** | `Design_Docs/*.docx` | PROCESS FIXED | **A second, hand-maintained source of truth.** No generator exists between `.md` and `.docx`. **Seven `.docx` are stale** — including every spec AUD-2 corrected, so a reviewer working from Word still reads the window-numbering error — and **five specifications have no `.docx` at all** (SPIM, I2C, UART, GPIO, PWM). Ruled in `Design_Docs/README.md`: the `.md` is normative. `make check_docs` now fails on drift; `make docs` regenerates via pandoc, which is not installed on the sim host. |

### AUD-8

*From `Docs/BUGS.md` at b90b481, line 341, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **AUD-8** | CORE §11 | **PARTLY CLOSED 2026-09-26** | **The core's stated verification does not exist.** [N-11.2] calls `t_core_hold_flush_matrix` "the most valuable new test in this project" — a 20-entry cross product that it says produced four errata, all found by inspection rather than by a test. **There is no such test**, under that name or any other. [N-11.3] names five SVA assertions for `pipe_ctrl` — `a_flush_beats_hold`, `a_trap_beats_branch`, `a_h2_defers_flush`, `a_no_gate_with_bus`, `a_no_gate_with_flush` — and **`pipe_ctrl.v` contains no assertions at all**. **The five properties now exist** as `rtl/core/pipe_ctrl_sva.sv`, bound at `garuda_core_top` on the **ungated** clock (bound to `gclk` they would stop being evaluated at the moment the gate closes, which is the moment they check). 22 assertions and covers elaborate and run in every simulation that instantiates the core. **The matrix is now measured**, by `make pipe_matrix`, and the result is the finding: across *every* test hex in the build, the nine plain hold x register cells are reached — H1 40/25, H2 112, H4 5, H5 399 962 — and **all four hold-versus-flush collision cells are reached zero times**. Those four are exactly where errata P-1, P-2 and P-3 came from. `t_core_hold_flush_matrix` as a directed test is still unwritten; see the note below for why that may be the wrong instrument. |

| ID | Where | Status | Summary |
|---|---|---|---|
| **AUD-8** | hold × flush matrix | **CLOSED in simulation** | `sw/tests/t_hold_flush_matrix.S` constructs 19 hold-versus-flush cells and checks architectural state. It found T-9, P-4..P-8, C-15 and DSU-13. All four collision cells that no test reached are now reached, and the test passes under eight wait-state and interrupt timings. Formal remains unavailable (FV-1). |

**2026-10-14:** Karthik 34cff0e: pipe_ctrl proved in SymbiYosys with assume-guarantee; the in-core reachability question and a_no_gate_with_flush still need a whole-core formal run (his section 1k).

### AUD-11

*From `Docs/BUGS.md` at b90b481, line 342, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **AUD-11** | the specifications' own verification plans (§10, §11), all 16 blocks | OPEN | **Each specification's planned tests and assertions were checked against what the benches actually do**, when the plans were moved into vPlanner (`tb/<block>/GARUDA_<BLOCK>_vplan.csv`). Of **221 planned tests**, 166 are run and pass, **28 are only partly run** (the test exists but not to the extent the plan states: fewer values, one window instead of all, no random sweep) and **27 are not written at all**. Of **165 assertions** in the §10 sections, **5 exist as SVA** (all in `rtl/core/pipe_ctrl_sva.sv`); most of the rest are checked procedurally by a bench check, and 17 are not checked in any form. Not written: CLIC `t_clic_level_trig`, `_no_edge`, `_latency`, `_nest`, `_spurious`, `_wfi_wake`; memories `t_boot_crc_fail`, `_recovery`, `_blank_flash`, `_trap`; timers `t_mtime_hi_alone`, `t_mtimecmp_naive`, `t_wdt_during_hartreset`, `t_timers_1khz`; debug `t_jtag_tap`, `t_sba_bulk_load`, `t_session_survives_reset`; clock/reset `t_no_por`, `t_sync_release`; DSU `t_dsu_apf`, `t_dsu_ekf_scope`; core `t_core_wfi_latency`; DMA `t_dma_random`; bridge `t_apb_no_cdc`; PWM `t_chip_pwm`; and two review gates. The per-test detail is in each plan's `implementation_note`. **Specification text found out of date while doing this:** DMA §10 `a_ch4_tied` contradicts its own [N-6.4] (channel 4 is the SPI slave); AHB2APB §11 lists windows 0x0 and 0xB–0xF as unmapped (0 is the SPI slave, 11 the timers); DEBUG R-8 says `dmactive` survives a reset where the bench checks decision D-18, that it does not; CORE §11 says 20 hold × flush combinations where the test has 19 cells. |

### AUD-12

*From `Docs/BUGS.md` at b90b481, line 394, section "1j. Stages 0 to 5 by the full flow — 2026-10-04 (evening)".*

| ID | Where | Status | Priority | Summary | Found by |
|---|---|---|---|---|---|
| **AUD-12** | specifications against RTL and against each other, all 16 blocks | **OPEN, each needs a ruling** | P2 | **Found while writing the feature-level plans (stage 0): 512 features, of which 27 are places where a specification is silent, out of date, or disagrees with the RTL or with another document.** Each is marked in its plan row. The ones where RTL and document disagree outright: (1) **DMA reach** - `garuda_system.yaml` and the AHB spec let the DMA address ISRAM; the DMA spec (R-9) and the DMA RTL refuse it. (2) **Clock gates that do not exist** - DMA [N-9.3] says a disabled channel receives no clock and DSU section 5 says the unit has its own idle gate; neither `rtl/dma` nor `rtl/dsu` contains a gate. (3) **Branch prediction** - CORE [N-7.1], [N-7.2] and section 13 say there is none; the RTL has a static predictor (`branch_predict.v`). (4) **Watchdog warning** - TIMERS [N-6.6], [N-6.8] say it is high for the one cycle the count equals the threshold; the RTL holds it while the count is at or below it (decision D-17). (5) **Register sources** - six specs name `spec/regs/<block>.yaml` as the machine-readable register source; the directory does not exist. (6) **Window numbers** - AHB2APB still says eleven windows and that window 0 is unmapped; MEM and AHB2APB place MEMCTL in window 8; the map has twelve windows, window 0 is the SPI slave and MEMCTL is in the reset controller's window. (7) **DMA CR** - the register table gives reset value 0 while SIZE resets to 2; a write of SIZE 3 is refused by the RTL and not mentioned in the spec. (8) **CLIC** - the ID map, [N-6.3] and four assertions in section 10 still describe the map before INT-2 and INT-3; [N-7.6] describes a two-stage tree where the RTL is a binary tree. (9) **mepc** - without the compressed extension both low bits should read zero; the RTL masked bit 0 only. Checked against Spike on 2026-10-05, confirmed and fixed as T-15. The remaining items are behaviours no document defines (what a write does when a FIFO is full, a second DIVSEL write while one is pending, which cause wins when two resets coincide, and similar); they are listed in the plans as open questions. | reading every spec feature by feature for the plans |

### AUD-13

*From `Docs/BUGS.md` at b90b481, line 399, section "1j. Stages 0 to 5 by the full flow — 2026-10-04 (evening)".*

| ID | Where | Status | Priority | Summary | Found by |
|---|---|---|---|---|---|
| **AUD-13** | register ports of all blocks | **OPEN, needs a ruling** | P3 | **Two things about PSLVERR are decided block by block and written nowhere.** (1) A write to a read-only register: the timers (WDTVAL) and the DMA (status registers) answer PSLVERR; the CLIC (CLICINFO, CLICIP), the reset controller and every block behind the shared shim (PWM STATUS, every ID register) ignore the write silently. (2) An offset that is not word aligned: the timers and the CLIC answer PSLVERR; the shim answers PSLVERR in its own range (0xFE1) and nothing at all inside the IP range (0x001 reads 0, no error). The second cannot happen in the chip, because the bridge refuses sub-word accesses and passes word addresses; the first can. Firmware that relies on a bus error to catch a write to a status register gets it from two blocks out of sixteen. The PWM plan had assumed the timers' behaviour for both; its rows now state what the specification and the RTL do. One rule for the whole chip should be written in the bridge specification. | writing the PWM reference model from the specification |

**2026-10-12:** Ruled in Karthik's two-track plan (proposed rulings table, agreed 2026-10-11): PSLVERR only for an offset that is not a register; a write to a read-only register is ignored. DMA part = Track A task 0.5: tb_dma_top now expects no PSLVERR on a write to STAT/GSTAT and fails on b90b481 (evidence AUD-13_before.txt); the fix is in rtl/dma/dma_apb_slave.v, plus the rule text in GARUDA-AHB2APB-SPEC-001 and GARUDA-DMA-SPEC-001 section 6. Timers part (WDTVAL) = Karthik's task 0.8. FIXED when both parts have commits.

### AUD-14

Fresh plan DMA-CON-02. The code is right: `garuda_soc_top.v:272-278` puts DMA complete on IDs 1-6 and DMA error on 8-13 (INT-2). But the file header at line 25 still says '7-12 DMA error  13,14 reserved'. The DMA spec (3.0a) and dma_top already say 8-13. Also stale: `Design_Docs/garuda_system.yaml:248` says the DMA config port is 'APB window 4'. It is window 5 (`dma_cfg`; window 4 = uart1), as the YAML's own window table says. Fix: one comment line in Karthik's file (shared), and the YAML comment. The chip-level test of all 12 IDs is in the bus plan's integration phase.

**AUD-14 fix, 2026-10-14 (comments only, made in Track A):** `rtl/soc/garuda_soc_top.v` header now gives the ID map as 1-6 DMA complete, 7 reserved, 8-13 DMA error, 14 SPI slave. The YAML comment says window 5 (`dma_cfg`). Both are Karthik's files; no logic change.
