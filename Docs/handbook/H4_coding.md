# H4. Coding standards

## RTL fixes
- Verilog-2001 house style of the block being changed; no new language features in RTL.
- Every fix carries `// ERRATUM <ID>: <one line>` at the changed lines (checked by `bugs check`).
- New debug or verification-only ports sit under a define (e.g. `GARUDA_RVFI`) and
  must not change the netlist when the define is off.

## Verification code
- SystemVerilog. C++ only for the Spike glue in `tools/cosim/`; Python/bash only
  for flow glue (runners, generators, report scripts).
- Plain SV with UVM-shaped layering (agent, driver, monitor, scoreboard, coverage,
  config object); no UVM library, so it runs on Verilator and Xcelium alike.
- No pasted copies of the DUT inside a testbench: benches compile the real RTL.
- Every `randomize()` result is checked; a failed randomize is an error.
- A bench prints exactly one verdict line and decides it by control flow, never by
  an earlier `$finish` (H2).
- Seeds come from the runner (`+verilator+seed+N`, `+SEED=N`); nothing is seeded by wall-clock time.

## Assertions
- Portable subset that Verilator, SBY (yosys-slang) and Xcelium/Jasper all read
  (measured 2026-10-12 with the pinned oss-cad-suite, Yosys 0.69+190):
  - yosys-slang **rejects `|->` and `|=>`** ("unsupported SVA feature"). Write
    `A |-> B` as the boolean `!(A) || (B)`, and `A |=> B` as `!$past(A) || (B)`,
    gated by a "past is valid" flop that is 0 in reset and 1 one edge after it.
  - Accepted: `$past`, `$rose`, `$fell`, `$stable`, `$onehot0`, `inside`, functions
    with loops, `bind` with hierarchical references (including generate scopes).
  - Not for SBY: `##n` / `##[m:n]` sequences, `throughout`, `intersect`. Use helper
    flops or shift registers instead.
  - Not for Verilator 5.052: a variable part-select inside `$past()` (TOOL-24). Put
    the indexed value in a wire and take `$past` of the wire.
  (Until 2026-10-12 this line listed `|->` and `|=>` as portable; the core and DSU
  property files already avoided them.)
- Every important assert has a `cover` on its antecedent, so a property that never
  triggers is visible (VACUOUS is a finding, H6).
- `disable iff` must not be relied on asynchronously (Verilator deviation, H2).
- Properties live in `rtl/<blk>/<blk>_sva.sv` (bound) or `tb/<blk>/formal/`; each names its vPlan row.
