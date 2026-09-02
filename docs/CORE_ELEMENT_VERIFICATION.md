# Core element-level verification

Per-element testbenches for Block I (`U_CORE`), written against
**AERO-GARUDA-DS-001 Rev 1.1** (`Design_Docs/Core/GARUDA_Core_Design_Doc.docx`)
and the RTL in `rtl/core/`.

> **STATUS: NOT YET RUN.** These testbenches were authored on a machine with no
> simulator available and have never been compiled or simulated. Treat every
> result claim here as *intended* behaviour, not measured. What HAS been checked
> statically: block/`begin`-`end`/`case`/`task`/`function` balance, that every
> macro used resolves in `garuda_defs.vh` / `core_ex_defs.vh`, and that all 15
> DUT instantiations connect exactly the ports their RTL module declares — no
> extras, none left unconnected. Expect first-run fixes anyway, most likely in
> `tb_garuda_iport_ahb_master` and `tb_garuda_if_stage_top`, whose checks are
> the most cycle-timing dependent.
>
> `test_elements` is deliberately kept OUT of `make test_core` until it reports
> clean, so the existing regression flow is unaffected.
>
> These are Verilog-2001 (`.v`), matching the `tb_pipe_ctrl.v` / `tb_trap_ctrl.v`
> smoke style — not the SystemVerilog (`.sv`) style of the `tb_top` unit TBs.
> No SV randomisation is used, so they run 32-bit under `xrun` without the
> `-64bit` flag the `tb_top` set requires.

Run them all:

```bash
source scripts/setup_env.sh
make test_elements          # the 14 element TBs
make test_core              # everything: smokes + unit TBs + elements
```

Or one at a time — `make test_alu`, `make test_dport`, and so on (table below).

Each testbench is self-checking and prints one result line:

```
<NAME> UNIT: ALL CHECKS PASSED
<NAME> UNIT: <n> FAILURE(S)
```

which is what the Makefile's existing `grep -ihE "FAIL|PASSED|ERROR"` picks up.
Plain Verilog-2001, no SV randomisation, so these run 32-bit under `xrun`
without the `-64bit` flag the `tb_top` unit TBs need.

---

## Coverage of the block diagram

Before this set, 12 of the 30 modules in `rtl/core/` had a dedicated
testbench. These add 14 more; `ex_stage` and `id_ex`/`if_id`/`ex_mem` are
covered by the existing smokes, and `regfile`/`decode_control`/`imm_gen`/
`branch_predict`/`hazard_forward_unit`/`id_stage` by the `tb_top` set.

| Element | Spec § | TB | `make` target | Directed tests (§18.2) |
|---|---|---|---|---|
| `garuda_pc_gen` | 6.2, 2.1, 17 | `tb_garuda_pc_gen.v` | `test_pc_gen` | C28, C14 |
| `garuda_prefetch_buffer` | 6.3, 6.5 | `tb_garuda_prefetch_buffer.v` | `test_prefetch` | C14, C15 |
| `garuda_iport_ahb_master` | 6.4, 6.5, 16 | `tb_garuda_iport_ahb_master.v` | `test_iport` | C12, C13, C14, C15 |
| `garuda_if_stage_top` | 6, 16 | `tb_garuda_if_stage_top.v` | `test_if_stage` | C13, C14, C15 |
| `alu` | 8.1 | `tb_alu.v` | `test_alu` | C01, C05 |
| `mul32` | 8.2 | `tb_mul32.v` | `test_mul32` | C02 |
| `branch_unit` | 12.2, 12.3 | `tb_branch_unit.v` | `test_branch_unit` | C06–C09 |
| `csr_rw` | 8.3, 8.4, 13.3 | `tb_csr_rw.v` | `test_csr_rw` | C21 |
| `load_store_unit` | 10.1, 10.2 | `tb_load_store_unit.v` | `test_lsu` | C10, C11 |
| `load_formatter` | 10.3 | `tb_load_formatter.v` | `test_load_fmt` | C10 |
| `d_port_ahb_master` | 10.4, 16.1–16.3 | `tb_d_port_ahb_master.v` | `test_dport` | C12 |
| `mem_stage` | 10, 11.4, 13.2, 14.1/14.2 | `tb_mem_stage.v` | `test_mem_stage` | C10, C11, C12 |
| `mem_wb_reg` + `wb_stage` | 5.2, 10.3, 11.4, 13.2 | `tb_mem_wb_reg.v` | `test_memwb` | C28 |
| `clic_ctrl` | 14.3, 14.5 | `tb_clic_ctrl.v` | `test_clic_ctrl` | C23, C24, C26 |

`wb_stage` has no TB of its own on purpose: it is three `assign`s with no
state (Sec. 5 calls it a structural boundary), so `tb_mem_wb_reg` instantiates
it downstream of the register and reads every check through it. That also
verifies the MEM/WB → WB → register-file-write-port wiring order, which a
standalone TB for three wires would not.

---

## The checks that exist because of a known bug

Several of these testbenches are regression tests for errata already recorded
in the RTL headers. Those are the checks worth reading first, because a
testbench that only proves "something came out" would pass the broken version.

**ERRATUM I-1** (`garuda_iport_ahb_master`) — the master used to complete a
transfer in its *address* phase, pairing every instruction with the previous
bus cycle's read data while keeping its own correct PC tag. `tb_garuda_iport_ahb_master`
runs a stream through a memory model whose word at address A is a unique
function of A, and checks the `(data_pc_o, data_instr_o)` **pair** on every
delivery. `tb_garuda_if_stage_top` re-checks the same property at the stage
output, plus strict `+4` ordering from the last redirect target.

**ERRATUM D-1** (`d_port_ahb_master`) — same root cause on the data side: every
store wrote zero and every load returned stale data. Three named checks in
`tb_d_port_ahb_master` target it:
`store_hwdata_held_after_start_falls` (drops `start_i`/`hwdata_i` the moment
the address phase is accepted, exactly as the pipeline does, and requires
`d_hwdata_o` to still present the captured value),
`ok_done_is_a_data_phase_event`, and
`stall_released_only_on_completion`.

**ERRATUM T-1** (`branch_unit`) — instruction-address-misaligned (cause 0) is
raised off JAL and off a *taken* branch, not off `redirect`. JAL redirects from
ID and never asserts `redirect`, so `tb_branch_unit` checks the JAL case
explicitly (`jal_misaligned` + `jal_no_ex_redirect`) — that is the
`rv32mi/ma_fetch` case a redirect-hung check misses.

**Erratum 6.3-E1** (EX result mux priority) — `csr_rdata` is the highest-priority
input. That priority lives in `ex_stage` and is covered by `tb_ex_smoke`;
`tb_csr_rw` covers the seam feeding it.

---

## Checks aimed at named coverage gaps

`docs/COVERAGE.md` Category C lists specific holes. These TBs target them
directly, so re-measure after running them:

- `garuda_pc_gen` (75.94%, "redirect-source priority combinations") →
  `redir_over_commit`, `redir_over_issue`, `redir_over_both`, back-to-back
  redirects.
- `garuda_if_stage_top` (58.36%, "buffer full, redirect with 2 fetches in
  flight, back-to-back redirects") → one section each.
- The wide-bus toggle shortfall the same doc describes is attacked here by
  driving complementary patterns (`0000_0000` / `FFFF_FFFF` / `8081_8283` /
  `AAAA_5555`) and full-range addresses through the datapath elements, rather
  than the small constants ordinary test programs use.

---

## Discriminating vectors worth knowing about

These are the specific stimuli chosen so a plausible wrong implementation
cannot pass:

| Check | Why this vector |
|---|---|
| `alu` shift-by-32/33/`FFFF_FFE1` | shift amount is `op_b[4:0]` only; a full-width shifter returns 0 and would pass a naive directed test |
| `alu` SLT vs SLTU on (`FFFF_FFFF`, 1) | separates signed from unsigned compare |
| `mul32` `mulhsu_pn` = (2, `FFFF_FFFF`) | MULHSU is the only asymmetric case; a transposed `a_signed`/`b_signed` is correct for MUL/MULH/MULHU and wrong only here |
| `branch_unit` `jalr_lsb_masked` | odd JALR sum must be *masked*, not trapped; bit 1 still raises misaligned |
| `csr_rw` `imm_wdata_uimm31_zeroext` | uimm `5'b11111` → 31, not `FFFF_FFFF`; also proves the uimm/rs1 field alias picked the right source |
| `load_formatter` data `8081_8283` | every byte and every halfword is negative, so a lane-mux error and a sign-extension error cannot cancel |
| `clic_ctrl` `lvl_eq_thresh` / `lvl_eq_active` | Sec. 14.3 requires **strictly** greater-than on both compares; a `>=` implementation fails only these two (test C24) |
| `mem_stage` load and store ERROR at the *same* address | a swapped `mem_read`/`mem_write` cause split cannot pass both |
| `mem_wb_reg` retire-pulse counting | a flush that killed the write but not the retire tag would silently inflate `minstret` |

---

## Scope boundaries

- **Misalignment causes 4 and 6 are EX's**, not MEM's. `mem_stage` deliberately
  raises no exception on a misaligned access — it only gates the transaction
  off the bus. `tb_mem_stage` asserts that absence (`misaligned_lw_no_mem_exc`)
  rather than treating it as a hole.
- **Pushing the prefetch buffer past full is out of contract.** The RTL does
  not guard the write at `occupancy == 4`; the I-port master owns that
  invariant through its `room_for_new_fetch` reservation, so overflow is
  checked in `tb_garuda_iport_ahb_master` (a continuous occupancy assertion),
  not by abusing the FIFO in isolation.
- **C13 ("a flushed faulting word does not trap")** cannot be fully decided at
  IF-stage level, because "does it trap" is only observable once the entry
  reaches ID. `tb_garuda_if_stage_top` hard-checks the half it can see — that
  nothing from the pre-redirect stream is ever issued — and *reports* whether
  the faulting word had already been popped. The authoritative test stays
  `sw/tests/t_flush.S` through `tb_boot`.
- **Bubble counts** (1 bubble for load-use, 2 for a mispredict) are `pipe_ctrl`
  and core-level properties, already covered by `tb_pipe_ctrl`. `tb_branch_unit`
  verifies the redirect request and target that drive them, not the count.

---

## Fixed along the way

`tb/core/filelist_clic_ctrl.f` listed `tb_clic_ctrl.v` with a trailing
`# (add later; clic has no tb yet — lint only for now)` comment. `#` is not a
comment in a Cadence/Vivado filelist, and the testbench did not exist. Both
are now correct: the file exists and the filelist uses `//`.
