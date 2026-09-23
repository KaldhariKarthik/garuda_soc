# GARUDA SoC — Third-party notices

The GARUDA SoC includes RTL from the projects below. This file exists to
discharge the attribution and notice-preservation obligations those licences
carry, and it **ships with the design** — with the GDSII handoff, with any
netlist or FPGA bitstream, and with any product that contains the chip.

Policy for how this code is handled — vendored verbatim, every delta in a
GARUDA wrapper, and a recorded patch only where that is impossible — is
`Docs/DECISIONS.md` D-22 and D-24. Machine-readable provenance (upstream URL,
commit SHA, vendoring date) is `rtl/third_party/MANIFEST.yaml`; per-file
SHA-256 hashes are `rtl/third_party/HASHES.txt`. `tools/vendor_sync.py --check`
verifies both the hashes and, for a patched IP, that the working files are
still exactly `patches/orig/` plus the recorded patch.

Full licence texts are kept next to the code they cover, at
`rtl/third_party/<vendor>/<ip>/LICENSE`. The summaries here do not replace them.

---

## 1. PULP Platform — Solderpad Hardware License, Version 0.51

Copyright ETH Zurich and University of Bologna.

| IP | Used for | Upstream |
|---|---|---|
| `apb_spi_master` | Block 13 SPI master — boot flash and IMU | <https://github.com/pulp-platform/apb_spi_master> |
| `axi_spi_master` | the SPI datapath `apb_spi_master` builds on (clkgen, controller, FIFO, RX, TX) | <https://github.com/pulp-platform/axi_spi_master> |
| `apb_uart_sv` | Blocks 16/17/18 — uart0, uart1, uart2 · **MODIFIED, see below** | <https://github.com/pulp-platform/apb_uart_sv> |
| `apb_gpio` | Block 19 — GPIO | <https://github.com/pulp-platform/apb_gpio> |

Licensed under the Solderpad Hardware License, Version 0.51 (the "License");
you may not use these files except in compliance with the License. You may
obtain a copy of the License at <http://solderpad.org/licenses/SHL-0.51>.
Unless required by applicable law or agreed to in writing, software, hardware
and materials distributed under this License are distributed on an "AS IS"
BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.

### Modifications made by GARUDA

Solderpad 0.51 requires that modified files carry prominent notices stating
they were changed. **One IP is modified:**

- **`apb_uart_sv`** — `src/uart_rx.sv` and `src/apb_uart.sv` are changed by
  `rtl/third_party/pulp/apb_uart_sv/patches/0001-report-parity-and-framing-errors.patch`,
  so that the receiver reports parity and framing errors (GARUDA-UART-SPEC-001
  R-7, which upstream cannot meet — see `Docs/BUGS.md` ERR-U2). Every changed
  line carries a `GARUDA patch 0001` marker in the source, the file as vendored
  is preserved verbatim under `patches/orig/`, and `tools/vendor_sync.py
  --check` fails if the working files stop matching `orig/` plus the recorded
  patch. Copyright and licence headers are untouched.

No other vendored file is modified.

**Two obligations a tapeout signatory should see.** Solderpad 0.51 is a
permissive Apache-2.0 derivative extended to hardware, so the terms below come
from Apache 2.0 and apply to silicon:

- **Attribution and notice preservation.** Copyright, patent, trademark and
  attribution notices in the source must be retained, and this NOTICE must
  travel with any distribution of the design or a product containing it. The
  per-file headers in `rtl/third_party/` are part of that obligation, and are
  never touched — including in the one modified IP, where the changes are
  additive and marked.
- **The patent grant and its termination clause.** Contributors grant a patent
  licence covering their contributions. That grant **terminates** for any
  licensee who initiates patent litigation alleging that the work infringes.
  Legal review should see this before tapeout, since it binds the entity
  shipping the chip, not the engineer who vendored the file.

## 2. OpenCores I²C master — Richard Herveille

Copyright (C) 2001 Richard Herveille · <richard@asics.ws> ·
<https://opencores.org/projects/i2c>

Used for Block 15 (I²C): the bit controller and byte controller only —
`i2c_master_bit_ctrl.sv`, `i2c_master_byte_ctrl.sv`, `i2c_master_defines.sv`.

This code is free software; redistribution and use in source and binary forms,
with or without modification, are permitted provided that the above copyright
notice and the full licence text in each file header are reproduced. The
software is provided "AS IS" and without any express or implied warranties,
including the implied warranties of merchantability and fitness for a
particular purpose. In no event shall the author be liable for any direct,
indirect, incidental, special, exemplary or consequential damages.

**Not vendored, deliberately:** PULP's `apb_i2c.sv` register front end, which
normally sits on top of these controllers, carries no licence header and its
repository has no LICENSE file. GARUDA supplies its own register layer in
`rtl/i2c/garuda_i2c_top.v` rather than ship RTL whose provenance cannot be
stated (D-22).

---

## Verification IP (simulation only — not in the chip)

Nothing in this section is synthesised or taped out. It is listed because it
ships in the repository.

| Component | Licence | Used for |
|---|---|---|
| *(none vendored yet)* | — | mbits-mirafra UVM VIP (MIT) is planned for I²C, and possibly UART, under `tb/uvm/` |

---

## GARUDA's own RTL

Everything outside `rtl/third_party/` is GARUDA's, under the project's own
terms. The wrappers in `rtl/spi_master/`, `rtl/uart/`, `rtl/gpio/`, `rtl/i2c/`
and the shared `rtl/common/garuda_apb_shim.v` are GARUDA code that instantiates
the IP above; they are not derivatives of it in the copyright sense, but they
are useless without it, which is the practical reason this file must stay
accurate.
