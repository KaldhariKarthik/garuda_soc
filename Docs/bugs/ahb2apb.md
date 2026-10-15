# Bugs: AHB-to-APB bridge (rtl/ahb2apb)

Owner: Track A. Index of all blocks: [`Docs/BUGS.md`](../BUGS.md). Process and fields: [`Docs/handbook/H3_bugs.md`](../handbook/H3_bugs.md).
Priorities: P1 the chip does the wrong thing or hangs; P2 a specified feature does not work but there is a workaround; P3 everything else (`flow/0_signoff_criteria.md`).

<!-- tools/bugs/bugs.py parses this table: one row per ID, columns fixed. Run `bugs.py check` before pushing. -->
| ID | Title | Status | Prio | Found-by | Found | Fixed-in | Regression test | Evidence | Formerly |
|---|---|---|---|---|---|---|---|---|---|
| APB-1 | The 16-pclk timeout abandons an APB access mid-flight, which strict APB does not permit | RULING-NEEDED | P3 | `apb_checker` bound to window 2 | 2026-10-03 | - | - | HISTORY_2026.md L269 | - |
| APB-2 | The bridge decodes only HADDR[15:12], so any address in region 0x4 above the 48 KiB aperture (e.g. 0x4001_5000, 0x4FFF_5000) aliases a live window instead of an ERROR | IN-PROGRESS | P2 | external plan review (Fresh AHB/APB/DMA plan 2026-10-13), checked against RTL (Fresh DMA-CON-04); reproduced on the real bridge | 2026-10-13 | - | ahb2apb/probe probe_alias (xfail APB-2); probe_control | logs/ahb2apb/evidence/APB-2_probe_before_after.txt (before: 3 accesses OKAY on window 5; after the proposed fix: 6/6 PASS, control 4/4) | - |
| APB-3 | AHB2APB spec and vPlan still say 'eleven windows' and 'window 0 unmapped', but the map has 12 windows (0 = SPI slave, ADR-0020 Rev 2) | IN-PROGRESS | P3 | external plan review (Fresh AHB/APB/DMA plan 2026-10-13), checked against RTL (Fresh BUS-CON-01) | 2026-10-13 | - | - | GARUDA-AHB2APB-SPEC-001.md:39,75,294,542; tb/ahb2apb/GARUDA_AHB2APB_vplan.csv R-2, t_apb_rw, t_apb_unmapped | - |
| TB-46 | tb_ahb2apb declared ext_rst_n = 1 before driving it 0 at #0, so clk_div_sva a_pclk_subset_hclk fired at time 0 (pclk leaving X); the bench printed PASS because its own summary does not count assertion failures | IN-PROGRESS | P3 | strict runner, bus plan B0 fresh baseline | 2026-10-13 | - | ahb2apb/bridge bridge (22 checks, 0 assertion failures) | logs/ahb2apb/evidence/TB-46_before_after.txt | - |
| TB-49 | The bridge's built-in check a_capture_stable_at_phase was a `$display("[BRG-ASSERT] ...")` that no regression counted as a failure, so it could never fail a test | IN-PROGRESS | P3 | bus plan B2 RTL read | 2026-10-14 | - | ahb2apb/fv_apb apb_prove (a_capture_stable_at_phase PROVEN) | rtl/ahb2apb/ahb2apb_sva.sv | - |
| BRG-1 | "accepts only from H_IDLE" silently drops every second back-to-back access | FIXED | P1 | - | 2026-09-16 | legacy | - | HISTORY_2026.md L560 | - |
| TB-19 | an APB monitor check that is invalid for a shared-PENABLE bus | FIXED | P2 | - | legacy | legacy | - | HISTORY_2026.md L1014 | - |

## Details

### APB-1

*From `Docs/BUGS.md` at b90b481, line 269, section "1g. The APB protocol checker — 2026-10-03".*

| ID | Where | Status | Severity | Summary | Found by |
|---|---|---|---|---|---|
| **APB-1** | `rtl/ahb2apb/ahb2apb_apb_fsm.v` | **OPEN — needs an owner ruling, not an RTL change** | low (deliberate, documented trade-off) | **The 16-pclk timeout abandons an APB access mid-flight, which strict APB does not permit.** On expiry (`ahb2apb_apb_fsm.v:97-101`) the FSM drops `psel_o` and `penable_o` with `PREADY` still low. APB has no abort: an access, once started, is supposed to complete. Measured on `tb_ahb2apb`'s deliberately-hanging window 2 — PREADY stall of exactly 16 cycles, one abandoned access, one `PSEL dropped mid-ACCESS` violation, while `[N-7.15] 16-pclk PREADY timeout -> ERROR` passes. So this is intended behaviour, not a bug: the alternative is hanging the AHB side, and therefore the core, forever on a slave that is already broken. It is recorded because **nothing in the repository said the bridge knowingly breaks APB to protect AHB**, and because a reviewer or a future integrator binding a checker to a real peripheral window will hit it. The ruling wanted is whether to state the deviation in GARUDA-AHB2APB-SPEC-001 §7.5 and accept it, or to hold PSEL and let STA/integration deal with a wedged window. The checker is left strict so the next occurrence is still reported. | `apb_checker` bound to window 2 |

### BRG-1

*From `Docs/BUGS.md` at b90b481, line 560, section "BRG-1 — "accepts only from H_IDLE" silently drops every second back-to-back access · `SPEC` / `FIXED IN RTL` · **Severity: high (silent data loss)**".*

#### BRG-1 — "accepts only from H_IDLE" silently drops every second back-to-back access · `SPEC` / `FIXED IN RTL` · **Severity: high (silent data loss)**

- **Where:** bridge spec §7.5; RTL `rtl/ahb2apb/ahb2apb_hclk_fsm.v`.
- **The defect:** §7.5 states "the bridge accepts a new transaction only from
  H_IDLE". But `H_RESP_OKAY` and `H_ERROR_2` both drive `HREADYOUT` **high** —
  they must, that is how the transfer completes — and a high HREADY is by
  definition the condition under which the master's next address phase *is
  accepted*, in that same cycle. A bridge that latched only from `H_IDLE` would
  let the master consider the transfer accepted and move on while the bridge
  ignored it.
- **Failure mode:** the access never reaches APB. HREADYOUT stays high, no error
  is raised anywhere, and the master gets stale or zero read data. Firmware
  configuring a peripheral with a run of consecutive stores — which is exactly
  how the DMA and the CLIC get programmed at boot — would lose every second
  write. A half-configured DMA channel is a transfer that silently does the
  wrong thing.
- **Fix:** acceptance is qualified on `hreadyout_o` being high rather than on
  one state, so `H_IDLE`, `H_RESP_OKAY` and `H_ERROR_2` all accept.
  `rtl/ahb/ahb_default_slave.v` already reasons this way for the identical
  reason ("S_ERR2 can accept a new transfer directly"), so the bridge is now
  consistent with the block beside it.
- **Test:** `tb/ahb2apb/tb_ahb2apb.sv` T8 — issues 8 back-to-back transfers and
  requires the APB slave model's own access counter to read 8. Counting at the
  far side is the point: a dropped transfer is invisible from the AHB side.
- **Spec action:** §7.5 should read "only states asserting HREADYOUT accept
  work", which is the property actually intended.

### TB-19

*From `Docs/BUGS.md` at b90b481, line 1014, section "TB-19 — an APB monitor check that is invalid for a shared-PENABLE bus  ·  `FIXED` · **Severity: medium (falsely alarming)**".*

#### TB-19 — an APB monitor check that is invalid for a shared-PENABLE bus  ·  `FIXED` · **Severity: medium (falsely alarming)**

- **Where:** `tb/ahb2apb/apb_slave_model.v`.
- **Symptom:** 25 `[APB-PROTO] PENABLE without PSEL` violations and two failed
  checks, against a bridge whose APB signalling was correct.
- **Root cause:** the model flagged `PENABLE && !PSEL`. APB fans out a **shared**
  PENABLE and selects peripherals with a per-slave PSEL, so during an access to
  window 9 the window 5 model legitimately sees PENABLE high with its own PSEL
  low. A real slave ignores PENABLE unless its PSEL is asserted.
- **Fix:** check removed; the valid "PENABLE in the same cycle PSEL rises" check
  is retained.
- **Lesson:** this is the TB-15 shape again. A monitor that cries wolf on legal
  traffic is worse than no monitor, because the next real violation lands in a
  log everyone has learned to ignore.

### APB-2

Reproduced 2026-10-13 with `tb/ahb2apb/tb_apb_probe.sv` on the real `clk_div` + `ahb2apb_bridge`, with all 12 windows present. The AHB decoder selects the bridge on `HADDR[31:28] == 4` (256 MiB), and `ahb2apb_bridge.v:102` takes the window from `haddr_i[15:12]` without checking `haddr_i[27:16]`. A word write and a read to 0x4001_5000 and a write to 0x4FFF_5000 each complete OKAY with one APB transfer on window 5 (dma_cfg). The control (0x4000_5000 OKAY on window 5; 0x4000_C000 ERROR, no PSEL) passes.

Why P2: garuda_system.yaml defines a 48 KiB APB aperture, and any other address in a region should fault (default-slave rule: 'the bus never hangs', a precise fault in the owning master). A wild pointer from the core or the DMA silently writes a live peripheral. The DMA's own R-9 check refuses only regions 0x0 and 0x1, so a DMA pointer to 0x4001_5xxx rewrites the DMA's own channel registers.

Proposed fix (one line): `win_ok = WINDOW_MASK[win] && (haddr_i[27:16] == 12'h000)`. The out-of-aperture access then takes the existing H_ERR1/H_ERR2 path with no PSEL. Test: probe_alias turns PASS; tb_ahb2apb and the chip programs are unchanged (t_chip_integ already expects a fault on an unmapped window). Alternative (not recommended): document region 0x4 as aliased every 64 KiB.

### APB-3

Documentation. The window count changed from 11 to 12 when ADR-0020 Rev 2 restored window 0 for the SPI slave. Stale text: AHB2APB spec lines 39 and 75 (R-2 'Decode eleven 4 KiB windows'), 294 ([N-7.11] 'All eleven windows'), and 542 ('all 11 windows'). Karthik's vPlan rows R-2, t_apb_rw ('all 11 windows') and t_apb_unmapped ('window 0x0 and 0xB-0xF error'), when window 0 is mapped and window 0xB is timers. The tests should cover all 12 windows plus the unmapped 12-15. Fix: edit the spec (generated .docx too) and the vPlan rows; Karthik owns the vPlan file.

### TB-46

Found in the bus plan B0 fresh baseline, 2026-10-13: Karthik's `tb_ahb2apb` printed `checks=22 FAIL=0 / RESULT: PASSED`, but the log also had `clk_div_sva.sv:54: Assertion failed ... a_pclk_subset_hclk: pclk changed at 0, the last hclk rise was at 0`. The bench declared `reg ext_rst_n = 1` and drove it to 0 at `#0` (TB-22), so at time 0 the reset read 1 while pclk left X, and the guarded assertion fired. It's the same start-up artefact the DMA chip manifests waive as "SHIM-RSTEDGE". The design is not involved. The real point is that the bench's own PASS line ignores assertion failures, and the strict runner catches them.

Fix (one line, `tb/ahb2apb/tb_ahb2apb.sv`, Karthik's file): declare `reg ext_rst_n;` (X). X→0 is still a negedge, so TB-22 holds, and the assertion's `=== 1'b1` guard stays quiet. After the fix: 22 checks, 0 assertion failures. The same fix pattern is used in `tb/ahb2apb/tb_apb_probe.sv`.


**APB-2 fix, 2026-10-14 (small change, made in Track A):** `rtl/ahb2apb/ahb2apb_bridge.v`, `win_ok` also requires `haddr_i[27:16] == 0` (`// ERRATUM APB-2`). `probe_alias` now PASSes (6/6), `probe_control` 4/4 and `tb_ahb2apb` 22/22 are unchanged. Status IN-PROGRESS until the commit SHA is recorded. **For Karthik's review:** the one RTL line.

**APB-3 fix, 2026-10-14 (doc):** `GARUDA-AHB2APB-SPEC-001.md` now says twelve windows in the summary, R-2, [N-7.11] and the R-1 test row; [N-6.2] describes window 0 as the SPI slave (ADR-0020 Rev 2). The `.docx` is regenerated (pandoc 3.1.11). Karthik's vPlan rows R-2 / t_apb_rw / t_apb_unmapped still say eleven and are left for him (his file).

### TB-49

Found in bus plan B2 (2026-10-14) reading `rtl/ahb2apb/ahb2apb_bridge.v`: the `ifndef SYNTHESIS` block named a_capture_stable_at_phase only printed `[BRG-ASSERT] capture moved during an APB transfer`. Neither Karthik's `sim_verdict.sh` nor the Track A runner counts that text, so the check could never fail a run. It also left an unreachable branch in the bridge's coverage. **Fix (made in Track A, comment-marked `TB-49` in the RTL; verification-only code, no netlist change):** the block is removed, and the check is now the bound property a_capture_stable_at_phase in `rtl/ahb2apb/ahb2apb_sva.sv`, PROVEN by SBY (`make fv_apb`). (TB-48 was taken by the renumbered TB-34 in the 2026-10-14 rebase.)

