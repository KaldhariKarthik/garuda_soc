# Zero waivers: the work list before G6

Ruled by Karthik on 2026-11-16, after G5: the chip has to do exactly what is written, with
nothing excused. Every waiver, coverage exclusion, `ignore_bins`, lint baseline or waived
static finding is removed. Each one is closed in one of three ways:

1. **The RTL changes** so the point no longer exists, or so it does what the spec says.
2. **A test** reaches the point.
3. **The coverage model is rewritten** so it never creates a point the design cannot have
   (explicit bins in place of tool-made crosses; no `ignore_bins`).

Then the 1-TOPS checklist G0 to G5 and flow stages F0 to F8 run again on the final tree,
in order. No row is closed while anything in it is left.

**Rulings (2026-11-16).**
- Third-party RTL (`rtl/third_party`: opencores, pulp) is fixed in place. Every change is
  recorded in `rtl/third_party/MANIFEST.yaml` and `HASHES.txt`.
- Mutants and negative controls (`xfail.tsv` rows marked PLANTED, `mut_*`, `negctl_*`)
  stay. They are deliberately broken copies that must fail, to show each bench catches
  the defect; they are not waivers.
- The only two stated open items: the DFT test enable (`test_en_i`, tied to 0 until scan
  is wired in G7) and the SRAM macros (G3 3.10, waits for the PDK).

**Design rule that comes out of this.** Lint asks for a `default` in every `case`, and
coverage counts a `default` that can never run as a hole. So a `case` that lists every
value makes its last value the `default`: the arm is reachable and no arm is dead.

## Inventory on 2026-11-16 (tree `5dfc2ef`)

| # | Kind | Count | Where | State |
|---|---|---|---|---|
| Z1 | HAL findings carried in a baseline | 747 (5 errors, 742 warnings) with the old deck; **6,807 (712 errors) with every rule on** | `flow/2_static/hal_baseline.txt`, `hal_waivers.txt`, the 65 `-nocheck` rules of `hal.f` | open |
| Z2 | Verilator lint waivers | 40 lines | `flow/2_static/verilator_waivers.vlt` | open |
| Z3 | Yosys lint waivers | 7 lines | `flow/2_static/yosys_waivers.txt` | open |
| Z4 | CDC waivers | 25 rows | `flow/2_static/cdc/reports/waivers.csv` | open |
| Z5 | Superlint findings explained, not fixed | 77 | `flow/2_static/superlint/chip/RESULTS.md` | open |
| Z6 | Code-coverage waivers | core 67, DMA 27, AHB 14, DSU 7, bridge 6 entries | `tb/*/cov/*_waivers.toml` | open |
| Z7 | IMC exclusion files | about 3,800 lines over 13 blocks | `flow/cov/*_exclusions*.tcl` | open |
| Z8 | `ignore_bins` / `illegal_bins` | 88 | 14 bench files under `tb/` | open |
| Z9 | Open bugs | track A 21, track B 6 | `Docs/bugs/` | open |
| Z10 | Expected failures that are not mutants | to be listed from every `xfail.tsv` | `tb/*/run/xfail.tsv` | open |
| Z11 | Spec deviation and open CSR items | ARCH-DEV-1 (arch-test signature check), csr_map C-16 | `tools/archtest/sigcheck.py`, `make csr_map` | open |

**Lint ruling (2026-11-16): every HAL rule on.** The 65 rules `hal.f` switched off go back on,
style included. The only exceptions are file:line entries for structures the chip must have,
each with its reason; no baseline file. Style-only rewrites are proven with Conformal LEC (RTL
against RTL) before simulation.

HAL with every rule on (`sim/hal_all/hal.log`, 2026-11-16), in three groups:

| Group | Findings | Main rules | Closed by |
|---|---|---|---|
| A. Style | about 3,800 | STYVAL 1191, MAXLEN 817, NBGEND 368, SEPLIN 321, CTLCHR 243, OLDALW 142, BITUNS 131, NOBLKN 126 | RTL rewritten, each module proven equal by Conformal LEC, then simulated |
| B. Pipeline structure | about 1,750 | CBPAHI 708 (errors), SYNPRT 524, USEPRT 231, DALIAS 146, FDTHRU 62 | per-line exceptions with the path and why it is combinational (forwarding, hazard, stall, flush, bus decode); registering them would add a cycle each |
| C. Real lint | about 1,250 | widths, drivers, unused signals, FSM, reset and clock; the 5 errors | RTL fixed, the block's regression and formal rerun |

By directory: core 1585, pulp 1321, opencores 555, DMA 473, DSU 421, debug 376, AHB 287,
SoC 246, reset_ctrl 203, common 162, CLIC 147, I2C 145, timers 132, mem 127, SPI slave 119,
PWM 113, bridge 110, the rest 391.

With the old deck, HAL by directory: third-party pulp 249 (3 errors), core 108 (1 error), opencores 84
(1 error), reset_ctrl 44, DMA 37, SoC top 35, debug 34, DSU 28, I2C 24, UART 14, clk_div 13,
SPI slave 12, the rest 65.

The 5 HAL errors:

| Rule | Where | What |
|---|---|---|
| GLTASR | `rtl/core/garuda_core_top.v:124` | `core_rst_n_i & hartreset_n_i` drives an asynchronous reset: a glitch on either input resets the core |
| CDEFNC | `rtl/third_party/pulp/apb_spi_master/src/spi_master_apb_if.sv:119` | `case` without `default` |
| CDEFNC | `rtl/third_party/opencores/i2c/src/i2c_master_byte_ctrl.sv:220` | `case` without `default` |
| TERMST, UNRCHS | `rtl/third_party/pulp/axi_spi_master/src/spi_master_controller.sv:209` | state 3 of the FSM is unreachable and terminal |

## Order of work

1. **F4 static**, chip-wide: HAL, Verilator, Yosys, Superlint and CDC to zero findings with
   empty waiver and baseline files. After each block's RTL change, its own regression and
   formal runs again before the next block.
2. **F5 blocks**, one at a time: code and functional coverage to 100% with no exclusions;
   open bugs and real expected failures of the block closed.
3. **F6 and F8, the core**: PC carried as [31:2], cause and other fields at their real
   width, coverage model with explicit bins; arch-test with no signature exception.
4. **The checklist and the flow again**, G0 to G5 and F0 to F8, every row with new
   evidence on the final tree.

## F4 HAL to zero: method (2026-11-16)

HAL runs with its whole default rule set: 141 rules fired on the chip, 8,539 findings (713 errors),
128 own files and 15 third-party files (`sim/hal_zero/`, `tools/hal_zero.py --summary`).

**Gate.** `tools/hal_zero.py` fails on any finding that has neither been removed from the RTL nor
been given one row in `flow/2_static/hal_exceptions.tsv` (rule, file:line, the signal or instance,
class), and on any row that matches no finding. Each class names a structure the chip must have,
with its reason. No baseline, no rule switched off. `hal_baseline.txt`, `hal_waivers.txt`,
`tools/hal_baseline.py` and `tools/hal_deck.py` go when the gate is green.

**Equivalence.** Style rewrites are proven with JasperGold SEC, RTL against the committed RTL,
module by module (`tools/sec_rtl.py`): Conformal LEC is not offered by the licence server
("No such feature exists" for every Conformal level, 2026-11-16). SEC is sequential, so it also
covers rewrites that touch registers. Checked both ways: it proves an unchanged module and
fails a planted one-constant change (`wdt`).

**Naming (Karthik, 2026-11-16): rename to HAL's defaults.** Active-low names end in `_n`
(ALOWID); identifiers are 4 to 16 characters (IDLENG); no numeric suffix (NUMSUF); lower-case
nets and instances, upper-case constants (LCVARN, UCCONN); no VHDL/AMS keywords (KEYWOD,
AMSKWD); a clock or reset keeps its name across every port it passes (DIFCLK, DIFRST).
Renames run through RTL, benches, SVA, specs and docs, and are checked by the full regression.

**Language.** OLDALW asks for `always_ff` / `always_comb` / `always_latch`: own RTL moves to
SystemVerilog procedural blocks. Every process block is named (NOBLKN); every if/else/always body
has begin/end (NBGEND); one statement and one declaration per line (SEPLIN, DECLIN); lines of at
most 80 characters (MAXLEN); no bare numeric range or literal where a constant belongs (STYVAL,
CNSTLT); constants written with width and base, every bit (PRMVAL, PRMBSE, BITUNS, CONSBS).
Compiler directives leave the RTL (CDNOTE, CDWARN): shared `define`s become a package,
simulation-only checks move to bound SVA, the time unit is given once to each tool; the
`GARUDA_SRAM_BLACKBOX` switch stays until the SRAM macros (a stated open item).

**Order.** (1) real lint, own RTL then third-party, each block's regression and formal rerun;
(2) the style rewrite, SEC per module; (3) renames, full regression; (4) per-line exceptions for
what is left, once line numbers stop moving; (5) the gate replaces `static_lint` in both gates.

## Log

| Date | Item | Change | Evidence |
|---|---|---|---|
| 2026-11-16 | Z1 HAL error GLTASR (`garuda_core_top.v:124`) | D-36: one core reset. The Debug Module's hartreset is sampled on hclk in `rtl/reset_ctrl/core_rst_sync.v` (asynchronous clear from reset_ctrl's request register, synchronous assert one hclk after the grant, release two hclk after both drop); the core loses `hartreset_n_i` and its internal reset flop. `halt_req_o` is held through the grant, and `halt_safe_o` also waits for any load or store in EX or MEM, so nothing issues in the clock between grant and reset | GLTASR 1 -> 0; RDC-1 proven in SymbiYosys (PDR) and JasperGold (131/131 asserts, 0 undetermined); rawgrant mutant fails on `a_grant_only_safe` |
| 2026-11-16 | RDC-1 harness | The excuse for a forced (timeout) grant now lasts from the grant until the core leaves the reset it causes (`forced_q`), not while `haltinfo.haltforced` reads 1: a debugger W1C in the clock between the grant and the D-36 reset cleared the excuse while the forced reset broke a waited transfer (JasperGold trace, 1039 cycles). Outside that window every property is required | `tb/core/formal/rdc1_top.sv`, ASSUMPTIONS.md |
| 2026-11-16 | Formal mutants | 15 of 34 had been copied from an older RTL and missed later fixes (C-17, DSU-14, DMA-9/14/15, the SBA error rules, the bridge's removed check block); `trap_ctrl_b90b481` was a whole old file with two errata reverted. All 34 are now the current RTL plus one change, written by `tools/formal_mutants.py`, which `make check_tree` runs in both gates; `trap_prove_unfixed` is split into `trap_prove_no_t13` and `trap_prove_no_t14` | fv_core_trap 13/13, fv_core_csr 4/4, fv_core_rdc1 4/4 as expected; block suites below |
| 2026-11-16 | DSU cover `c_fold_replaced_ovf` (DSU-18) | Was in the depth-16 formal cover task, where a 48-bit overflow (~65000 cycles) can never be reached, and the DSU suite had not run since 2026-10-13, so nobody saw it. Moved beside `c_overflow` (simulation only); `tb_dsu_top_ovf_b2b.sv` now runs its four cases on all three accumulators | `logs/dsu/evidence/dsu18_covers_2026-11-16.txt`: 12/12 checks, both covers hit on mac0, mac1, mac2; fv_dsu 7/7 |
| 2026-11-16 | DMA formal: hidden exclusion | `dma_cover`, `dma_bmc` and `dma_prove` still removed the detectors of DMA-10, -11, -13, -14 and `a_write_data` before proving, though those bugs were fixed on 2026-11-04; the `*_find` tasks expecting each to fail had turned into XPASS. The detectors are back in all three tasks (only `a_ack_one_pclk_edge` stays out: it needs a real pclk and is proven in `dma_2clk.toml`); the four `*_find` tasks and their xfail rows are removed | fv_dma (below) |
| 2026-11-16 | DMA formal result | Every property of `dma_props_a.sv` (but `a_ack_one_pclk_edge`, `dma_2clk.toml`) proven: dma_prove PROVEN 369 asserts, dma_bmc depth 32 on 375, dma_cover reached; the 6 not in the prove model (`a_irq_level` ch1-5, `a_active_def` ch3) are folded to constant true by `opt -fast`, i.e. structural tautologies, and hold in the BMC; 5 mutants killed on their named property | `logs/dma/summary/fv_dma.tsv` |
| 2026-11-16 | Element bench summary | `run_tb_elem` counted `[PASS]` lines, which the element benches do not print, so 14 showed `PASS=0` beside "ALL CHECKS PASSED". It now prints the bench's own count and fails a bench that reports none | test_elements: 15 benches, 38 to 40056 checks each, 0 failed |
| 2026-11-16 | Open (Z10, DMA, F5) | Expected failures of fixed bugs still listed in `tb/dma/run/xfail.tsv` and run by no gate: `probe_dma9`, `probe_dma10`, `probe_dma11a/b`, `probe_unaligned`, `probe_stop_size`, `probe_m2m_ack`, `t_chip_dma_rearm` | to rerun, turn into passing checks and drop the rows |
| 2026-11-16 | JasperGold multiplier blackboxing | JasperGold blackboxes every multiplier by default (WNL018): `mul32`'s 33x33 and the DSU's 16x16, and the `a * b` inside `a_mul_product` itself, so that property failed in one cycle on two free values, and every cover that depends on a product could be reached by a value the multiplier never gives. `-bbox_mul 128` added to `pipe_ctrl_core.tcl`, `cov_g5_unr.tcl`, `block_fpv.tcl`, `unr_block.tcl`, `vacuity_block.tcl`; `a_mul_product` then PROVEN | `sim/zw_mul/jg2.log` |
| 2026-11-16 | DSU JasperGold block proof | With multipliers kept: 47/47 proven (was 20/20; the 16x16 product and 49-bit adder checks now prove instead of facing free values), 31/31 covers reached. `run_blocks.sh` gives the DSU `DEFS=FORMAL`, as SymbiYosys does, so the six simulation-only overflow covers (~65000 cycles from reset) are not posed to formal; simulation reaches them on every accumulator | `flow/formal/dsu/dsu_fpv.result.txt`; `logs/dsu/evidence/dsu18_covers_2026-11-16.txt` |
| 2026-11-16 | Whole-core harness over-constrained (FV-A1) | `flow/formal/core/ahb_slave_env.sv` assumed HREADY high whenever no data phase was outstanding. GARUDA's interconnect holds an ungranted master's address phase with HREADY low (`ahb_master_port.v`), so every whole-core proof assumed arbitration waits away, and `a_dport_addr_stable` was vacuous there (recorded as "proved at unit level"). The assumption now allows that wait: HREADY high only when the master presents nothing and owes nothing | whole core with the real DSU, multipliers kept, 60 min limit: 156/156 proven (a_pfb_order included, no longer undetermined), 134 covers, `a_dport_addr_stable` precondition covered; `cov_g5_unr` 3/3, 5/5; `flow/formal/core/pipe_ctrl_core.result.txt` |
| 2026-11-16 | F4 renames (Karthik: rename to HAL's defaults) | One name per clock and reset through every port (refclk, ext_rst_n, hclk, hreset_n, gclk, core_rst_n, pclk, preset_n, tck, dm_rst_n, aon_clk, ext_hrst_n); modules of 4 to 16 characters (14 renamed, files with them: alu_unit, iport_master, prefetch_buf, if_stage_top, dport_master, hazard_fwd_unit, ahb_dflt_slave, debug_dtm, watchdog, i2c_bit_ctrl, i2c_byte_ctrl, spim_apb_if, spim_clkgen, spim_ctrl); no numeric suffix (DSU accumulators by their spec names fx/fy/mag, funct3_fld, rs1_val); no reserved words; lower-case instances. Table: `flow/2_static/renames.tsv`, applied by `tools/rename_rtl.py` to RTL, benches, SVA, formal harnesses, specs | HAL with every rule on: DIFRST 33 -> 0, DIFCLK 33 -> 0, ALOWID 129 -> 9 (left: written-negative conditions, the style pass), IDLENG/NUMSUF/KEYWOD/AMSKWD/LCVARN own RTL -> 0 (third-party in its pass); regress_all PASS; uvm_b 8 x 22 PASS; fv_core_trap/csr/rdc1, fv_cov_unreach, fv_dsu, fv_apb, fv_ahb, fv_dma all as expected |
| 2026-11-16 | Open from RDC-1 JasperGold | Covers proven unreachable: `c_ifid_flush_and_stall`, `c_pfb_wr_rd_full` (design facts), `c_h4_*` (DSU stub in this harness). To become assertions or move to the harnesses where they can happen, with the coverage-model work (F5/F6) | `sim/zw_rdc1/jg_t.log` |
| 2026-11-16 | Open from D-36 | HAL DIFRST 26 -> 33 (`core_rst_n_i` meets submodule ports named `rst_n_i`) and FRSTDF 9 -> 10 (the new synchroniser). Both close in the F4 reset-naming pass and the per-line exception list; the baseline is not raised | `sim/static/hal.log` |
