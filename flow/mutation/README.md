# Planted-defect lists: python3 tools/mutate.py flow/mutation/<block>_mutants.py (copies under sim/lab/<block>/mut)

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
