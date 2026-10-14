# H7. Core environment and co-simulation

Lands with plan E1 (RVFI), E2 (core environment) and E3 (Spike co-simulation);
each starts with an approved design note (DN-RVFI, DN-ENV-CORE, DN-COSIM).

Decided already:
- RVFI port on the core under `GARUDA_RVFI` (Verilog-2001), records emitted at WB.
- Plain-SV environment in `tb/core/env/` with AHB slave agents (I-port, D-port),
  CLIC, timer, debug (halt-by-reset per ADR-0012), reset agents; RVFI monitor
  feeding the co-simulation scoreboard and coverage.
- Spike as a library through DPI (`tools/cosim/`, C++), stepped per retired
  instruction; interrupts, bus errors and halt-by-reset injected by the harness;
  GARUDA Spike extension for DSU custom-0 and the GARUDA CSRs.
- Reference-model qualification before use: independent DSU golden vectors, the
  CLIC take-decision model reviewed by Karthik, explicit event-timing tests, and
  negative controls (corrupted rd, store, mcause; missed and late interrupt) that
  must each mismatch.
