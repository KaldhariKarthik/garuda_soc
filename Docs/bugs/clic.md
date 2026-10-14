# Bugs: CLIC (rtl/clic)

Owner: Track B. Index of all blocks: [`Docs/BUGS.md`](../BUGS.md). Process and fields: [`Docs/handbook/H3_bugs.md`](../handbook/H3_bugs.md).
Priorities: P1 the chip does the wrong thing or hangs; P2 a specified feature does not work but there is a workaround; P3 everything else (`flow/0_signoff_criteria.md`).

<!-- tools/bugs/bugs.py parses this table: one row per ID, columns fixed. Run `bugs.py check` before pushing. -->
| ID | Title | Status | Prio | Found-by | Found | Fixed-in | Regression test | Evidence | Formerly |
|---|---|---|---|---|---|---|---|---|---|
| CLIC-1 | 32-entry arrays indexed with a 10-bit index | FIXED | P3 | - | 2026-09-16 | legacy | - | HISTORY_2026.md L609 | - |
| TB-20 | CLIC latency sampled one edge early, and a stale source left asserted | FIXED | P2 | - | legacy | legacy | - | HISTORY_2026.md L1029 | - |

## Details

### CLIC-1

*From `Docs/BUGS.md` at b90b481, line 609, section "CLIC-1 — 32-entry arrays indexed with a 10-bit index · `FIXED` · **Severity: low (latent)**".*

#### CLIC-1 — 32-entry arrays indexed with a 10-bit index · `FIXED` · **Severity: low (latent)**

- **Where:** `rtl/clic/clic_apb_regs.v`, ten index sites (lines 143–150 write
  path, 166–172 read mux).
- **The defect:** `ie_q`, `trig_q`, `shv_q`, `lvl_q`, `ip_w1c_q` and `ip_i` all
  hold `CLIC_N` = 32 entries and need a 5-bit index, but were indexed with
  `idx[9:0]` — the full 10-bit APB register offset. Verilator:
  `WIDTHTRUNC: Bit extraction of var[31:0] requires 5 bit index, not 10 bits`,
  at every one of the ten sites.
- **Why it was harmless in practice, and why it still matters:** `idx_ok`
  (`idx < CLIC_N`) gates every write and the read mux, so an out-of-range index
  never reaches an array in the current design. The truncation is therefore
  latent rather than active — but it is exactly the construct that turns into a
  silent aliasing bug the moment `CLIC_N` changes or the qualification is
  restructured, and it is the kind of thing a reader has to re-derive `idx_ok`
  to convince themselves about.
- **Fix:** added `IDX_W = $clog2(CLIC_N)` and `aidx = idx[IDX_W-1:0]`, used for
  array indexing only. `idx` deliberately stays 10 bits wide because the range
  check needs the full offset — narrowing it *there* would fold a stray address
  onto a live source, which is the precise failure `idx_ok` exists to prevent.
  No architectural or behavioural change.
- **Confirmed:** `WIDTHTRUNC` 7+ → **0**; `tb_clic` 33/33 with 0 failures;
  `clic_top` synthesis 3,449 → **3,322** cells (the narrower index removes
  width-extension logic), 0 latches; full regression still 1,007 / 0.
- **How it was found, and the process defect behind it:** only after two earlier
  Verilator attempts had aborted and been *misreported as clean*. The working
  invocation was already documented in this register as **TOOL-2**
  (`VERILATOR_ROOT`, and `+incdir+path` not `-I path`) and was not consulted.
  The register had the answer; nobody read it.

---

### TB-20

*From `Docs/BUGS.md` at b90b481, line 1029, section "TB-20 — CLIC latency sampled one edge early, and a stale source left asserted  ·  `FIXED` · **Severity: medium (falsely alarming)**".*

#### TB-20 — CLIC latency sampled one edge early, and a stale source left asserted  ·  `FIXED` · **Severity: medium (falsely alarming)**

- **Where:** `tb/clic/tb_clic.sv` T4/T5/T7/T12. Seven failures against correct RTL.
- **Root causes, three of them:**
  1. Latency was sampled one clk edge early. Spec §9.1 budgets one clk from
     *pending* to `clic_irq` — but pending is itself registered, so from the
     source **line** rising it is two edges. Confirmed with a directed probe:
     `ip` sets at edge 1, the winner register and `clic_irq` follow at edge 2.
  2. T7 acknowledged a level source while its line was still high, then expected
     a different winner. Re-firing is *correct* behaviour (§8.4) — the test was
     asserting the opposite of the specification.
  3. T12 never cleared `irq_src[3]` from T4, so a level-4 source outranked the
     level-2 source under test and kept the request asserted.
- **Fix:** sample after two edges, clear the source before acknowledging, and
  clear all sources before the enable/disable test.
