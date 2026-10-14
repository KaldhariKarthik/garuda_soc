# Formal assumption register: DMA (Docs/handbook/H6_formal.md)

A proof is only as good as the assumptions next to it. Every harness under
`tb/dma/formal/` lists here what it assumes, why that is justified, and the
simulation check that backs it. Written 2026-10-12 (Track A DMA plan D2).

## Harnesses

| Manifest | Environment | Clocking | Used for |
|---|---|---|---|
| `dma.toml` | `dma_fv_env.sv` (FD-1..FD-5) | single clock: SBY clocks every flop once per step, so pclk = hclk | every hclk-domain property (PDR proof, bounded check, covers), the open-bug finders, the negative controls |
| `dma_2clk.toml` | `dma_fv_env_2clk.sv` (FD-6..FD-9) | two clocks (`multiclock on`), pclk = hclk/2 on shared edges | the properties whose meaning depends on real pclk timing: `a_pready`, `a_pslverr_rule`, `a_read_data`, `a_prdata_stable`, `a_ack_one_pclk_edge` |
| `arb.toml` | none (combinational) | — | `dma_arbiter` under five PRIO settings against a reference written from the spec |

## Assumptions

| ID | Harness | Assumption | Justification | Backed by (simulation) |
|---|---|---|---|---|
| FD-1 | `dma.toml` | `hreset_n` and `preset_n` low for the first 2 cycles, then high for good | a power-up reset; reset in mid-run (vPlan F47) is not covered by these harnesses | every DMA bench and chip run starts this way; F47 is closed in simulation (DMA plan D5) |
| FD-2 | `dma.toml` | **single clock** (pclk = hclk): an APB access lasts one cycle, so a register write takes 2 hclk instead of 4 and may start on any cycle | for the hclk-domain logic (channels, arbiter, engine, write strobes) this is an over-approximation of D-5: every real sequence of register writes (4-hclk spacing, pclk-aligned) is one of the sequences allowed here, and the only pclk flop (`prdata_q`) does not feed the hclk logic. So a hclk-domain property PROVEN here holds on the real design. A counterexample may need writes faster than software can make them, so each one is replayed with real timing before it is filed. The pclk-timing properties are proven in `dma_2clk.toml` instead (`a_prdata_stable` is vacuous here: an access lasts one cycle, cover `c_apb_access2` unreachable; `a_ack_one_pclk_edge` is false by construction here and is left out) | the DMA-10/11/13/14 counterexamples are reproduced with real timing by `tb/dma/tb_dma_probe.sv` and `sw/chip/t_chip_dma_rearm.c` |
| FD-3 | `dma.toml` | APB master (AMBA APB, PREADY tied 1): setup is followed by exactly one access with the same address, direction and write data; after an access comes idle or a new setup; PSEL low in reset | the APB protocol; GARUDA's only APB master is the AHB2APB bridge | the bridge is Track A block 6A.3 (its own proof is planned there); every DMA bench drives APB by this protocol |
| FD-4 | `dma.toml`, `dma_2clk.toml` | AHB-Lite slave: HREADY may be low in any cycle (wait states, or a lost arbitration holding M3's address phase); HRESP is OKAY unless a data phase is pending; ERROR is the two-cycle response; HREADY high and HRESP OKAY in reset; HRDATA free | the AHB-Lite slave protocol (IHI 0033A) as GARUDA's interconnect and slaves produce it | `tb/ahb/ahb_lite_checker.v` on M3 in `tb_dma_top` and on every master and slave port in `tb_chip`: 0 violations in every run |
| FD-5 | `dma.toml` (PDR task), `dma_2clk.toml` (PDR task) | x bits after `techmap` become free values (`setundef -anyseq`) | the AIGER export for abc pdr refuses x constants; they come from the 3-bit channel index reading the 6-channel vectors at channels 6 and 7 (`dma_engine.v:70-72`, and the same pattern in `dma_sva.sv`). A free value there only adds behaviours (sound for proofs); `a_state_legal` and the arbiter proof show the channel index never exceeds 5 | simulation never selects channel 6 or 7 (the arbiter grants 0..5) |
| FD-6 | `dma_2clk.toml` | two clocks from the environment's time base: hclk toggles every tick; pclk = hclk/2 and every pclk rising edge is an hclk rising edge (D-5) | the CRG's divider (`rtl/clk_div`) makes pclk this way; D-5 is the design rule that removed all CDC logic | `clk_div_sva` `a_pclk_subset_hclk` in every chip run |
| FD-7 | `dma_2clk.toml` | the time base is a `(* gclk *)` wire that behaves as a free clock: one tick takes at least two formal steps and the solver may pause it | measured 2026-10-12 (a cover on the tick counter); pausing all clocks together (stuttering) adds no behaviour a safety property can see. PDR does not depend on the step count; bounded depths are set for 4 steps per hclk cycle | — (a formal-tool property, not a design assumption) |
| FD-8 | `dma_2clk.toml` | as FD-1, in environment ticks | as FD-1 | as FD-1 |
| FD-9 | `dma_2clk.toml` | APB inputs change only right after a pclk edge; AHB slave inputs only right after an hclk edge; protocols as FD-3 and FD-4 | registered masters and slaves on those clocks | as FD-3, FD-4 |

`dma_req_i` is free in every harness: the DMA's own rules must hold for any request
pattern, including ones that break the peripheral contract D-21.

## White-box signals

The properties read three internal signals through the bind (hierarchical names,
accepted by Verilator and yosys-slang): the engine state `u_eng.st`, its channel
`u_eng.ch`, and the six request-taken flags `g_ch[n].u_ch.taken_q`. Every property
that uses one says so in `rtl/dma/dma_sva.sv`.

## Property selection

Each task picks its properties with `chformal` in its `script` (no ifdefs in
`dma_sva.sv`): the proof tasks leave out the open-bug detectors (DMA-10, DMA-11,
DMA-13, DMA-14, including `a_write_data`, which fails through DMA-14 and DMA-13) and
the pclk-timing properties; each `*_find` task and each negative control keeps only
the properties it is about, so a FAIL cannot come from another property.
