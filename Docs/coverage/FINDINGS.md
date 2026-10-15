# Coverage findings, block by block

Written by `tools/gen/cov_findings.py` from the IMC reports of `make cov_chart` (the merged directed runs, the chip programs and the UVM environments). The figures per block are in `Docs/coverage/COVERAGE_BY_BLOCK.md`; this file lists **what was never hit**, which is what the next tests have to aim at. A hole is not a defect: it is a combination the tests did not produce.

## Summary

| Block | Code: block | Expression | Toggle | Functional | Uncovered bins |
|---|---|---|---|---|---|
| RV32IM core | 97.6% | 94.3% | 84.6% | 90.7% | 111 |
| DSU | 100.0% | - | 95.6% | 60.0% | 128 |
| AHB interconnect | 98.6% | 100.0% | 69.1% | 71.8% | 40 |
| AHB to APB bridge | 93.0% | 81.8% | 78.3% | 38.4% | 85 |
| Memories | 85.7% | 95.7% | 92.8% | 77.2% | 13 |
| DMA | 99.1% | 97.8% | 60.3% | 75.8% | 39 |
| Debug | 96.5% | 88.6% | 77.1% | 90.0% | 8 |
| CLIC | 100.0% | - | 96.0% (100.0% after waivers) | 100.0% | 0 |
| Timers and watchdog | 100.0% | 100.0% | 93.8% (100.0% after waivers) | 100.0% | 0 |
| Clock divider and reset | 100.0% | 100.0% | 82.2% (100.0% after waivers) | 100.0% | 0 |
| PWM | 98.0% (100.0% after waivers) | 96.0% (100.0% after waivers) | 92.9% (100.0% after waivers) | 100.0% | 0 |
| GPIO | 58.4% (100.0% after waivers) | 93.5% (100.0% after waivers) | 55.5% (100.0% after waivers) | 100.0% | 0 |
| UART | 83.1% | 84.1% | 66.7% | 98.1% | 4 |
| I2C | 97.7% (100.0% after waivers) | 88.2% (100.0% after waivers) | 91.2% (100.0% after waivers) | 100.0% | 0 |
| SPI master | 67.3% | 52.8% | 54.5% | 39.1% | 42 |
| SPI slave | 97.8% (100.0% after waivers) | 94.7% (100.0% after waivers) | 85.2% (100.0% after waivers) | 100.0% | 0 |
| APB shim (six peripherals) | 93.5% | 92.3% | 99.0% | 90.5% | 4 |
| Chip and SoC top (wiring) | - | - | 56.0% | 86.2% | 8 |

## RV32IM core

**`cg_decode`** (59 of 83 bins), from `sim/cov_all/cg_core_holes.txt`

- `x_op_f3`: 24 uncovered: `jalr,auto[1]`, `jalr,auto[2]`, `jalr,auto[3]`, `jalr,auto[4]`, `jalr,auto[5]`, `jalr,auto[6]`, `jalr,auto[7]`, `branch,auto[2]`, `branch,auto[3]`, `load,auto[3]` ...

**`cg_ldst`** (34 of 41 bins), from `sim/cov_all/cg_core_holes.txt`

- `x_size_off`: 7 uncovered: `h,auto[1]`, `h,auto[3]`, `w,auto[1]`, `w,auto[2]`, `w,auto[3]`, `hu,auto[1]`, `hu,auto[3]`

**`cg_hazard`** (30 of 31 bins), from `sim/cov_all/cg_core_holes.txt`

- `x_fwd_under_stall`: 1 uncovered: `exmem,auto[1]`

**`cg_trap`** (9 of 10 bins), from `sim/cov_all/cg_core_holes.txt`

- `cp_cause`: 1 uncovered: `instr_fault`

**`cg_ahb`** (26 of 27 bins), from `sim/cov_all/cg_core_holes.txt`

- `cp_i_err`: 1 uncovered: `auto[1]`

**`cg_dsu`** (28 of 47 bins), from `sim/cov_all/cg_core_holes.txt`

- `cp_f5`: 4 uncovered: `macsub`, `macabs`, `macdot`, `macshift`
- `x_op_acc`: 15 uncovered: `macsub,fx`, `macsub,fy`, `macsub,mag`, `macabs,fx`, `macabs,fy`, `macabs,mag`, `macdot,fx`, `macdot,fy`, `macdot,mag`, `macsat,mag` ...

**`cg_csr`** (66 of 115 bins), from `sim/cov_all/cg_holes_garuda_core_cov_ext.txt`

- `cp_csr`: 2 uncovered: `auto[MIP]`, `auto[UNIMPL]`
- `cp_illegal`: 1 uncovered: `auto[1]`
- `x_csr_op`: 26 uncovered: `auto[MISA],rw`, `auto[MISA],rc`, `auto[MTVEC],rc`, `auto[MEPC],rc`, `auto[MCAUSE],rc`, `auto[MTVAL],rc`, `auto[MIP],rw`, `auto[MIP],rs`, `auto[MIP],rc`, `auto[MNXTI],rw` ...
- `x_csr_illegal`: 20 uncovered: `auto[MSTATUS],auto[1]`, `auto[MISA],auto[1]`, `auto[MIE],auto[1]`, `auto[MTVEC],auto[1]`, `auto[MSCRATCH],auto[1]`, `auto[MEPC],auto[1]`, `auto[MCAUSE],auto[1]`, `auto[MTVAL],auto[1]`, `auto[MIP],auto[0]`, `auto[MIP],auto[1]` ...

**`cg_irq`** (20 of 26 bins), from `sim/cov_all/cg_holes_garuda_core_cov_ext.txt`

- `cp_nesting`: 1 uncovered: `nested`
- `cp_threshold`: 1 uncovered: `set`
- `x_level_nesting`: 4 uncovered: `lowest,nested`, `low,nested`, `high,nested`, `top,nested`

**`cg_sleep`** (4 of 7 bins), from `sim/cov_all/cg_holes_garuda_core_cov_ext.txt`

- `cp_len`: 1 uncovered: `one`
- `cp_woken_by`: 2 uncovered: `both`, `other`


## DSU

**`cg_instr`** (185 of 309 bins), from `sim/cov_all/cg_holes_dsu_cov.txt`

- `x_arith_operands`: 122 uncovered: `auto[MAC],auto[ZERO],auto[ZERO]`, `auto[MAC],auto[ZERO],auto[ONE]`, `auto[MAC],auto[ZERO],auto[MINUS_ONE]`, `auto[MAC],auto[ZERO],auto[NEG]`, `auto[MAC],auto[ZERO],auto[MAX_POS]`, `auto[MAC],auto[ZERO],auto[MIN_NEG]`, `auto[MAC],auto[ONE],auto[ZERO]`, `auto[MAC],auto[ONE],auto[ONE]`, `auto[MAC],auto[ONE],auto[MINUS_ONE]`, `auto[MAC],auto[ONE],auto[POS]` ...
- `x_op_accstate`: 1 uncovered: `auto[MACSUB],above_32bit`
- `x_shift`: 1 uncovered: `zero,auto[1]`

**`cg_events`** (7 of 11 bins), from `sim/cov_all/cg_holes_dsu_cov.txt`

- `cp_flush_busy`: 3 uncovered: `flush_while_busy`, `flush_idle`, `busy`
- `cp_back_to_back`: 1 uncovered: `auto[1]`


## AHB interconnect

**`cg_addr`** (60 of 92 bins), from `sim/cov_all/cg_holes_ahb_interconnect_cov.txt`

- `cp_contenders`: 1 uncovered: `four`
- `x_master_slave_dir`: 18 uncovered: `iport,rom,read`, `iport,dsram,read`, `iport,bridge,read`, `iport,undecoded,read`, `dport,isram,write`, `dport,bridge,write`, `sba,rom,read`, `sba,rom,write`, `sba,bridge,read`, `sba,bridge,write` ...
- `x_master_contended`: 7 uncovered: `iport,three`, `iport,four`, `dport,three`, `dport,four`, `sba,three`, `sba,four`, `dma,four`
- `x_master_split`: 2 uncovered: `dport,split_to_nonseq`, `sba,split_to_nonseq`
- `x_master_size`: 4 uncovered: `sba,byte_`, `sba,half`, `dma,byte_`, `dma,half`

**`cg_resp`** (42 of 50 bins), from `sim/cov_all/cg_holes_ahb_interconnect_cov.txt`

- `cp_waits`: 1 uncovered: `many`
- `x_master_resp`: 1 uncovered: `dma,error`
- `x_master_waits`: 4 uncovered: `iport,many`, `dport,many`, `sba,many`, `dma,many`
- `x_slave_resp`: 2 uncovered: `rom,error`, `bridge,error`


## AHB to APB bridge

**`cg_access`** (53 of 138 bins), from `sim/cov_all/cg_holes_ahb2apb_bridge_cov.txt`

- `cp_window`: 5 uncovered: `w[4]`, `w[6]`, `w[7]`, `w[8]`, `w[10]`
- `cp_size`: 1 uncovered: `wider`
- `cp_divider`: 2 uncovered: `div4`, `div8`
- `cp_slave_waits`: 2 uncovered: `one`, `many`
- `cp_in_reset`: 1 uncovered: `during_apb_reset`
- `x_win_dir_ok`: 14 uncovered: `w[2],read,ok`, `w[2],write,ok`, `w[3],read,ok`, `w[3],write,ok`, `w[4],read,ok`, `w[4],write,ok`, `w[6],read,ok`, `w[6],write,ok`, `w[7],read,ok`, `w[7],write,ok` ...
- `x_err_dir`: 3 uncovered: `absent,write`, `slave_error,write`, `timeout,write`
- `x_div_waits`: 13 uncovered: `none,one`, `none,many`, `div2,one`, `div2,few`, `div2,many`, `div4,none`, `div4,one`, `div4,few`, `div4,many`, `div8,none` ...
- `x_arrival_outcome`: 7 uncovered: `after_idle,absent`, `back_to_back,absent`, `back_to_back,subword`, `back_to_back,slave_error`, `back_to_back,timeout`, `after_error,slave_error`, `after_error,timeout`
- `x_size_window`: 37 uncovered: `byte_,w[1]`, `byte_,w[2]`, `byte_,w[3]`, `byte_,w[4]`, `byte_,w[6]`, `byte_,w[7]`, `byte_,w[8]`, `byte_,w[9]`, `byte_,w[10]`, `byte_,w[11]` ...


## Memories

**`cg_access`** (44 of 57 bins), from `sim/cov_all/cg_holes_mem_cov.txt`

- `cp_size`: 1 uncovered: `wider`
- `x_dir_size_lane`: 8 uncovered: `read,half,auto[1]`, `read,half,auto[3]`, `read,word,auto[2]`, `read,word,auto[3]`, `write,half,auto[3]`, `write,word,auto[1]`, `write,word,auto[2]`, `write,word,auto[3]`
- `x_read_wbuf`: 2 uncovered: `read,other_word,after_write`, `read,same_word,after_write`
- `x_dir_outcome`: 2 uncovered: `read,auto[LOCKED]`, `read,auto[DEBUG_BYPASS]`


## DMA

**`cg_beat`** (97 of 134 bins), from `sim/cov_all/cg_holes_dma_cov.txt`

- `cp_contenders`: 1 uncovered: `more`
- `x_channel_mode`: 5 uncovered: `c[0],m2p`, `c[1],m2p`, `c[2],m2p`, `c[4],m2p`, `c[5],m2p`
- `x_channel_outcome`: 10 uncovered: `c[0],auto[ERR_BUS_READ]`, `c[0],auto[ERR_BUS_WRITE]`, `c[1],auto[ERR_BUS_READ]`, `c[1],auto[ERR_BUS_WRITE]`, `c[2],auto[ERR_BUS_READ]`, `c[2],auto[ERR_BUS_WRITE]`, `c[4],auto[ERR_BUS_READ]`, `c[4],auto[ERR_BUS_WRITE]`, `c[5],auto[ERR_BUS_READ]`, `c[5],auto[ERR_BUS_WRITE]`
- `x_size_lanes`: 10 uncovered: `byte_,auto[0],auto[2]`, `byte_,auto[0],auto[3]`, `byte_,auto[1],auto[0]`, `byte_,auto[1],auto[3]`, `byte_,auto[2],auto[0]`, `byte_,auto[2],auto[1]`, `byte_,auto[3],auto[1]`, `byte_,auto[3],auto[2]`, `half,auto[0],auto[2]`, `half,auto[2],auto[0]`
- `x_inc`: 4 uncovered: `auto[0],auto[1],m2p`, `auto[1],auto[0],p2m`, `auto[1],auto[0],m2m`, `auto[1],auto[1],m2p`
- `x_channel_contended`: 7 uncovered: `c[0],more`, `c[1],more`, `c[2],more`, `c[3],more`, `c[4],more`, `c[5],two`, `c[5],more`

**`cg_ctrl`** (25 of 27 bins), from `sim/cov_all/cg_holes_dma_cov.txt`

- `x_reg_active`: 1 uncovered: `cnt,auto[1]`
- `x_en_in_beat`: 1 uncovered: `auto[1],inside_own_beat,auto[0]`


## Debug

**`cg_dmi`** (47 of 55 bins), from `sim/cov_all/cg_holes_debug_cov.txt`

- `x_reg_op`: 1 uncovered: `abstractcs,write`
- `x_sba_reg_state`: 7 uncovered: `sbcs,read,inactive,idle`, `sbcs,write,inactive,idle`, `sbcs,write,active,busy`, `sbaddress0,read,inactive,idle`, `sbaddress0,read,active,busy`, `sbaddress0,write,inactive,idle`, `sbdata0,read,inactive,idle`


## CLIC

No covergroup report found (files: `sim/uvm_clic/func_holes.txt`).

## Timers and watchdog

No covergroup report found (files: `sim/uvm_timers/func_holes.txt`).

## Clock divider and reset

No covergroup report found (files: `sim/uvm_crg/func_holes.txt`).

## PWM

No covergroup report found (files: `sim/uvm_pwm/func_holes.txt`).

## GPIO

No covergroup report found (files: `sim/uvm_gpio/func_holes.txt`).

## UART

**`cg_uart_fifo`** (9 of 11 bins), from `sim/uvm_uart/func_holes.txt`

- `cp_tx_level`: 1 uncovered: `empty`
- `cp_rx_level`: 1 uncovered: `empty`

**`cg_uart_err`** (12 of 13 bins), from `sim/uvm_uart/func_holes.txt`

- `cp_kind`: 1 uncovered: `both`

**`cg_uart_dma`** (5 of 6 bins), from `sim/uvm_uart/func_holes.txt`

- `x_dir_level`: 1 uncovered: `transmit_with_the_fifo_nearly_full`


## I2C

No covergroup report found (files: `sim/uvm_i2c/func_holes.txt`).

## SPI master

**`cg_start`** (19 of 56 bins), from `sim/cov_all/cg_holes_spim_cov.txt`

- `cp_device`: 1 uncovered: `none`
- `cp_dir`: 2 uncovered: `write`, `both`
- `cp_div`: 2 uncovered: `slower`, `much_slower`
- `cp_cmd`: 1 uncovered: `none`
- `cp_addr`: 1 uncovered: `a32`
- `cp_data`: 1 uncovered: `none`
- `cp_dma`: 2 uncovered: `tx`, `both`
- `x_device_dir`: 6 uncovered: `flash,write`, `flash,both`, `imu,write`, `imu,both`, `both,write`, `both,both`
- `x_flash_read`: 21 uncovered: `none,none,none`, `none,none,word`, `none,none,multi`, `none,none,short`, `none,a24,none`, `none,a24,word`, `none,a24,multi`, `none,a24,short`, `none,a32,none`, `none,a32,word` ...

**`cg_fw`** (6 of 8 bins), from `sim/cov_all/cg_holes_spim_cov.txt`

- `cp_quad_bits`: 1 uncovered: `both`
- `cp_soft_reset`: 1 uncovered: `auto[1]`

**`cg_dma`** (2 of 5 bins), from `sim/cov_all/cg_holes_spim_cov.txt`

- `cp_req_at_ack`: 1 uncovered: `auto[1]`
- `cp_mode`: 2 uncovered: `tx`, `both`


## SPI slave

No covergroup report found (files: `sim/uvm_spis/func_holes.txt`).

## APB shim (six peripherals)

**`cg_access`** (23 of 25 bins), from `sim/cov_all/cg_holes_garuda_apb_shim_cov.txt`

- `x_target_dir`: 1 uncovered: `hole,auto[1]`
- `x_tail_dir`: 1 uncovered: `id,auto[1]`

**`cg_dma`** (5 of 7 bins), from `sim/cov_all/cg_holes_garuda_apb_shim_cov.txt`

- `cp_mode`: 1 uncovered: `both`
- `cp_holdoff`: 1 uncovered: `auto[1]`


## Chip and SoC top (wiring)

**`cg_dma`** (7 of 8 bins), from `sim/cov_all/cg_holes_chip_cov.txt`

- `cp_req_still_high`: 1 uncovered: `auto[1]`

**`cg_reset`** (3 of 5 bins), from `sim/cov_all/cg_holes_chip_cov.txt`

- `cp_cause`: 2 uncovered: `ndm`, `sw`

**`cg_misc`** (17 of 22 bins), from `sim/cov_all/cg_holes_chip_cov.txt`

- `cp_ratio`: 3 uncovered: `div4`, `div8`, `div16`
- `cp_ratio_change`: 1 uncovered: `auto[1]`
- `cp_gpio_out`: 1 uncovered: `auto[2]`

