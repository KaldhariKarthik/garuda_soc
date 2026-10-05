# Reset-domain review

Written 2026-10-04 by reading `rtl/reset_ctrl/reset_ctrl.v`, `rtl/soc/garuda_soc_top.v`
and the reset pins of each block. HAL 15.20 has no reset-domain-crossing check, so
this is a review, not a tool report. Where a statement below needs a tool to
hold it, that is said.

## The reset domains

| Reset | Driven by | Asserts | Releases | Resets |
|---|---|---|---|---|
| `ext_rst_n` (pin) | board supervisor | asynchronously | synchronised in each domain | everything |
| `hreset_n` | `hrst_q`, set by `sys_req_q` | asynchronously, on a reference-clock edge | two flops on hclk | bus fabric, memories, DMA, CLIC, timers |
| `preset_n` | `prst_q`, set by `sys_req_q` | asynchronously | two flops on pclk, after `hreset_n` | bridge peripheral side, all peripherals |
| `core_rst_n` | `core_q`, set by `core_req_q` | asynchronously | two flops on hclk | core and DSU |
| `hartreset` | a Debug Module flop on hclk, ANDed into the core's reset inside the core | at an hclk edge | at an hclk edge, no synchroniser | core and DSU |
| `dm_rst_n` | `dm_q`, set by `dm_req_q` | asynchronously | two flops on hclk | Debug Module (not on `ndmreset`) |
| `ext_hrst_n`, `ext_prst_n` | pin only | asynchronously | two flops on hclk / pclk | watchdog request flop, RSTREASON side |
| TAP reset | five TMS-high clocks, `por_n` | on tck | on tck | TAP and DTM |

Every reset that reaches a flop's asynchronous pin comes straight from a flop
output. HAL found one exception, the I2C core reset, fixed as I2C-5, and one that
stays by design, the AND of the two core resets inside the core (waived, CORE
[N-7.33]).

## Crossings: a flop that can be reset while the flop it feeds is not

| # | From (reset by) | To (reset by) | When | Verdict |
|---|---|---|---|---|
| 1 | watchdog counter and enable (`hreset_n`) | watchdog request flop (`ext_hrst_n`) | any internal reset | Safe by construction: the request flop is forced to 0 by `hreset_n` low as a synchronous term, so what its other inputs do during the reset does not matter. Checked in simulation (`tb_timers`, `t_chip_wdt`). |
| 2 | request flop, DM requests, APB strobes (hclk, pclk) | stretch counter and RSTREASON (reference clock, pin reset only) | every request | Synchronous: hclk and pclk are divided from the reference clock. Needs the generated-clock constraints at synthesis; nothing to check before that. |
| 3 | bus fabric and slaves (`hreset_n`) | Debug Module (`dm_rst_n`) | `ndmreset` | The debugger writes `ndmreset` through the DMI, and no system-bus access is in flight during that write. If one were, `sbdata0` would capture from a bus in reset. Not excluded by the RTL; to be checked with a test (debug plan F27). |
| 4 | Debug Module hclk side (`dm_rst_n`) | TAP, DTM and the tck side of `dmi_cdc` (TAP reset only) | watchdog or software reset during a debug session | The handshake toggles on the two sides can disagree after the reset. Decision D-18 handles it; `tb_debug` resets the hclk side mid-request and checks the DTM is not stuck. |
| 5 | **core bus masters (`core_rst_n`, `hartreset`)** | **bus fabric and slaves (`hreset_n`)** | **the debugger halts the core** | **Open.** A halt is a reset of the core at an arbitrary cycle. If the core is in the data phase of a store that is being waited (every peripheral write is, for about eight cycles), its write data and its next address phase change under a bus that is not in reset. Expected result: the transfer in flight completes with the wrong data, and the address phase behind it is withdrawn, which AHB does not allow. **Reproduced 2026-10-04**: with the core's debug reset forced at 50 moments during a storing program, one moment landed in a waited store and the bus checker reported the write data changing mid-transfer. No regression test does this yet: `t_chip_jtag` halts a core that is idling in the boot ROM. Logged as RDC-1; permanent test planned in the core plan, F37. |
| 6 | core (`core_rst_n`) | CLIC, timers (`hreset_n`) | halt | None: nothing in those blocks is driven by the core except through the bus (crossing 5). |
| 7 | everything (`hreset_n`) | divider (`ext_rst_n` raw) | any internal reset | `div_sel` returns to its reset value unless the register is outside the reset; the divider changes ratio glitch-free. To be checked with the clock plan's F14 under a reset. |

## Release

Each domain releases through its own two-flop synchroniser on its own clock, and
`preset_n` is released from `hreset_n`'s synchroniser output, so it cannot come
first. `hartreset` is released directly from a flop on the core's own clock; that
is a normal recovery and removal check for the timing tool, not a simulation
matter.

## What a tool would add

A reset-domain-crossing checker (JasperGold, or Conformal's constraint designer
with the SDC) would list these crossings itself and catch any I have missed. Until
one is run this review is the evidence.
