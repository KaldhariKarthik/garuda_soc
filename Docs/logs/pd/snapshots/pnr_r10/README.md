# pnr_r10 snapshots (ASAP7, final exploratory run, 2026-11-22)

Layout pictures of run pnr_r10, stage by stage. EXPLORATORY: ASAP7 with mock memories.
Stage pictures: `make pd_stage_shots V=pnr_r10`. GDS renders: `make pd_shot V=pnr_r10 [PD_VIEW=routing]`.
The ORFS pictures come from `~/tools/garuda_pd/reports/asap7/garuda/pnr_r10/`. Results:
`Docs/logs/pd/PD_LOG_2026-11-21.md`.

| File | Stage | What it shows |
|---|---|---|
| `01_floorplan.png` | Floorplan | Six memory macros in a row along the bottom (labelled), standard-cell rows, power-grid straps; die 320 x 300 µm |
| `02_placement.png` | Placement | Standard cells placed above the memories, clustered by connectivity; no wires |
| `03_cts_all_clocks.png` | CTS | Every clock net and clock buffer |
| `04_cts_hclk_tree_layout.png` | CTS | The hclk tree drawn on the die |
| `05_cts_hclk_tree_diagram.png` | CTS | Arrival time per hclk sink: most at 700 to 750 ps, the core behind the clock gate at 950 to 1,000 ps (PD-15, D-43) |
| `06_global_route_demand.png` | Global route | Estimated routing demand (RUDY); the memories are blockages |
| `07_detailed_route.png` | Detailed route | Every routed signal net |
| `08_final_congestion.png` | After route | Routing congestion; overflow 0 on every layer |
| `09_resizer_buffers.png` | After route | Cells the repairs inserted; hold buffers in green (8,038) |
| `10_worst_path.png` | After route | Worst setup path, DIV2 at SS (+141.86 ps) |
| `11_ir_drop.png` | After route | Power-grid IR drop, default activity (optimistic: mock memories) |
| `12_gds_all_layers.png` | GDS | KLayout render, every layer |
| `13_gds_M3_M7.png` | GDS | KLayout render, M3 to M7 |
