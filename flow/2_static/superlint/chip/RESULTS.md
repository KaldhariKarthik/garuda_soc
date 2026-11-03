# Superlint on the whole chip (1-TOPS item 3.14)

JasperGold 2022.09p002, Superlint app, `flow/2_static/superlint/superlint.tcl` with `TOP=garuda_chip_top`, `FL=rtl/soc/filelist_chip.f`, `CLK=refclk`, `RST=ext_rst_n`. Run on 2026-11-03 on tree `a5c06a1`.

Run from the repository root in tcsh:

    source /home/install/cshrc
    setenv TOP garuda_chip_top
    setenv FL rtl/soc/filelist_chip.f
    setenv CLK refclk
    setenv RST ext_rst_n
    setenv OUT sim/superlint/chip
    /home/install/JASPER/bin/jg -allow_unsupported_OS -superlint -batch -no_jges -proj sim/superlint/chip_proj flow/2_static/superlint/superlint.tcl

The tool's reports are in this folder: `superlint_report.txt` (summary) and `superlint_violations.txt` (every finding with its file and line).

The structural lint of the chip is HAL (`make static_lint`): 5 errors, each waived with a reason in `flow/2_static/hal_waivers.txt`, and the warning counts held by `flow/2_static/hal_baseline.txt`. Superlint adds formal checks, which find two classes: 5 floating buses and 31 dead-code statements. **All 36 were read by hand and explained. None is a design error and none needs an RTL change.**

## Floating bus (5)

`tdo`, `i2c_scl`, `i2c_sda`, `gpio0/1` and `spis_miso` float whenever their output enable is 0. Each is a tristate or bidirectional pin by design:
- JTAG TDO is tristate per IEEE 1149.1;
- I2C is open-drain, with pull-ups on the board (PHYS [N-3.3]);
- the GPIO pins are bidirectional;
- the SPI slave's MISO is released when the slave is not selected.

The PDK's pad cells (input, output and enable as separate pins) replace this model.

## Dead code, own RTL (14)

A statement the formal engine proved can never execute, with the chip's real inputs and parameters.

| Class | Findings | Why it cannot execute |
|---|---|---|
| Recovery branch of a state machine or `case` | `ahb2apb_bridge.v:172`, `ahb_default_slave.v:93`, `ahb_slave_mux.v:128`, `d_port_ahb_master.v:140`, `dma_engine.v:168`, `alu.v:40`, `csr_file.v:238`, `decode_control.v:216` | The `default:` of a fully enumerated `case`. Kept so that an illegal state or encoding returns to a safe one; that is the standard practice. |
| Parameter value | `ahb2apb_apb_fsm.v:53`, `:89` | `APB_DIV` gives every window a divider of 0 and there are 12 windows, so neither the extra-wait countdown nor a window index of 12 or more is ever used. Both exist for a slow peripheral the chip does not have. |
| Tie-off | `clic_select.v:35`, `:41` | ID 0 and the IDs with no source are masked out of the candidates (`GARUDA_CLIC_ID_MASK`), so their leaf and one inner node of the selection tree never win. |
| Behaviour of the attached peripherals | `dma_chan.v:140` | `taken_q <= 1` needs the request still high in the cycle the beat completes. In the chip it never is. `dma_engine.v` (state `E_WD`) raises `beat_done` and the acknowledge on the same edge, and every peripheral's APB shim drops its request combinationally while the acknowledge is high, then holds it low for one more pclk (`rtl/common/garuda_apb_shim.v:166-167`, DECISIONS D-21). So "one beat per request" is enforced by the shim in the chip, and the channel's own flag is a second safeguard for a peripheral that does not drop its request on the acknowledge. It is reachable in the DMA block bench, which has such a peripheral, and not in this chip. Not a defect; read 2026-11-03. |
| Open finding | `dtm.v:66` | `rsp_err_i` is tied 0 in `debug_top`, so `dmistat = 2` cannot occur. This is the open entry **DBG-5** (spec text, P3) in `Docs/bugs/track_a.md`. |

## Dead code, vendored IP (17)

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

## Result

- Structural lint (HAL): 0 errors left without a waiver.
- Superlint: 36 findings, each with its reason above.

Row 3.14 of the 1-TOPS workbook is closed with this file as its evidence.
