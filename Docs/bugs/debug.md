# Bugs: Debug module + JTAG (rtl/debug)

Owner: Track A. Index of all blocks: [`Docs/BUGS.md`](../BUGS.md). Process and fields: [`Docs/handbook/H3_bugs.md`](../handbook/H3_bugs.md).
Priorities: P1 the chip does the wrong thing or hangs; P2 a specified feature does not work but there is a workaround; P3 everything else (`flow/0_signoff_criteria.md`).

<!-- tools/bugs/bugs.py parses this table: one row per ID, columns fixed. Run `bugs.py check` before pushing. -->
| ID | Title | Status | Prio | Found-by | Found | Fixed-in | Regression test | Evidence | Formerly |
|---|---|---|---|---|---|---|---|---|---|
| CDC-1 | 5 CLKDMN on the DMI payload | CLOSED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L312 | - |
| DBG-1 | A debug request could run twice | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L335 | - |
| DBG-2 | sbbusy did not cover the cycle in which a finished transfer's result is written into sbdata/sberror | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L336 | - |
| DBG-3 | dmactive = 0 reset only ndmreset/hartreset: sbcs, sberror, sbbusyerror and sbaddress0 survived the debugger's reset o... | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L337 | - |

## Details

### CDC-1

*From `Docs/BUGS.md` at b90b481, line 312, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **CDC-1** | HAL clock-domain checks | REVIEWED | Chip level: clocks found are `refclk` and `tck` only, so `dmi_cdc` is the one asynchronous boundary (DEBUG [N-7.16] holds). HAL does not analyse crossings into the divided/gated `hclk` at chip level, so the check was repeated on `debug_top`, where both clocks are ports: two-flop synchronisers found on the request and acknowledge toggles; **5 `CLKDMN` on the DMI payload** (`sbdata`, `hartreset`, `rdata_o`). Those are qualified-data crossings: the payload is loaded with the toggle and held until the acknowledge returns. A structural tool cannot see that, so they are waived on the handshake argument, not fixed. |

### DBG-1

*From `Docs/BUGS.md` at b90b481, line 335, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **DBG-1** | `rtl/debug/dtm.v` | FIXED | **A debug request could run twice.** A DMI scan that captured "busy" must itself be ignored, but the refusal was decided at Update-DR, 41 or more `tck` later, when the earlier request had usually finished. The debugger was told "busy, ignored", retried, and the request executed twice: with `sbautoincrement`, a word written twice or skipped. |

### DBG-2

*From `Docs/BUGS.md` at b90b481, line 336, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **DBG-2** | `rtl/debug/debug_module.v` | FIXED | `sbbusy` did not cover the cycle in which a finished transfer's result is written into `sbdata`/`sberror`. An `sbdata0` read landing there returned the previous word with `sbbusyerror` clear. |

### DBG-3

*From `Docs/BUGS.md` at b90b481, line 337, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **DBG-3** | `rtl/debug/debug_module.v` | FIXED | `dmactive = 0` reset only `ndmreset`/`hartreset`: `sbcs`, `sberror`, `sbbusyerror` and `sbaddress0` survived the debugger's reset of the module, and SBA still ran with the module inactive. |
