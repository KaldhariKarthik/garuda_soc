# tb/chip_uvm: the UVM bench of the whole chip (1-TOPS G6 6.1, decision D-42)

The core runs the chip programs of `sw/chip` from the pins (tb_chip: refclk, ext_rst_n,
boot flash, JTAG, the board's I2C slave), and every peripheral's own UVM environment
checks its block inside the chip on that real traffic.

    make -f flow/mk/track_b.mk uvm_chip          (or: tb/chip_uvm/sweep.sh)
    tb/chip_uvm/run_chip_uvm.sh <name> <mode> <hex> [max_us] [blocks]   one program
    PLANT=<name> tb/chip_uvm/run_chip_uvm.sh ...                        one planted defect

Results: `sim/chip_uvm/summary.txt`, one log per program in `sim/chip_uvm/<name>/irun.log`,
coverage in `sim/chip_uvm/cov_work` (scope `chip_uvm`, one test per program).

## What is checked

| Environment | Block(s) in the chip | APB | Pins and sidebands |
|---|---|---|---|
| uart0..2 | `u_core.g_uart[n].u_uart` | passive | line agent on the pads: monitors tx, **drives rx** (echoes every frame back, the UVM form of tb_chip's wire loopback); line format follows the firmware's LCR/DLL/DLM |
| gpio | `u_core.u_gpio` | passive | pads, output enables; the pad agent may drive the pads |
| pwm | `u_core.u_pwm` | passive | the four pins, measured |
| i2c | `u_core.u_i2c` | passive | the board's bus (pull-ups, slave model at 0x48); the agent's own slave stays silent; ACK/NACK and read data from the wire |
| spis | `u_core.g_spis.u_spis` | passive | **the master agent is the board's companion**: on each rising edge of gpio1 it sends A5 3C at 5 MHz (tb_chip's `spi_master_model` is left out under `GARUDA_CHIP_UVM`) |
| timers | `u_soc.u_timers` | passive | mtip, watchdog warn and reset request, the chip's resets |
| clic | `u_soc.u_clic` | passive | the chip's 32 sources in, valid/id/level out |
| dma | `u_soc.u_dma` | passive | its AHB master port on the chip fabric, the six request/ack pairs, complete/error |
| crg | `u_core.u_clk_div`, `u_core.u_reset_ctrl` | passive | refclk, the divided clocks, every reset, the request sources |

Each environment's monitors, reference model, scoreboard and coverage are the block
runs' own, unchanged. The only edits to the block environments: the register model is
connected to a sequencer only when the APB agent is active, and its root name is unique
when several environments share a run. Agents that stand in for the chip in a block run
(the CLIC's source driver, the DMA's AHB slave and request driver, the CRG's pin driver)
start no sequence here, and their signals are forced to the chip's own nets.

A run passes when the program reports success (tohost = 1 and no AHB checker violation,
tb_chip's verdict), no scoreboard has a mismatch, and there is no UVM error.

`+BLOCKS=a,b,...` names the environments a program uses (`uart` = all three). For the
others, only "the scoreboard compared nothing" is reported as a note: every other check
stays on, so an unused block must still sit idle at its reset values.

## Negative controls (`plants.txt`)

Each planted defect is one the firmware cannot see: the program still reports success,
and the run must fail on the named scoreboard check.

| Plant | Defect | Program | Must fire |
|---|---|---|---|
| pwm | the four PWM pins stuck low | cov | `sb_pin` |
| spis_miso | MISO stuck high while the companion is selected | cov | `sb_miso` |
| uart_dma | UART2's DMA request stuck high (no channel uses it) | uart | `sb_dma` |

## Files

- `tb_chip_uvm.sv`: the top: tb_chip (with `GARUDA_CHIP_UVM`), the environments'
  interfaces tapped onto the blocks, the plants
- `chip_uvm_pkg.sv`: `chip_env` (the eleven environments, the UART format follower and
  echo, the SPI companion), `chip_base_test`
- `chip_ctl_if.sv`: the program's verdict, and gpio1, from tb_chip
- `filelist_chip_uvm.f`, `run_chip_uvm.sh`, `sweep.sh`, `programs.txt`, `plants.txt`
