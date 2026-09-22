# Third-party RTL

Upstream IP vendored into GARUDA. **Files under this directory are never
edited.** Every GARUDA-specific change lives in the wrapper next to the block
(`rtl/<block>/garuda_*_top.v`), which is also where our register map, interrupt
and DMA semantics are implemented. Policy and rationale: `Docs/DECISIONS.md` D-22.

| Directory | Block | Wrapper |
|---|---|---|
| `pulp/apb_spi_master` + `pulp/axi_spi_master` | 13 spi_master | `rtl/spi_master/garuda_spim_top.v` |
| `pulp/apb_uart_sv` | 16/17/18 uart0/1/2 | `rtl/uart/garuda_uart_top.v` |
| `pulp/apb_gpio` | 19 gpio | `rtl/gpio/garuda_gpio_top.v` |
| `opencores/i2c` | 15 i2c | `rtl/i2c/garuda_i2c_top.v` |

Block 20 (pwm) has no upstream: it is written in-house (`rtl/pwm/`), because the
only PULP option is the far larger `apb_adv_timer` and an ESC output has a
safe-idle requirement that is cheaper to prove on a counter-compare.

## Rules

1. **No edits upstream.** If you think you need one, you need a wrapper change.
2. If a change is genuinely unavoidable (a missing port, say), it goes in
   `<ip>/patches/*.patch` with a `Docs/BUGS.md` entry saying why. An empty
   `patches/` directory is the goal state.
3. `MANIFEST.yaml` records where each IP came from and at which commit.
   `HASHES.txt` records what we vendored. Run:

   ```
   python3 tools/vendor_sync.py --check     # CI and code review
   python3 tools/vendor_sync.py --update    # only after a deliberate re-vendor
   ```

4. Each IP compiles into its **own Xcelium library** (`-makelib` in its
   `filelist.f`). PULP uses generic module names — `clk_div`, FIFOs, clock-gating
   cells — that collide with GARUDA's own `rtl/clk_div/`. A library per IP fixes
   that without touching upstream code.
5. Licences and copyright notices are reproduced in `Docs/THIRD_PARTY_NOTICES.md`
   and must ship with the design.
