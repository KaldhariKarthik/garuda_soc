# Formal assumption register: AHB interconnect (Docs/handbook/H6_formal.md)

A proof is only as good as the assumptions next to it. Every harness under
`tb/ahb/formal/` lists here what it assumes, why that is justified, and the
simulation check that backs it. Written 2026-10-13 (Track A bus plan B1, phase A2).

## Harness

| Manifest | Environment | Clocking | Used for |
|---|---|---|---|
| `ahb.toml` | `ahb_fv_env.sv` (FA-1..FA-4), bound into `ahb_interconnect` | single clock (hclk) | every property of `rtl/ahb/ahb_interconnect_sva.sv`: PDR proof, bounded check, covers, the AHB-7 finder, 7 negative controls |

## Assumptions

| ID | Assumption | Justification | Backed by (simulation) |
|---|---|---|---|
| FA-1 | `hreset_n` low for the first 2 cycles, then high | power-up reset; reset in mid-run (vPlan F22, AHB.TA.t_ahb_reset_mid) is a simulation item | every AHB bench starts this way; t_ahb_reset_mid in the B1 env |
| FA-2 | Each master obeys AHB-Lite: no BUSY; IDLE in reset; a presented, unaccepted address phase is held unchanged until the master sees HREADY high, except that after the first cycle of an ERROR it may be dropped to IDLE; HSIZE <= word, aligned; HWDATA held while its own write data phase waits. M1/M2/M3: SINGLE, NONSEQ only. M0: word reads, SINGLE or INCR, a SEQ continues its own last accepted transfer at +4 | the AHB-Lite master rules (IHI 0033A) and the four GARUDA masters as specified ([N-5.3], [N-8.5]); the BUSY exclusion: no GARUDA master emits BUSY (ahb_arbiter.v header) | `ahb_lite_checker` on every master port in `tb_ahb_interconnect` and `tb_chip`: 0 violations; the I-port's BUS-B/BUS-C errata keep its SEQ legal |
| FA-3 | Each slave: HREADYOUT high and HRESP OKAY outside its own data phase; inside it any wait, OKAY, or the two-cycle ERROR; HRDATA free | AHB-Lite slave rules; GARUDA's slaves (memories, bridge, default slave) | `ahb_lite_checker` on the shared slave bus in every chip run; the default slave itself is inside the proof (not assumed) |
| FA-4 | (proof tasks only, `AHB_FV_CANCEL_ON_ERROR`) a master that saw ERROR with HREADY low in its own data phase last cycle presents IDLE now | this is exactly the condition under which **AHB-7** cannot occur; without it the solver finds AHB-7 (task `ahb7_find`, xfail). Not true of the real I-port (it holds its next fetch through an ERROR, BUS-C), which is why AHB-7 is logged; the effect on today's masters is analysed in `Docs/bugs/ahb.md` AHB-7 | when AHB-7 is fixed, FA-4 is removed and the proof must still close |

## Results (2026-10-13, Yosys 0.69 / SBY 0.69)

- `ahb_prove` (abc pdr): **PROVEN**, 56 asserts, 10 s.
- `ahb_bmc`: BOUNDED(24).
- `ahb_cover`: all 47 covers reached (the 15 request sets, held responses, captures per master, the ERROR then accept, the SEQ rewrite, cancel after ERROR).
- `ahb7_find`: FAIL (xfail AHB-7) at depth 6, master 0.
- **Negative controls, each failing only its named property:**
  - `mut_ahb1` → a_hwdata_data_phase;
  - `mut_ahb2` → a_rdata_value;
  - `mut_ahb3` → a_burst_restart_nonseq;
  - `mut_ahb4` → a_idle_not_gated / a_reset_state;
  - `mut_prio` → a_priority;
  - `mut_decode` → a_decode;
  - `mut_nofreeze` → a_grant_stable_in_data_phase.
