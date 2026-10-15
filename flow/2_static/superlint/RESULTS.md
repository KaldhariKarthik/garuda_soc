# Superlint on every block, first run (2026-10-15)

JasperGold 2022.09p002, `flow/2_static/superlint/superlint.tcl`, one run per top, `prove -all`.
Not a sign-off: nothing here is waived or fixed yet. "Dead code" is a statement the formal engine
proved can never execute; "overflow" is an arithmetic or assignment overflow it found reachable.

| Block (top) | Extracted | Dead code | Overflow | Where |
|---|---|---|---|---|
| CLIC (`clic_top`) | 135 | 0 | 0 | clean |
| Clock divider (`clk_div`) | 11 | 0 | 0 | clean |
| Reset controller (`reset_ctrl`) | 33 | 0 | 0 | clean |
| PWM (`garuda_pwm_top`) | 46 | 0 | 0 | clean |
| ISRAM (`isram_top`) | 27 | 0 | 0 | clean |
| DSRAM (`dsram_top`) | 43 | 0 | 0 | clean |
| Timers (`timers_top`) | 34 | 1 | 1 | `wdt.v:79`, `mtime.v:47` |
| GPIO (`garuda_gpio_top`) | 79 | 2 | 0 | vendored `apb_gpio.sv:284,547` |
| I2C (`garuda_i2c_top`) | 122 | 1 | 0 | vendored `i2c_master_bit_ctrl.sv` |
| UART (`garuda_uart_top`) | 144 | 6 | 2 | vendored `uart_rx/tx/interrupt.sv` |
| SPI slave (`garuda_spis_top`) | 46 | 0 | 1 | `garuda_spis_core.v:110` |
| SPI master (`garuda_spim_top`) | 228 | 2 | 6 | 2 properties undetermined (10%) |
| DMA (`dma_top`) | 189 | 1 | 2 | `dma_engine.v:168`, `dma_chan.v:115`, `dma_apb_slave.v:78` |
| Debug (`debug_top`) | 130 | 1 | 1 | `dtm.v:66`, `debug_module.v:123` |
| AHB interconnect (`ahb_interconnect`) | 77 | 2 | 0 | `ahb_default_slave.v:93`, `ahb_slave_mux.v:128` |
| AHB to APB bridge (`ahb2apb_bridge`) | 28 | 2 | 1 | `ahb2apb_bridge.v:168`, `ahb2apb_apb_fsm.v:53,105` |
| DSU (`dsu_top`) | 122 | 0 | 8 | `kogge_stone_49`, `barrel_shifter`, `mac_unit` |
| Boot ROM (`bootrom_top`) | 23 | 8 | 0 | the write-back path of the shared memory front end |

## What each class turned out to be (own RTL, 21 findings, read by hand)

| Class | Findings | Reading |
|---|---|---|
| Unreachable default branch of a state machine or `case` (illegal-state recovery) | `dma_engine:168`, `ahb_default_slave:93`, `ahb_slave_mux:128`, `ahb2apb_bridge:168`, `ahb2apb_apb_fsm:53` | by design, a standard waiver |
| Counter or accumulator that wraps on purpose | `mtime:47` (64-bit), `spis_core:110` (3-bit bit counter), `kogge_stone_49` (carry out dropped), `debug_module:123` (address auto-increment) | by design |
| Signed against unsigned assignment at a stated width in the DSU datapath | `barrel_shifter:43-45`, `mac_unit:166,201,204,245` | by design, the datapath is checked against its model |
| Shift that truncates | `dma_apb_slave:78` (channel 6 and 7 select nothing) | by design: PSLVERR for channel 6 is tested |
| Boot ROM write-back path | 8 in `bootrom_top` | by design: one front end shared with the RAMs, writes to a ROM are errors |
| **Reset modelled as assumed inactive after release** | `wdt.v:79` (`else if (!hreset_n_i)`) | **an artefact of the run**: the formal engine treats the reset pin as inactive once it has released, so "reset asserts again" is dead. Not a finding. |
| **Needs a counterexample trace before it is classed** | `dma_chan.v:115` (`rem_q - 1` can reach below 0: **confirmed, DMA-9**, JasperGold trace 2026-10-15), `ahb2apb_apb_fsm.v:105` (`to_cnt` reaches 32; the timeout is 16), `dtm.v:66` (DMI error status never set: **explained, DBG-5**, `rsp_err_i` tied 0 in `debug_top`) | open; may be unreachable in the chip because the block inputs are free here |

A finding is "reachable with the block's inputs free", which is not the same as reachable in the chip.
