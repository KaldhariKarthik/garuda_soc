# 1-TOPS gate G0: tools, environment and flow

Evidence for items 0.1 to 0.4 of the 1-TOPS signoff workbook. Each tool runs one small case, `hello.sv`: a flop, plus a bench that checks it. Each tool's output is in `out/`.

Run on 2026-11-03 on cadence-ws (Rocky 8.10).

Every command below is typed in tcsh from the repository root, one line at a time. Before the first command, set the licence. The lab's file sets `LM_LICENSE_FILE` and `CDS_LIC_FILE`; the server address is kept out of this public repository:

    source /home/install/cshrc
    mkdir -p sim/g0

## 0.1 Front-end tools

| Tool (1-TOPS list) | GARUDA uses | Command | Result (`out/`) |
|---|---|---|---|
| VCS | Xcelium 22.09 | `/home/install/XCELIUM2209/tools/bin/xrun -sv flow/signoff/g0/hello.sv -top tb_hello -xmlibdirname sim/g0/xcelium.d -l flow/signoff/g0/out/xrun.txt` | `xrun.txt`: HELLO PASS |
| VCS (coverage flow) | irun 15.2 | `set path = (/home/install/INCISIVE152/tools/bin $path)`, then `irun -sv flow/signoff/g0/hello.sv -top tb_hello -nclibdirname sim/g0/INCA_libs -l flow/signoff/g0/out/irun.txt` | `irun.txt`: HELLO PASS |
| Verdi | SimVision 22.09 | `/home/install/XCELIUM2209/tools/bin/simvision -64bit -version` | `simvision.txt`: simvision(64) 22.09-s003 |
| SpyGlass lint | HAL 15.2 | `irun -hal -sv flow/signoff/g0/hello.sv -top hello -define SYNTHESIS -nclibdirname sim/g0/INCA_hal -l flow/signoff/g0/out/hal.txt` | `hal.txt`: 0 errors, 0 warnings |
| SpyGlass lint and CDC | JasperGold 2022.09 | `/home/install/JASPER/bin/jg -allow_unsupported_OS -fpv -batch -no_jges -proj sim/g0/jg flow/signoff/g0/hello_jg.tcl` | `jaspergold.txt`: licence `jasper_papp`, 1 property proven |
| DC / Fusion Compiler | Genus 21.1 | `/home/install/GENUS211/bin/genus -batch -no_gui -files flow/signoff/g0/hello_genus.tcl -log sim/g0/genus` | `genus.txt`: mapped to `DFFRHQX1` of the generic 45 nm library, normal exit |
| Tessent | Modus 20.1 | `/home/install/MODUS201/bin/modus -version` | `modus.txt`: Modus 20.12-s002_1 |

## 0.2 Back-end tools

| Tool (1-TOPS list) | GARUDA uses | Command | Result (`out/`) |
|---|---|---|---|
| Innovus | Innovus 21.1 | `/home/install/INNOVUS211/bin/innovus -no_gui -batch -files flow/signoff/g0/hello_innovus.tcl -log sim/g0/innovus` | `innovus.txt`: 21.15-s110_1, 0 errors |
| Conformal LEC | Conformal 21.1 | `/home/install/CONFRML211/bin/lec -lpgxl -nogui -dofile flow/signoff/g0/hello_lec.do` | `conformal_lec.txt`: 2 of 2 points equivalent |
| Calibre | PVS 22.2 | `/home/install/PVS222/bin/pvs -version` | `pvs.txt`: 22.20-p031 |
| Calibre DFM | Pegasus DFM 22.1 | `/home/install/PEGASUSDFM221/bin/PEGASUSDFMVersion` | `pegasus_dfm.txt`: 22.12.000 |
| (extraction) | Quantus 21.2 | `/home/install/QUANTUS212/bin/quantus -version` | `quantus.txt` |
| PrimeTime | not installed: Tempus is absent | | timing from Innovus and Genus (deviation D-T8) |
| Voltus | not installed | | requested from 1-TOPS (deviation D-T9) |

## 0.3 RISC-V GNU toolchain

    set path = (/home/vivado/2025.2/Vitis/gnu/riscv/linux_toolchain/lin64/bin $path)
    riscv64-amd-linux-gnu-gcc -march=rv32im_zicsr -mabi=ilp32 -O2 -nostdlib -nostartfiles -static -T sw/common/link.ld sw/common/crt0.S flow/signoff/g0/hello_rv.c -o sim/g0/hello_rv.elf

`out/gcc.txt` holds the compiler version, the ELF header (32-bit RISC-V) and the disassembly of `main`. This is the Vitis multilib build, not `riscv32-*-elf` (deviation D-T10).

## 0.4 Spike

    /home/kkarthik/external/spike-inst/bin/spike --isa=rv32im_zicsr_zifencei_zicntr -m0x10000000:0x40000 --disable-dtb --priv=m --pmpregions=0 --triggers=0 --pc=0x10000000 --log-commits -l sw/riscv-tests/build/add.elf

`out/spike.txt` records the result. Exit status is 0, and the test stores 1 to `tohost`, which means it passed. The file also holds the first and last lines of the commit log.

## Traps found on this machine

- **irun and SimVision:** both need their install directory on PATH. Called by absolute path from another directory, irun stops with `*F,INSTRT`.
- **SimVision 32-bit:** without `-64bit` it starts the 32-bit binary, and this machine has only the 64-bit `libX11`.
- **Conformal licences:**
  - `-lpgxl` (feature `Conformal_Low_Power_GXL`) checks out.
  - The default and `-xl`, `-lp`, `-gxl` are refused: Ultra, Asic, Low_Power, Custom and GXL.
- **Generic 45 nm library:** `typical.lib` has no area attribute (LBR-43), so Genus reports area 0. Area budgets use the cell count or the Nangate library in the same folder.
