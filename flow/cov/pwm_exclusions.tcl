# =============================================================================
# pwm_exclusions.tcl - coverage waivers for block 20, the PWM.
#
# Applied in IMC after loading the merged PWM run:
#     imc -exec flow/cov/pwm_report.tcl
# or typed at the IMC prompt. Every line has its reason. Sign-off criterion 3
# (flow/0_signoff_criteria.md): code coverage 100% after the waivers below.
#
# Three reasons cover everything here:
#   1. No register of this block is wider than 20 bits, and the upper half of
#      ID is the constant 0x6A5D: the read-data bits listed are 0 in every
#      register (PWM section 6). Checked on every read by the scoreboard.
#   2. PREADY is tied high (AHB2APB 7.5); checked by a_shim_pready.
#   3. The PWM has no DMA channel and no pad input (PWM section 5): the shim's
#      DMA and synchroniser inputs are tied off in garuda_pwm_top, so that
#      logic cannot move here. It is exercised in the blocks that use it
#      (UART, I2C, SPI). a_no_dma_req checks that no request ever leaves.
# =============================================================================
exclude -inst garuda_pwm_top -toggle reg_rdata\[20\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top.u_shim -toggle ip_prdata_i\[20\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top -toggle reg_rdata\[21\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top.u_shim -toggle ip_prdata_i\[21\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top -toggle reg_rdata\[22\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top.u_shim -toggle ip_prdata_i\[22\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top -toggle reg_rdata\[23\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top.u_shim -toggle ip_prdata_i\[23\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top -toggle reg_rdata\[24\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top.u_shim -toggle ip_prdata_i\[24\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top -toggle reg_rdata\[25\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top.u_shim -toggle ip_prdata_i\[25\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top -toggle reg_rdata\[26\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top.u_shim -toggle ip_prdata_i\[26\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top -toggle reg_rdata\[27\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top.u_shim -toggle ip_prdata_i\[27\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top -toggle reg_rdata\[28\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top.u_shim -toggle ip_prdata_i\[28\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top -toggle reg_rdata\[29\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top.u_shim -toggle ip_prdata_i\[29\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top -toggle reg_rdata\[30\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top.u_shim -toggle ip_prdata_i\[30\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top -toggle reg_rdata\[31\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top.u_shim -toggle ip_prdata_i\[31\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top -toggle prdata_o\[31\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top.u_shim -toggle prdata_o\[31\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top -toggle prdata_o\[28\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top.u_shim -toggle prdata_o\[28\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top -toggle prdata_o\[26\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top.u_shim -toggle prdata_o\[26\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top -toggle prdata_o\[24\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top.u_shim -toggle prdata_o\[24\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top -toggle prdata_o\[23\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top.u_shim -toggle prdata_o\[23\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top -toggle prdata_o\[21\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top.u_shim -toggle prdata_o\[21\] -comment "read-data bit that is 0 in every register of this block: constant by specification, checked by the scoreboard on every read"
exclude -inst garuda_pwm_top -toggle pready_o -comment "PREADY is tied high, no wait states: checked by a_shim_pready and sb_pready"
exclude -inst garuda_pwm_top.u_shim -toggle pready_o -comment "PREADY is tied high, no wait states: checked by a_shim_pready and sb_pready"
exclude -inst garuda_pwm_top.u_shim.u_shim_sva -toggle pready_o -comment "PREADY is tied high, no wait states: checked by a_shim_pready and sb_pready"
exclude -inst garuda_pwm_top.u_shim -toggle ip_pready_i -comment "tied high in garuda_pwm_top: the registers answer in the same cycle"
exclude -inst garuda_pwm_top.u_shim -toggle rx_avail_i -comment "tied off in garuda_pwm_top: the PWM has no DMA channel and no pad input; covered in the blocks that use the shim's DMA and synchroniser"
exclude -inst garuda_pwm_top.u_shim -toggle tx_space_i -comment "tied off in garuda_pwm_top: the PWM has no DMA channel and no pad input; covered in the blocks that use the shim's DMA and synchroniser"
exclude -inst garuda_pwm_top.u_shim -toggle dma_ack_i -comment "tied off in garuda_pwm_top: the PWM has no DMA channel and no pad input; covered in the blocks that use the shim's DMA and synchroniser"
exclude -inst garuda_pwm_top.u_shim -toggle dma_req_o -comment "tied off in garuda_pwm_top: the PWM has no DMA channel and no pad input; covered in the blocks that use the shim's DMA and synchroniser"
exclude -inst garuda_pwm_top.u_shim -toggle pad_async_i -comment "tied off in garuda_pwm_top: the PWM has no DMA channel and no pad input; covered in the blocks that use the shim's DMA and synchroniser"
exclude -inst garuda_pwm_top.u_shim -toggle pad_sync_o -comment "tied off in garuda_pwm_top: the PWM has no DMA channel and no pad input; covered in the blocks that use the shim's DMA and synchroniser"
exclude -inst garuda_pwm_top.u_shim -toggle holdoff_q -comment "tied off in garuda_pwm_top: the PWM has no DMA channel and no pad input; covered in the blocks that use the shim's DMA and synchroniser"
exclude -inst garuda_pwm_top.u_shim -toggle sync0_q -comment "tied off in garuda_pwm_top: the PWM has no DMA channel and no pad input; covered in the blocks that use the shim's DMA and synchroniser"
exclude -inst garuda_pwm_top.u_shim -toggle sync1_q -comment "tied off in garuda_pwm_top: the PWM has no DMA channel and no pad input; covered in the blocks that use the shim's DMA and synchroniser"
exclude -inst garuda_pwm_top.u_shim.u_shim_sva -toggle rx_avail_i -comment "tied off in garuda_pwm_top: the PWM has no DMA channel and no pad input; covered in the blocks that use the shim's DMA and synchroniser"
exclude -inst garuda_pwm_top.u_shim.u_shim_sva -toggle tx_space_i -comment "tied off in garuda_pwm_top: the PWM has no DMA channel and no pad input; covered in the blocks that use the shim's DMA and synchroniser"
exclude -inst garuda_pwm_top.u_shim.u_shim_sva -toggle dma_ack_i -comment "tied off in garuda_pwm_top: the PWM has no DMA channel and no pad input; covered in the blocks that use the shim's DMA and synchroniser"
exclude -inst garuda_pwm_top.u_shim.u_shim_sva -toggle dma_req_o -comment "tied off in garuda_pwm_top: the PWM has no DMA channel and no pad input; covered in the blocks that use the shim's DMA and synchroniser"
exclude -inst garuda_pwm_top.u_pwm_sva -toggle dma_req -comment "tied off in garuda_pwm_top: the PWM has no DMA channel and no pad input; covered in the blocks that use the shim's DMA and synchroniser"
exclude -inst garuda_pwm_top.u_shim.u_shim_sva -assertion a_shim_dma_holdoff -comment "tied off in garuda_pwm_top: the PWM has no DMA channel and no pad input; covered in the blocks that use the shim's DMA and synchroniser"
exclude -inst garuda_pwm_top.u_shim.u_shim_sva -assertion a_shim_dma_gate -comment "tied off in garuda_pwm_top: the PWM has no DMA channel and no pad input; covered in the blocks that use the shim's DMA and synchroniser"
exclude -inst garuda_pwm_top.u_shim -block 27 -comment "the shim's report that an IP held PREADY low: the PWM registers answer in the same cycle (ip_pready_i tied high), so the report can never print here"
exclude -inst garuda_pwm_top.u_shim -expression 4.1 -comment "condition of the same report: ip_pready_i is tied high in garuda_pwm_top"
