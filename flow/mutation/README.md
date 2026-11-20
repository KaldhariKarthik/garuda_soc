# Planted-defect lists: python3 tools/mutate.py flow/mutation/<block>_mutants.py (copies under sim/lab/<block>/mut)

Each spec names its block's file list in `FL_LINE`; `tools/mutate.py` reads the block's files from
it (TOOL-A24, 2026-11-19: hand-kept `FILES` lists had missed the state machines split out in F4).
A recipe whose text is not found exactly once fails the run, and `make check_tree` runs
`tools/check_mutants.py`, which checks every recipe here, the generated mutants of
`tools/gen/gen_*_mutants.py` and the UVM planted lists against the RTL.

## Results, 2026-11-20 (D-40 closure, tree 8db2380 + closing changes)

`python3.12 tools/mutate.py <spec>` with irun 15.2; output in `results/<set>_2026-11-20.txt`. Since
TOOL-A26 every mutant builds in a fresh directory and the run exits 1 on a survivor or a build error;
a mutant proven equivalent is named in its spec's `EQUIVALENT` with the evidence.

| Set | Mutants | Killed | Notes |
|---|---|---|---|
| ahb | 8 | 8 | all by assertions (the 2026-11-19 run was 8 BUILD ERRORs: a stale library, TOOL-A26) |
| bridge | 8 | 8 | |
| debug | 10 | 10 | |
| mem | 8 | 7, M8 equivalent | `EQUIVALENT` in the spec |
| spim | 6 | 6 | |
| dsu (stream) | 6 | 5, `clear_latches_product` equivalent | `DSU_STREAM=1`; the per-test protocol leaves the three TB-42 survivors by design |
| Verilator suites | AHB 19, APB 16, DMA 25 (SIZE_RESET in the register suite) + 1 equivalent, DSU 7 | all | `make -f flow/mk/track_a_run.mk {ahb,apb,dma,dsu}_mut` |
| UVM planted defects | UART 14, I2C 18, SPIS 12 | all | `scripts/planted_defects.sh`, each on a baseline that passes (TOOL-A26) |

## Results, 2026-11-10 (1-TOPS G4)

`python3.12 tools/mutate.py flow/mutation/<block>_mutants.py` with irun 15.2 on the path;
output in `results/<block>_2026-11-10.txt`. Every set is now killed:

| Set | Mutants | Killed | Notes |
|---|---|---|---|
| ahb | 8 | 8 | |
| bridge | 8 | 8 | |
| debug | 10 | 10 | M5 split into M5 / M5b / M5c (the alignment check is now in three places, D-33); M7 follows the RDC-1 grant. M5b, M5c, M7, M8 survived until `tb/debug/tb_debug.sv` got misaligned read-on-address and read-on-data, a DM deactivation while the hart is held, and a withheld grant on random cycles |
| mem | 8 | 7, M8 equivalent | M2 survived until `tb_mem_subsystem.sv` got a sub-word write and immediate read with other data on the idle lanes; M8 proven equivalent, `flow/formal/mem/dsram_bank_fpv.result.txt` |
| spim | 6 | 6 | M2 survived until the APB BFM held PWRITE after a write as the bridge does (TB-B4) |
| dma | 25 | 24, M12 equivalent | `logs/dma/evidence/dma_mut_2026-11-10.txt` |
| dsu | 7 | 7 | `logs/dsu/evidence/dsu_mut_2026-10-11.txt` |
