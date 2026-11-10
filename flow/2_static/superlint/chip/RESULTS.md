# Superlint on the whole chip (1-TOPS item 3.14)

JasperGold 2022.09p002, Superlint app, `flow/2_static/superlint/superlint.tcl` with
`TOP=garuda_chip_top`, `FL=rtl/soc/filelist_chip.f`, `CLK=refclk`, `RST=ext_rst_n`, and the
proof time limit `SL_TIME` at its default of 3600 s. Run on 2026-11-10 on commit d395563,
from 10:00 to 12:04.

Run from the repository root in tcsh (it takes about two hours):

    source /home/install/cshrc
    setenv TOP garuda_chip_top
    setenv FL rtl/soc/filelist_chip.f
    setenv CLK refclk
    setenv RST ext_rst_n
    setenv OUT sim/superlint/chip
    /home/install/JASPER/bin/jg -allow_unsupported_OS -superlint -batch -no_jges -proj sim/superlint/chip_proj flow/2_static/superlint/superlint.tcl

The tool's reports are in this folder: `superlint_report.txt` (summary) and
`superlint_violations.txt` (every finding with its file, line and instance).

## Why this run replaces the one of 2026-11-03 (TOOL-A11)

The run of 2026-11-03 used a proof limit of 300 s on a busy machine. Most formal checks never
finished, and it reported 36 findings and no overflow at all. That result depended on
machine load, not on the design (`Docs/bugs/track_a.md`, TOOL-A11). The limit is now an hour.
JasperGold applies it to each of the five check groups separately, so a full run takes about
two hours.

## Result

**77 findings: 5 floating bus, 38 dead code, 34 overflow. All 77 were read by hand on
2026-11-10. None is a design error and none needs an RTL change.**

What the proof engine decided, per check group:

| Group | Checks | Decided | Left undetermined after an hour |
|---|---|---|---|
| Floating bus | 6 | all (6 counterexamples, grouped into 5 findings) | 0 |
| Case (unique and parallel) | 3 | all proven | 0 |
| Out-of-bound indexing | 23 | all proven: no index can leave its array | 0 |
| Overflow | 127 | 65 proven, 48 counterexamples (grouped into 34 findings) | **14** |
| Dead code | 1817 statements | 1094 reached, 130 unreachable (grouped into 38 findings) | **609** |

What "undetermined" means here:

- **14 overflow checks.** For these, the engine neither proved that no overflow can happen
  nor found one. Every overflow it did find is intended (below), and the arithmetic of the
  core and the DSU is checked by simulation: the ISA tests in Spike lockstep (F6) and the DSU
  reference model.
- **609 dead-code statements.** For these, the engine neither reached the statement nor
  proved it unreachable, so the 38 dead-code findings are the statements proven dead, not a
  full list. A statement that is really dead also shows up in F8 as a code-coverage hole,
  and JasperGold UNR decides it there before any waiver. Reading the 609 here would repeat
  that work.

Karthik accepted both on 2026-11-10 (`Docs/DECISIONS.md`, D-33).

## Floating bus (5)

`tdo`, `i2c_scl`, `i2c_sda`, `gpio0/1` and `spis_miso` float whenever their output enable is 0.
Each is a tristate or bidirectional pin by design:
- JTAG TDO is tristate per IEEE 1149.1;
- I2C is open-drain, with pull-ups on the board (PHYS [N-3.3]);
- the GPIO pins are bidirectional;
- the SPI slave's MISO is released when the slave is not selected.

The PDK's pad cells (input, output and enable as separate pins) replace this model.

## Dead code, own RTL (21)

A statement the formal engine proved can never execute, with the chip's real inputs and parameters.

| Class | Findings | Why it cannot execute |
|---|---|---|
| Recovery branch of a state machine or `case` | `ahb2apb_bridge.v:172`, `ahb_default_slave.v:93`, `ahb_slave_mux.v:128`, `d_port_ahb_master.v:140`, `dma_engine.v:203`, `alu.v:40`, `csr_file.v:246`, `decode_control.v:216` | The `default:` of a `case` whose listed items cover every value that can occur. For `csr_file.v:246` (the `default` of the CSR-operation function `nextv`): a CSR is written only when the operation is not 0 (`access`, `csr_file.v:231`), so in the calls whose result is stored the default is never taken. Kept so that an illegal state or encoding returns to a safe one, which is standard practice. (`dma_engine.v` and `csr_file.v` moved down by the rulings D-32; on 2026-11-03 they were lines 168 and 238.) |
| ROM instance of the memory interface | `ahb_mem_slave_if.v:161`, `:173`, `:174`, `:175`, `:183`, `:184`, `:185`, `:186`, all in `u_brom.u_if` | The boot ROM uses the shared SRAM interface with `WRITABLE=0`, so every write gets ERROR and the write buffer is never filled. Its fill, its port select and its read bypass are therefore dead in this one instance; in ISRAM and DSRAM they are live. New in this run because the 300 s run never finished these checks. |
| Parameter value | `ahb2apb_apb_fsm.v:53`, `:89` | `APB_DIV` gives every window a divider of 0 and there are 12 windows, so neither the extra-wait countdown nor a window index of 12 or more is ever used. Both exist for a slow peripheral the chip does not have. |
| Tie-off | `clic_select.v:35`, `:41` | ID 0 and the IDs with no source are masked out of the candidates (`GARUDA_CLIC_ID_MASK`), so their leaf and one inner node of the selection tree never win. |
| Open finding | `dtm.v:66` | `rsp_err_i` is tied 0 in `debug_top`, so `dmistat = 2` cannot occur. This is the open entry **DBG-5** (spec text, P3) in `Docs/bugs/track_a.md`. |

The run of 2026-11-03 also reported `dma_chan.v:140` (`taken_q <= 1`, now line 157). This run
does not: it is among the statements left undetermined or reached. The reading of
2026-11-03 still stands. In the chip, every peripheral's APB shim drops its request on the
acknowledge (`rtl/common/garuda_apb_shim.v`, DECISIONS D-21), so the flag is a second
safeguard.

## Dead code, vendored IP (17)

The same 17 as on 2026-11-03.

| IP | Findings | Why |
|---|---|---|
| PULP SPI master (`axi_spi_master`) | `spi_master_controller.sv:221,533`, `spi_master_rx.sv:50,82`, `spi_master_tx.sv:42,54,85` | Quad and dual SPI paths: GARUDA uses single-bit SPI, and quad mode is never selected (SPIM spec). `:221` is in the `MODE` state, open entry SPIM-2. |
| PULP SPI master (`apb_spi_master`) | `apb_spi_master.sv:201` | `default:` of the transmit-side state machine. |
| PULP UART (`apb_uart_sv`) | `uart_rx.sv:182`, `uart_tx.sv:150` | `default:` of the receive and transmit state machines. |
| PULP UART | `uart_rx.sv:206,220`, `uart_tx.sv:179` | The "disabled" branches: `apb_uart.sv` ties `cfg_en_i` to 1. |
| PULP UART | `uart_interrupt.sv:76` | The character-timeout interrupt: `apb_uart.sv` ties `CTI_i` to 0. |
| PULP GPIO (`apb_gpio`) | `apb_gpio.sv:284,547` | The registers of pins 32 to 63 (`REG_PADDIR_32_63` and the read-back of bits above 31). GARUDA uses 2 pins. |
| OpenCores I2C | `i2c_master_bit_ctrl.sv:247` | The filter counter's reset when the core is disabled: `rtl/i2c/garuda_i2c_top.v:302` ties `ena` to 1. |

Vendored files are not edited (`Docs/THIRD_PARTY_NOTICES.md`).

## Overflow (34)

A counterexample means the engine found inputs for which the result does not fit its
destination. Every one below wraps on purpose.

| Class | Findings | Why it is intended |
|---|---|---|
| 32-bit address and ALU arithmetic, modulo 2^32 as RV32I defines it | `alu.v:29` ADD, `:30` SUB; `branch_predict.v:41,42,54`; `branch_unit.v:95,96` (branch and jump targets), `:97` (JALR target, expression rule); `ex_stage.v:307` (link = pc + 4); `garuda_pc_gen.v:55,58` (pc + 4) | The ISA defines these additions modulo 2^32: a target past 0xFFFF_FFFC wraps, and ADD and SUB ignore the carry. |
| 64-bit counters | `csr_file.v:150,285,287,290,292` (mcycle, minstret and the architectural instret); `timers/mtime.v:47` (mtime) | They wrap at 2^64 as the privileged spec says; at 250 MHz that is after more than 2000 years. |
| Shifts | `alu.v:34` SLL; `dsu/barrel_shifter.v:44` | A left shift drops the bits shifted out; that is what SLL and the DSU shift do. |
| Same width, sign changed | `alu.v:36` SRA; `mul32.v:47,48` (33-bit signed operands); `dsu/barrel_shifter.v:43,45`; `dsu/mac_unit.v:167,202,205,247` | The engine counts a signed value stored into an unsigned one of the same width (or the reverse) as an overflow. The bits are kept unchanged, which is what each line wants. |
| DSU adder | `dsu/kogge_stone_49.v:10` | The 49-bit adder of the MAC. Bit 48 is the guard bit: an overflow is detected by `result_ext[48] ^ result_ext[47]` and saturated by the saturation unit. |
| DMA channel select | `dma/dma_apb_slave.v:78`, `6'd1 << ch` | A channel number of 6 or 7 shifts the 1 out of the 6 bits. Those numbers are excluded before the select is used (`chan_rgn`: `ch < 3'd6`). |
| Vendored UART bit counter | `uart_rx.sv:136`, `uart_tx.sv:115` | The 3-bit bit counter can only wrap if software changes the character length in the middle of a frame; the frame is then wrong, as it would be on any UART. New in this run. |
| Vendored SPI receive counter | `apb_spi_master.sv:153,230`, `s_cnt_rx-1` | With a receive count of 0 the subtraction wraps, the compare never matches, and the count interrupt does not fire: the right behaviour for a count of 0. New in this run. |

## Core

The core's findings, for G2 row 2.12 (`flow/2_static/core_lint.md`):
- dead code: `alu.v:40`, `csr_file.v:246`, `decode_control.v:216`, `d_port_ahb_master.v:140`;
- overflow: `alu.v:29,30,34,36`, `branch_predict.v:41,42,54`, `branch_unit.v:95,96,97`,
  `csr_file.v:150,285,287,290,292`, `ex_stage.v:307`, `garuda_pc_gen.v:55,58`,
  `mul32.v:47,48`.

Each has its reason in the tables above.

## Closing

- Structural lint (HAL): 0 errors left without a waiver.
- Superlint: 77 findings, each with its reason above. The undetermined checks are stated in
  the Result section, with where they are covered.

Row 3.14 of the 1-TOPS workbook is closed again with this file as its evidence (TOOL-A11).
