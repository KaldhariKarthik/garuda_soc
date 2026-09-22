# OpenCores I2C master (bit + byte controllers)

Vendored from https://github.com/pulp-platform/apb_i2c at commit
`84855413cc2c8e70209ee7f168a0225d3c5914a1` on 2026-09-22; those files originate
from http://www.opencores.org/projects/i2c (Richard Herveille, 2001).

Licence: the permissive notice in each file header - use and distribution are
unrestricted provided the copyright statement stays in the file and derivative
work carries the original notice and disclaimer. Not modified.

PULP`s apb_i2c.sv register front end is deliberately NOT vendored: it carries no
licence header and its repository has no LICENSE file. Our register layer is
`rtl/i2c/garuda_i2c_top.v` (D-22).
