# 1-TOPS gate G1: item 1.15, gate-count budget

A trial synthesis of `garuda_chip_top` to measure the logic. Run from the repository root in tcsh:

    source /home/install/cshrc
    /home/install/GENUS211/bin/genus -batch -no_gui -files flow/signoff/g1/trial_synth.tcl -log sim/g1_synth/genus

Run on 2026-11-03 with Genus 21.14 on the Nangate 45 nm open cell library; the script's header explains the library choice. SRAMs and ROM are black boxes, there is no SDC, and the result is the logic only.

| | Result (`out/summary.txt`) |
|---|---|
| Cells | 39,854 |
| Flops | 7,925 |
| Latches | 1 (the clock-gate cell) |
| Area | 90,451.7 µm² = **113.3 kGE** (NAND2_X1 = 0.798 µm²) |
| Unresolved references | none (`out/unresolved.rpt`) |

Reports: `out/area.rpt`, `out/gates.rpt` (cell types: 61% sequential), `out/area_by_block.rpt`.

The budget derived from it (150 kGE of logic) is in `Design_Docs/GARUDA-PHYS-SPEC-001.md` [N-6.4].
