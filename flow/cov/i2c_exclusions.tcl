# =============================================================================
# i2c_exclusions.tcl - coverage waivers for block 15, the I2C master.
#
# Applied in IMC after loading the merged I2C run:
#     imc -exec flow/cov/i2c_report.tcl
# or typed at the IMC prompt. Every line has its reason. Sign-off criterion 3
# (flow/0_signoff_criteria.md): code coverage 100% after the waivers below.
# Checked against JasperGold by ./flow/formal/unr_block.sh i2c.
#
# Six reasons cover everything here:
#   1. No register of this block is wider than 16 bits, and bits 31, 28, 26, 24,
#      23, 21 and 17 of ID (0x6A5D0F01) are 0: the read-data bits listed are 0 in
#      every register (I2C section 6). Checked on every read by the scoreboard.
#   2. PREADY is tied high (AHB2APB 7.5); checked by a_pready and a_shim_pready.
#   3. Open drain: the output values are constant 0 (I2C N-9.2); a_never_high.
#   4. The vendored controllers' enable is tied high (I2C-1): the wrapper stops
#      them through their reset, so the "enable low" branches cannot be taken.
#   5. The vendored state machines are written with full_case and no default.
#   6. The shim's two simulation-only checks cannot fire in a correct build.
# =============================================================================
exclude -inst garuda_i2c_top -toggle prdata_o\[31\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle prdata_o\[28\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle prdata_o\[26\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle prdata_o\[24\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle prdata_o\[23\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle prdata_o\[21\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle prdata_o\[17\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle pready_o -comment "PREADY is tied high: an access to this block never waits (I2C R-4); checked by a_pready and a_shim_pready"
exclude -inst garuda_i2c_top -toggle i2c_scl_o -comment "open drain: the output value of both pins is tied to 0 and the block speaks through the output enables only (I2C N-9.2); checked by a_never_high"
exclude -inst garuda_i2c_top -toggle i2c_sda_o -comment "open drain: the output value of both pins is tied to 0 and the block speaks through the output enables only (I2C N-9.2); checked by a_never_high"
exclude -inst garuda_i2c_top -toggle reg_rdata\[31\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle reg_rdata\[30\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle reg_rdata\[29\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle reg_rdata\[28\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle reg_rdata\[27\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle reg_rdata\[26\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle reg_rdata\[25\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle reg_rdata\[24\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle reg_rdata\[23\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle reg_rdata\[22\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle reg_rdata\[21\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle reg_rdata\[20\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle reg_rdata\[19\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle reg_rdata\[18\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle reg_rdata\[17\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle reg_rdata\[16\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top -toggle core_scl_o -comment "open drain: the output value of both pins is tied to 0 and the block speaks through the output enables only (I2C N-9.2); checked by a_never_high"
exclude -inst garuda_i2c_top -toggle core_sda_o -comment "open drain: the output value of both pins is tied to 0 and the block speaks through the output enables only (I2C N-9.2); checked by a_never_high"
exclude -inst garuda_i2c_top.u_shim -toggle prdata_o\[31\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle prdata_o\[28\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle prdata_o\[26\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle prdata_o\[24\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle prdata_o\[23\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle prdata_o\[21\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle prdata_o\[17\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle pready_o -comment "PREADY is tied high: an access to this block never waits (I2C R-4); checked by a_pready and a_shim_pready"
exclude -inst garuda_i2c_top.u_shim -toggle ip_prdata_i\[31\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle ip_prdata_i\[30\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle ip_prdata_i\[29\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle ip_prdata_i\[28\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle ip_prdata_i\[27\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle ip_prdata_i\[26\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle ip_prdata_i\[25\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle ip_prdata_i\[24\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle ip_prdata_i\[23\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle ip_prdata_i\[22\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle ip_prdata_i\[21\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle ip_prdata_i\[20\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle ip_prdata_i\[19\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle ip_prdata_i\[18\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle ip_prdata_i\[17\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle ip_prdata_i\[16\] -comment "read-data bit that is 0 in every register of this block (no register is wider than 16 bits and these bits of ID are 0): constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_i2c_top.u_shim -toggle ip_pready_i -comment "PREADY is tied high: an access to this block never waits (I2C R-4); checked by a_pready and a_shim_pready"
exclude -inst garuda_i2c_top.u_shim.u_shim_sva -toggle pready_o -comment "PREADY is tied high: an access to this block never waits (I2C R-4); checked by a_pready and a_shim_pready"
exclude -inst garuda_i2c_top.u_byte -toggle ena -comment "the vendored controllers' enable input is tied high by the wrapper, which stops them through their reset instead (I2C-1, N-7.5)"
exclude -inst garuda_i2c_top.u_byte -toggle scl_o -comment "open drain: the output value of both pins is tied to 0 and the block speaks through the output enables only (I2C N-9.2); checked by a_never_high"
exclude -inst garuda_i2c_top.u_byte -toggle sda_o -comment "open drain: the output value of both pins is tied to 0 and the block speaks through the output enables only (I2C N-9.2); checked by a_never_high"
exclude -inst garuda_i2c_top.u_byte.bit_controller -toggle ena -comment "the vendored controllers' enable input is tied high by the wrapper, which stops them through their reset instead (I2C-1, N-7.5)"
exclude -inst garuda_i2c_top.u_byte.bit_controller -toggle scl_o -comment "open drain: the output value of both pins is tied to 0 and the block speaks through the output enables only (I2C N-9.2); checked by a_never_high"
exclude -inst garuda_i2c_top.u_byte.bit_controller -toggle sda_o -comment "open drain: the output value of both pins is tied to 0 and the block speaks through the output enables only (I2C N-9.2); checked by a_never_high"
exclude -inst garuda_i2c_top.u_byte.bit_controller -toggle c_state\[17\] -comment "bit 17 of the vendored bit controller's state vector: it has 17 states in an 18-bit one-hot vector, so the top bit is never used"
exclude -inst garuda_i2c_top.u_i2c_sva -toggle pready_o -comment "PREADY is tied high: an access to this block never waits (I2C R-4); checked by a_pready and a_shim_pready"
exclude -inst garuda_i2c_top.u_i2c_sva -toggle i2c_scl_o -comment "open drain: the output value of both pins is tied to 0 and the block speaks through the output enables only (I2C N-9.2); checked by a_never_high"
exclude -inst garuda_i2c_top.u_i2c_sva -toggle i2c_sda_o -comment "open drain: the output value of both pins is tied to 0 and the block speaks through the output enables only (I2C N-9.2); checked by a_never_high"
exclude -inst garuda_i2c_top.u_byte -block 56 -comment "the state machine of the vendored byte controller has no default branch (full_case): the five states listed are all it can be in, so the implicit default is never taken"
exclude -inst garuda_i2c_top.u_byte.bit_controller -block 77 -comment "the state machine of the vendored bit controller has no default branch (full_case): the 17 one-hot states listed are all it can be in, so the implicit default is never taken"
exclude -inst garuda_i2c_top.u_byte.bit_controller -block 18 -comment "the spike filter's counter is cleared when the vendored enable is low; the wrapper ties the enable high (I2C-1)"
exclude -inst garuda_i2c_top.u_byte.bit_controller -expression 1.1 -comment "the term for the vendored enable being low in the prescaler reload: the wrapper ties the enable high (I2C-1)"
exclude -inst garuda_i2c_top.u_shim -block 27 -comment "the shim stops the simulation if its parameter IP_LIMIT is above 0x100, which the 64-bit register map cannot describe; the parameter is a constant below that here, so the branch cannot be taken"
exclude -inst garuda_i2c_top.u_shim -block 30 -comment "the shim's report that an IP held PREADY low: the I2C registers answer in the same cycle (ip_pready_i tied high), so the report can never print here"
exclude -inst garuda_i2c_top.u_shim -expression 4.1 -comment "condition of the same report: ip_pready_i is tied high in garuda_i2c_top"
