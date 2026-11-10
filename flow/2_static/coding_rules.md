# RTL coding rules (1-TOPS G2 row 2.11)

Written 2026-11-10. Flow stage F4 (`flow/FLOW.md`).

The rule: synthesisable subset only, meaning no `initial` blocks, no delays, no latches and no
multiply driven nets in logic that is synthesised. Checked on every RTL file the chip
compiles (`rtl/soc/filelist_chip.f`), own and vendored, at commit d395563.

| Rule | How it was checked | Result |
|---|---|---|
| No `initial` blocks | text scan of `rtl/` | 5 found, none synthesised (below) |
| No delays | text scan of `rtl/`; HAL rule DLNBLK | 60, all in one vendored file, ignored by synthesis (below) |
| No latches | Genus `make synth` (`.is_latch` on the elaborated chip); Yosys `make local_synth`; HAL rule LATINF | 1: the clock-gate latch of the core, as intended (below) |
| No multiply driven nets | Genus `check_design -multiple_driver` (`flow/signoff/g3/out/multidriven.rpt`); HAL rule MULWIR | only the bidirectional pads (G3 row 3.16, `flow/signoff/g3/README.md`) |

Scans, run from the repository root in tcsh:

    grep -rnE '^\s*initial\b' rtl --include='*.v' --include='*.sv'
    grep -rlE '(<=|=)\s*#\s*[0-9]' rtl --include='*.v' --include='*.sv'
    source /home/install/cshrc
    make synth

## `initial` blocks (5)

| Where | What it is | Synthesised? |
|---|---|---|
| `rtl/mem/sram_wrapper.v:76` | `$readmemh` of the behavioural memory model | No: it is in the `else` branch of `ifdef GARUDA_SRAM_BLACKBOX`; synthesis uses the macro (G3 row 3.10 waits for the 28 nm macros) |
| `rtl/common/garuda_apb_shim.v:203` | Elaboration check of the IP_LIMIT parameter | No: inside `ifndef SYNTHESIS` |
| `rtl/dma/dma_props_a.sv:267` | Elaboration assertion on ACK_CYCLES | No: an assertion file, bound in, never synthesised |
| `rtl/clic/clic_sva.sv:145` | Elaboration check that the software-interrupt ID matches the system map | No: an assertion file |
| `rtl/ahb/ahb_mem_slave.v:88` | Memory clear of a bus memory model | No: the chip does not compile this file; it is used only by block benches |

## Delays (60)

All 60 are `<= #1` in `rtl/third_party/opencores/i2c/src/i2c_master_byte_ctrl.sv`, the
OpenCores I2C byte controller, as its author wrote it. Synthesis ignores them. Vendored
files are never edited (DECISIONS, decision of 2026-09-22: upstream files under
`rtl/third_party/` are taken as they are); HAL counts them as DLNBLK 60, explained in
`flow/2_static/hal_waivers.txt`. No own RTL file has a delay.

## Latches

Genus elaborates the whole chip (`make synth`, `scripts/run_genus.sh`, 2026-11-10: 74 699
cells, 7 999 flops) and lists every instance that is a latch in
`sim/genus_garuda_chip_top/latches.rpt`. It prints `GENUS_LATCHES 1`:

    u_core/u_soc_u_core_u_cg_en_l_reg

That is the enable latch of `rtl/core/core_clk_gate.v`, the behavioural integrated clock
gate (WFI clock gating). A latch there is required: it holds the enable stable while the
clock is high. The 28 nm library ICG cell replaces it in the physical flow. HAL reports the
same single latch (LATINF 1, `flow/2_static/hal_waivers.txt`).

Yosys, a second tool with its own front end, gives the same answer (`make local_synth`
after `source scripts/setup_open_tools.sh`, in bash: `Latches: 1 total, 0 unexpected`;
the gate fails on any latch other than this one).

During elaboration Genus also inferred latches for 14 unused bits in two vendored blocks
(`apb_uart.sv` lines 42 and 59, `apb_gpio.sv` line 72) and removed them, because nothing
reads them (message CDFG-508, "Removing unused register"). They are not in the netlist.

## Result

Every synthesised file follows the rule except where written above, and each exception is
either outside synthesis or vendored and explained.
