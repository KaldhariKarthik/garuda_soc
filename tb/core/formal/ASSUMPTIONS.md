# Formal assumption register: core (Docs/handbook/H6_formal.md)

A proof is only as good as the assumptions next to it. Every harness under
`tb/core/formal/` lists here what it assumes, why that is justified, and the
simulation check that backs it.

| ID | Harness | Assumption | Justification | Backed by (simulation) |
|---|---|---|---|---|
| FA-1 | all core harnesses (`core_fv_env.sv`) | `core_rst_n_i` and `hartreset_n_i` low for the first 4 cycles, then high for good | a reset sequence at power-up; mid-run resets are a separate property set (RDC-1, W4) | every tb_boot run starts this way |
| FA-2 | all core harnesses | clock gate = pass-through (`core_clk_gate_passthru.sv`, the design's `CLK_GATE == 0` build) | SBY single-clock mode cannot model the latch ICG; properties are sampled on the ungated clock every cycle, so no violation before the first sleep can be hidden | the regression runs with `CLK_GATE = 1` (gated); a counterexample after a sleep must be replayed in simulation |
| FA-3 | all core harnesses (`rtl/core/filelist_core.f`) | DSU = inert stub (`tb/stub/dsu_top_stub.v`): outputs tied to 0 | the DSU is proven separately (plan D4); H4 (`dsu_busy`) cells are therefore unreachable here | tb_boot runs the real DSU |
| FA-4 | all core harnesses | every bus response (HREADY, HRESP, HRDATA on both ports), instruction word and interrupt input is free | over-approximates any legal and illegal environment; a property that holds here holds for any slave | AHB-Lite checkers in every tb_boot run |

| FA-5 | `csr_file.toml` (`csr_file_fv_env.sv`) | `rst_n_i` low in the first cycle, then free (may reassert at any time); every other input free | csr_file is only ever used after a reset; without it the registers (and the property helper flops) start in states no reset reaches, which produced a false T-12 counterexample at step 1 (2026-10-11) | every simulation starts with a reset |

| FA-6 | `rdc1.toml` (`rdc1_top.sv`) | the bus/Debug-Module reset `rst_n` is low in the first cycle and high afterwards; the HART reset comes only from the Debug Module (free DMI requests) | RDC-1 is about hart resets on a live bus, so the bus must not be reset again; a bus reset resets slaves and masters together and breaks no transfer | tb_core_halt.sv (bus reset only at start, 60 halts per seed) |
| FA-7 | `rdc1.toml` | an ERROR response on either port is AHB-Lite's two-cycle response: HRESP=1 with HREADY=1 only right after HRESP=1 with HREADY=0, and the first cycle is always followed by the second | the AHB-Lite slave protocol; GARUDA's slaves and the interconnect produce nothing else | tb/ahb/ahb_lite_checker.v flags any other pattern in every simulation |

Harnesses: `rdc1.toml` uses FA-6 and FA-7 (and FA-2, FA-3 through the core filelist); every
property there is required only while no halt grant has been forced (haltinfo.haltforced = 0):
the forced grant is the documented, flagged fallback, exercised in simulation by
`t_core_hartreset_timeout`. `csr_file.toml` uses FA-5 only. `core_trap.toml` (trap_ctrl: T-13, T-14, TC-1, TC-3) uses FA-1..FA-4 and
nothing else.
