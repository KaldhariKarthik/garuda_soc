# GARUDA SoC

RV32IM SoC with embedded DSU (3× MAC) for autonomous drone swarm collision
avoidance via the Artificial Potential Field algorithm.

## Project structure

- `rtl/`     — Verilog-2001 synthesizable RTL, one subdirectory per block.
- `tb/`      — SystemVerilog testbenches, mirroring the `rtl/` block layout.
- `tools/`   — Reference models (Python), generators, compliance test integration.
- `scripts/` — Build scripts, file lists.
- `sim/`     — Simulation working directory (gitignored).
- `docs/`    — Design documents.

## Blocks

| # | Directory      | Description                                  |
|---|----------------|----------------------------------------------|
| 1 | `core/`        | RV32IM CPU core (5-stage in-order pipeline)  |
| 2 | `dsu/`         | Domain-Specific Unit (3× MAC, Custom-0 ISA)  |
| 3 | `isram/`       | Instruction SRAM (64 KB)                     |
| 4 | `dsram/`       | Data SRAM (64 KB, 4 banks)                   |
| 5 | `brom/`        | Boot ROM (4 KB)                              |
| 6 | `ahb/`         | AHB-Lite bus bar                             |
| 7 | `apb/`         | APB peripheral bus                           |
| 8 | `ahb2apb/`     | AHB-to-APB bridge with CDC                   |
| 9 | `dma/`         | 6-channel DMA controller                     |
|10 | `spi_master/`  | SPI master (IMU)                             |
|11 | `spi_slave/`   | SPI slave (ESP-NOW / external accelerator)   |
|12 | `i2c/`         | I2C controller (baro + mag)                  |
|13 | `uart/`        | UART (×3: SONAR, GPS, LoRa)                  |
|14 | `pwm/`         | PWM generator (4 motor channels)             |
|15 | `gpio/`        | GPIO controller                              |
|16 | `clic/`        | Core-local interrupt controller              |
|17 | `plic/`        | Platform-level interrupt controller          |
|18-21 | `timers/`   | System / watchdog / PWM / GP timers          |
|22 | `clk_div/`     | Clock divider                                |
|23 | `reset_ctrl/`  | Reset controller                             |
|24 | `debug/`       | RISC-V Debug Module 0.13                     |

## Tools

- **RTL language:** Verilog-2001
- **Testbench language:** SystemVerilog
- **Simulator:** Cadence Xcelium
- **Synthesis:** Cadence Genus (planned, July)
- **PnR:** Cadence Innovus (planned, Aug–Oct)
- **Process node:** 28 nm
- **Target frequency:** 200 MHz (100 MHz fallback)

## Tapeout target

December 1, 2026.
