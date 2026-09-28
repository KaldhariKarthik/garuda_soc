# GARUDA on KV260 — FPGA prototype

Unmodified `garuda_chip_top` on the K26 PL. The A53 running stock Kria
Ubuntu 22.04 acts as the "board": it drives GARUDA's JTAG pins, reset and
boot_sel, and reads uart0. This is the same development loop as `tb_chip
+MODE=jtag` (DEBUG-SPEC §7.6): Boot ROM recovery → SBA load → mailbox →
resume → `tohost`.

```
 A53 Linux ─ HPM0_FPD ─ SmartConnect ─┬─ AXI GPIO  0xA000_0000  ch1 ctrl ─▶ TCK/TMS/TDI, ext_rst_n, boot_sel, uart0 loopback
 (garuda_host.py, /dev/mem)           │                          ch2 stat ◀─ TDO, locked, heartbeat, pwm, pads
                                      └─ UartLite  0xA001_0000  ◀──▶ GARUDA uart0 (console mode)
 pl_clk0 100 MHz ─ MMCM ─ 50 MHz ─┬─ BUFGCE_DIV/1 ─ hclk 50 MHz ─ BUFGCE ─ core gclk
                                  └─ BUFGCE_DIV/2 ─ pclk 25 MHz
 PMOD J2: i2c_scl/sda (PULLUP), gpio0/1 (PULLDOWN), pwm0..3
```

## FPGA-only deviations (flagged, none of them touch the ASIC flow)

| ID | What | Why |
|---|---|---|
| FD-1 | `rtl/fpga/clk_div_fpga.v` replaces `clk_div.v`. refclk = MMCM output at the hclk rate, `aon_clk = hclk` | The ripple-toggle divider is fabric-generated clocking and can't be timed on an FPGA |
| FD-2 | DIVSEL is echoed (`div_act = div_sel`, `busy = 0`) and the frequency never changes | Same reason |
| FD-3 | `rtl/fpga/core_clk_gate_fpga.v` uses BUFGCE (`CE_TYPE SYNC`) instead of latch+AND | A LUT gated clock glitches. Fallback is `CORE_CLK_GATE=0` |
| FD-4 | hclk 50 MHz / pclk 25 MHz, not 250/125 | FPGA timing. `MMCM_MULT` / `MMCM_OUT_DIV` in `garuda_fpga_core` |
| FD-5 | UARTs, SPIM MISO←MOSI and SPIS idle are looped/tied in fabric (like tb_chip). Only I2C/GPIO/PWM reach pads | PMOD has 8 pins. I2C and GPIO need real pull resistors |
| FD-6 | `*_sva.sv` excluded | bind-only assertions |

Things that do NOT work here, by construction: flash boot (`t_chip_flash`,
no SPI flash wired), and step 4 of `t_chip_periph` (needs an I2C slave at
0x48 on J2.1/J2.2 — a TMP102 breakout works).

## 0. Laptop prerequisites
- Vivado (2022.1+, any edition that has the xck26 part), `python3`
- RISC-V gcc: the Vitis one (`riscv64-amd-linux-gnu-`, as in `sw/Makefile`),
  or `sudo apt install gcc-riscv64-unknown-elf`
- Serial: `sudo apt install picocom`. The KV260 micro-USB gives 4 ttyUSB ports
  and the Linux console is usually the second one.

## 1. Build firmware images
```
make -C sw fpga                                                     # Vitis toolchain paths
# or:  make -C sw fpga RISCV_BIN=/usr/bin RISCV_PREFIX=riscv64-unknown-elf-
```
Produces `sw/build/bootrom.hex` (baked into the bitstream), the `t_chip_*.hex`
set, and `t_fpga_hello.hex`.

## 2. (optional) Simulate the exact board flow — Verilator 5.x
```
fpga/sim/run_sim.sh core sw/build/t_chip_basic.hex               # SV copy of the host sequences
fpga/sim/run_sim.sh host run sw/build/t_chip_wdt.hex --wdt       # garuda_host.py itself, via FIFOs
```

## 3. Bitstream
```
source /tools/Xilinx/Vivado/<ver>/settings64.sh
vivado -mode batch -source fpga/kv260/build.tcl -tclargs 8
```
~15–25 min. Check the last lines: **WNS and WHS must both be ≥ 0**, or the
bitstream is not trustworthy. Outputs are in `fpga/kv260/out/`
(`garuda.bit.bin`, `timing.rpt`, `util.rpt`, `cdc.rpt`).

## 4. Copy to the Kria
Replace `<kria-ip>` with the board's address (`ip a` on the serial console):
```
scp -r fpga/kv260 ubuntu@<kria-ip>:~/garuda_kv260
ssh ubuntu@<kria-ip> mkdir -p garuda_kv260/images
scp sw/build/*.hex ubuntu@<kria-ip>:~/garuda_kv260/images/
```
With no network, a USB stick works too. The Kria needs only `out/garuda.bit.bin`,
`garuda.dtso`, `shell.json`, `install_on_kria.sh`, `host/` and the `.hex` images.

## 5. Load (on the Kria)
```
cd ~/garuda_kv260
sudo ./install_on_kria.sh          # dtc overlay, /lib/firmware/xilinx/garuda, xmutil loadapp
```
Expect `signature = 0x6a5d OK`, `mmcm lock = 1`, `heartbeat = toggling`.

## 6. Test (on the Kria)
```
sudo python3 host/garuda_host.py idcode                      # 0x00000DB1 = JTAG path alive
sudo python3 host/garuda_host.py run images/t_chip_jtag.hex
sudo python3 host/garuda_host.py run images/t_fpga_hello.hex --console
sudo python3 host/garuda_host.py suite --build images
```
Expected suite: jtag/basic/irq/uart/wdt **PASS**, periph **FAIL step 4**
(no I2C slave), hello **PASS** with the banner.

## Bring-up ladder (stop at the first rung that fails and debug that)
1. `stat`: signature wrong → bitstream not loaded (`xmutil listapps`). Locked=0
   → pl_clk0 not running (the overlay's `garuda_clk0`).
2. `idcode` ≠ 0xDB1 → JTAG/TCK path. Check `ext_rst_n` (ctrl bit 3), TCK BUFG, TDO.
3. `run t_chip_jtag` fails at "not halted" / readback → SBA / AHB / DSRAM.
4. Tests time out → the core never reached the program. The ROM recovery loop
   and mailbox are the suspects. Read `0x2000_FFF0` and RSTREASON over SBA.
