# Core lint report (1-TOPS G2 row 2.12)

Written 2026-11-10. Flow stage F4 (`flow/FLOW.md`).

The core is `rtl/core/` (32 files): `garuda_core_top` and the modules under it (fetch, decode,
execute, memory, writeback, CSR file, trap control, CLIC controller, clock gate). The lint is the
chip run of HAL (`make static_lint`, replay R3.1 in `flow/COMMANDS.md`), cut down to the
findings whose file is in `rtl/core/`. The core is not linted on its own: in the chip run
its clock, reset and bus ports are driven by the real reset controller and fabric, so
nothing is reported that only exists because the ports float.

Run: HAL 15.20, 2026-11-10, commit d395563, log `sim/replay/hal.log`. Count the core
findings in tcsh, from the repository root:

    grep -cE '^hal\w+: \*[EW],[A-Z0-9]+ \(\./rtl/core/' sim/replay/hal.log

Result: **108 findings, 1 error and 107 warnings, in 30 rules. None is a defect.** Every one
is in the chip baseline (`flow/2_static/hal_baseline.txt`, may not rise) and every rule has
a written reason in `flow/2_static/hal_waivers.txt`. The table repeats each reason against
the core lines it covers; each line was read on 2026-11-10.

## The error

| Rule | Where | Why it is accepted |
|---|---|---|
| GLTASR | `garuda_core_top.v:124`, `core_rst_n_i & hartreset_n_i` | CORE [N-7.33] requires the two resets to be combined inside the core. Both come from synchroniser flops on hclk in reset_ctrl. A glitch needs them to move in opposite directions in the same cycle; its only effect would be a short release while reset is being asserted. |

## The warnings

| Rule | n | Where | Why it is accepted |
|---|---|---|---|
| FFWNSR | 31 | `regfile.v:39`, x1 to x31 | The register file has no reset (CORE spec, table of units: `regfile` "no reset"). Software writes each register before reading it; the X-propagation run of F4 checks that no X reaches a register that matters. |
| TIELOG | 9 | `csr_file.v:266` mtvec_o[1:0]; `garuda_iport_ahb_master.v:89-92,109` HSIZE, HPROT, HWRITE, HWDATA, HBURST; `load_store_unit.v:32` hsize[2]; `mem_stage.v:140-141` HBURST, HPROT | Constant outputs by design: the fetch port always reads words, with HBURST fixed to INCR (comment in the file); the data port never uses HSIZE[2] (no 64-bit access) and drives HBURST SINGLE and a fixed HPROT; mtvec MODE is fixed to CLIC and BASE is word-aligned. |
| URDWIR | 8 | `csr_file.v:262,263,271` parts of mstatus_next, mintthresh_next, ctl_next; `garuda_core_top.v:156` ex_branch_mispredict; `:174` clic_take; `mul32.v:50` product[65:64] | The CSR update function returns 32 bits and only the implemented fields are stored. The mispredict and CLIC-take wires are outputs of ex_stage and trap_ctrl that the core top does not use (the redirect and the trap entry use other signals). The top two product bits are the sign extension of the 33x33 multiply; only [63:0] is used. |
| UNCONO | 7 | `ex_stage.v:236` branch_taken; `garuda_core_top.v:292` branch_mispredict, `:395` clic_take_o; `garuda_if_stage_top.v:72` pc_o, `:119` full_o; `id_stage.v:112` opcode_o; `mem_stage.v:114` ok_done_o | Outputs of shared sub-blocks that this instance does not need. Each was reviewed; none is a missing connection. |
| UNCONN | 5 | the same five instances (`ex_stage.v:236`, `garuda_if_stage_top.v:72,119`, `id_stage.v:112`, `mem_stage.v:114`) | The same open outputs, reported a second time by the instance rule. |
| DFDRVS | 5 | `garuda_pc_gen.v:40,41` pc_o, fetch_pc_o; `garuda_prefetch_buffer.v:48` fifo_instr; `id_ex.v:68`, `if_id.v:27` instr_o | The reset value has both 0 and 1 bits (the reset vector `0x1000_0000`; the NOP `0x0000_0013`), so some bits are reset flops and some are set flops. Intended. |
| LOGAND | 5 | `garuda_iport_ahb_master.v:248,250,254`; `trap_ctrl.v:190,191` | `&` between 1-bit signals in a condition: the same as `&&`. |
| LOGORP | 4 | `branch_unit.v:105,115`; `ex_stage.v:308`; `trap_ctrl.v:154` | `|` between 1-bit signals in a condition: the same as `||`. |
| UELOPR | 4 | `garuda_prefetch_buffer.v:90,94,97,98` | Pointer and occupancy counters stepped by `1'b1`. The pointers wrap on purpose (4-entry FIFO, 2-bit pointers). Occupancy is 3 bits and cannot pass 4, because the fetch master only issues while there is room (`room_for_new_fetch`, `garuda_iport_ahb_master.v:189`). |
| AMSKWD | 3 | `branch_unit.v:48`, `ex_stage.v:96` "branch"; `csr_file.v:231` "access" | Verilog-AMS keywords used as names. AMS is not used anywhere in the flow. |
| POOBID | 3 | `regfile.v:39,43,44` | The array is `mem[1:31]`. A write to x0 is blocked by `wb_rd_i != 0`; a read of x0 returns 0 before the array is indexed. |
| CDEFCV | 2 | `decode_control.v:196,234` | funct3 is 3 bits and all 8 values are listed, so the default (illegal instruction) cannot be reached. It is kept so a later edit of the list cannot leave a value undecoded. |
| CONSBS | 2 | `load_store_unit.v:50,51` | The byte and halfword shift amounts `* 8` and `* 16` are written without a base. |
| IPUFSE | 2 | `mul32.v:47,48` | The 33-bit signed operands of the multiplier are built from unsigned registers on purpose (MUL, MULH, MULHSU, MULHU share one multiplier). Checked by the ISA multiply tests in Spike lockstep. |
| MXUANS | 2 | `alu.v:36,37` SRA, SLT | Signed and unsigned are mixed on purpose; checked by the ISA tests. |
| ULCMPE | 2 | `garuda_prefetch_buffer.v:56,57` | A 3-bit occupancy compared with the integer FIFO_DEPTH (4) and with 0. The values fit; no padding error. |
| BOUINC | 1 | `regfile.v:34` | The array starts at 1: x0 is not stored and reads as 0 by construction. |
| CLKGNP | 1 | `core_clk_gate.v:21` | The clock gate module has an enable latch next to the gate. It is replaced by the library ICG cell in the physical flow. |
| CLKINP, GTDCLK, RSTINP | 1 each | `garuda_core_top.v:203`, flop i_dph_q | The core flops run on the gated clock gclk from core_clk_gate (WFI clock gating, CORE spec). |
| IMPDTC | 1 | `alu.v:36` | `$signed(op_a) >>> shamt` stored in an unsigned result: the arithmetic shift is what SRA needs. |
| LATBAS, LATINF, LENCPI | 1 each | `core_clk_gate.v:45,46` | The behavioural ICG latch, the only latch in the chip (`flow/2_static/coding_rules.md`). |
| LMULOP | 1 | `mul32.v:50` | The 33x33 multiply gives a 66-bit product by design. |
| NAUTOF | 1 | `csr_file.v:240` function nextv | A function without `automatic`: it is not recursive and is not called again while running, so it synthesises the same. |
| RSTGNP | 1 | `garuda_core_top.v:34` | The two core resets are combined in the core top, as CORE [N-7.33] requires (see GLTASR). |
| ULRELE | 1 | `garuda_iport_ahb_master.v:189` | The 4-bit projected occupancy compared with FIFO_DEPTH (4): the value fits. |

## Superlint on the core

The chip Superlint run of 2026-11-10 (one hour per check group, TOOL-A11) reports 24 core
findings, all intended: 4 dead `default:` branches (`alu.v:40`, `csr_file.v:246`,
`decode_control.v:216`, `d_port_ahb_master.v:140`) and 20 overflows (address and ALU
arithmetic modulo 2^32, the 64-bit counters, shifts, and same-width sign changes in the ALU
and multiplier). The list and each reason are in `flow/2_static/superlint/chip/RESULTS.md`,
under "Core". No index in the core can leave its array (out-of-bound indexing: all proven).

## What this does not cover

- The core is linted only in the chip. A core-only HAL run was not made; it would also
  report findings that exist only because the core's ports are left free.
- Coding rules (no delays, no initial blocks, no latches, no multiple drivers) are in
  `flow/2_static/coding_rules.md` (row 2.11).
