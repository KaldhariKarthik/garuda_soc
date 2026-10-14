# Bugs: SPI slave (rtl/spi_slave)

Owner: Track B. Index of all blocks: [`Docs/BUGS.md`](../BUGS.md). Process and fields: [`Docs/handbook/H3_bugs.md`](../handbook/H3_bugs.md).
Priorities: P1 the chip does the wrong thing or hangs; P2 a specified feature does not work but there is a workaround; P3 everything else (`flow/0_signoff_criteria.md`).

<!-- tools/bugs/bugs.py parses this table: one row per ID, columns fixed. Run `bugs.py check` before pushing. -->
| ID | Title | Status | Prio | Found-by | Found | Fixed-in | Regression test | Evidence | Formerly |
|---|---|---|---|---|---|---|---|---|---|
| SPIS-1 | An SPI slave's shift clock comes from the far end of the wire, so the textbook build clocks the shifter on sclk and c... | CLOSED | - | - | 2026-09-26 | legacy | - | HISTORY_2026.md L195 | - |
| SPIS-2 | That is simulation being kinder than silicon | CLOSED | - | - | 2026-09-26 | legacy | - | HISTORY_2026.md L196 | - |
| SPIS-3 | 2 pclk (16 ns) after cs_n rises | WONTFIX | - | - | 2026-09-26 | legacy | - | HISTORY_2026.md L197 | - |
| SPIS-4 | Every transmitted byte after the first went out shifted left by one bit | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L328 | - |
| SPIS-5 | Setting CTRL.EN while the master was already inside a frame started the shifter on whatever bit came next, pushed mis... | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L329 | - |
| SPIS-6 | A write-1-to-clear in the cycle of a new event cleared the STATUS bit while IRQSTAT kept it: the interrupt said "over... | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L330 | - |
| SPIS-7 | IP_LIMIT was 0x020 (copied from PWM) for a block with four registers: offsets 0x10..0x1C read 0 and swallowed writes ... | FIXED | - | - | 2026-10-04 | legacy | - | HISTORY_2026.md L331 | - |

## Details

### SPIS-1

*From `Docs/BUGS.md` at b90b481, line 195, section "1e. Block 14 (SPI slave) — 2026-09-26".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **SPIS-1** | design decision | — | An SPI slave's shift clock comes from the far end of the wire, so the textbook build clocks the shifter on `sclk` and crosses to `pclk` through an async FIFO. That would have made DEBUG [N-7.16] — "`dmi_cdc` is the only asynchronous crossing in the chip" — false, for one peripheral. `garuda_spis_core.v` oversamples in `pclk` instead. The chip keeps one CDC; the cost is SCLK ≤ pclk/6 = 20 MHz, specified, and scaling with DIVSEL. |

### SPIS-2

*From `Docs/BUGS.md` at b90b481, line 196, section "1e. Block 14 (SPI slave) — 2026-09-26".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **SPIS-2** | `t_spis_rate` | MEASURED, caveated | The rate sweep passes at every half period down to 9 ns, far below the specified 24 ns limit. **That is simulation being kinder than silicon**: ideal edges cannot exercise metastability or finite edge rates, which is what actually sets the limit. The sweep confirms correctness at and above the spec figure; it does not derive it, and the log says so rather than letting a reader infer headroom that is not there. Half periods are deliberately not `pclk` multiples, because aligned edges make an oversampler look better than it is. |

### SPIS-3

*From `Docs/BUGS.md` at b90b481, line 197, section "1e. Block 14 (SPI slave) — 2026-09-26".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **SPIS-3** | `[N-9.2a]` | ACCEPTED, bounded | `miso_oe` drops **2 `pclk` (16 ns) after `cs_n` rises**, because `cs_n` arrives through the shim's synchroniser. Releasing from the raw pin would remove the tail but put a combinational path from an async pad input onto a pad output enable — on the one block whose premise is adding no async timing. Bounded instead: `t_spis_reset` fails above 3 `pclk`, and at max SCLK a bit is 50 ns so no master can reselect inside it. |

### SPIS-4

*From `Docs/BUGS.md` at b90b481, line 328, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **SPIS-4** | `rtl/spi_slave/garuda_spis_core.v` | FIXED | **Every transmitted byte after the first went out shifted left by one bit.** At the eighth falling edge the shifter was reloaded with `{txdata[6:0], 1'b0}`: `TXDATA = 0xA5` was answered `A5 4A 4A ...`. A one-byte test cannot see it. |

### SPIS-5

*From `Docs/BUGS.md` at b90b481, line 329, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **SPIS-5** | `rtl/spi_slave/garuda_spis_core.v` | FIXED | Setting `CTRL.EN` while the master was already inside a frame started the shifter on whatever bit came next, pushed misaligned bytes into the FIFO as data and reported the packet complete. A packet now opens only on a `cs_n` falling edge seen while enabled. |

### SPIS-6

*From `Docs/BUGS.md` at b90b481, line 330, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **SPIS-6** | `rtl/spi_slave/garuda_spis_top.v` | FIXED | A write-1-to-clear in the cycle of a new event cleared the STATUS bit while IRQSTAT kept it: the interrupt said "overrun", STATUS said it had not happened. Set now beats clear. |

### SPIS-7

*From `Docs/BUGS.md` at b90b481, line 331, section "1h. Flow stages 2 to 6 on Cadence tools — 2026-10-04".*

| ID | Where | Status | Summary |
|---|---|---|---|
| **SPIS-7** | `rtl/spi_slave/garuda_spis_top.v` | FIXED | `IP_LIMIT` was `0x020` (copied from PWM) for a block with four registers: offsets 0x10..0x1C read 0 and swallowed writes instead of raising PSLVERR. |
