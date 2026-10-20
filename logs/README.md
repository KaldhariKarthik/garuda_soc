# logs/: verification results, one folder per block

Every block has `summary/`, `evidence/`, `history.tsv` (in git) and `raw/` (not in git).
Every log file starts with a header (date, tool + version, design SHA + dirty flag,
seed, command, reproduce line) and ends with a footer (exit code, counts, verdict).
Verdicts: PASS, FAIL, BLOCKED; classified OK, XFAIL:<bug>, XBLOCK:<bug>, XPASS:<bug>,
UNEXPECTED. Full rules: [`Docs/handbook/H2_running.md`](../Docs/handbook/H2_running.md).

| Folder | Block | Owner |
|---|---|---|
| [`core/`](core/) | RV32IM core (rtl/core) | Track A (Sreyesh) |
| [`dsu/`](dsu/) | DSU coprocessor (rtl/dsu) | Track A (Sreyesh) |
| [`ahb/`](ahb/) | AHB-Lite interconnect (rtl/ahb) | Track A (Sreyesh) |
| [`ahb2apb/`](ahb2apb/) | AHB-to-APB bridge (rtl/ahb2apb) | Track A (Sreyesh) |
| [`dma/`](dma/) | DMA controller (rtl/dma) | Track A (Sreyesh) |
| [`debug/`](debug/) | Debug module + JTAG (rtl/debug) | Track A (Sreyesh) |
| [`mem/`](mem/) | Memories, boot ROM, ISRAM lock (rtl/mem, brom, isram, dsram) | Track A (Sreyesh) |
| [`clic/`](clic/) | CLIC (rtl/clic) | Track B (Karthik) |
| [`uart/`](uart/) | UART x3 (rtl/uart) | Track B (Karthik) |
| [`i2c/`](i2c/) | I2C (rtl/i2c) | Track B (Karthik) |
| [`spi_master/`](spi_master/) | SPI master (rtl/spi_master) | Track B (Karthik) |
| [`spi_slave/`](spi_slave/) | SPI slave (rtl/spi_slave) | Track B (Karthik) |
| [`gpio/`](gpio/) | GPIO (rtl/gpio) | Track B (Karthik) |
| [`pwm/`](pwm/) | PWM (rtl/pwm) | Track B (Karthik) |
| [`timers/`](timers/) | Timers + watchdog (rtl/timers) | Track B (Karthik) |
| [`clkrst/`](clkrst/) | Clock divider + reset controller (rtl/clk_div, rtl/reset_ctrl) | Track B (Karthik) |
| [`soc/`](soc/) | Chip integration (rtl/soc) | Track B (Karthik) |
| [`flow/`](flow/) | Runner self-tests, oracle negative controls, tool checks | shared (Track A drafts, both review) |
