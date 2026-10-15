`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - chip : the pin wrapper (garuda_chip_top, P2) drives each bidirectional pad
// with its output when enabled and leaves it floating otherwise (PHYS section 3).
// Bound to garuda_chip_top; runs in every chip program.
// Not for synthesis, not under Icarus (TOOL-B2).
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
module chip_pads_sva (
    input wire refclk, ext_rst_n,
    input wire tdo_o, tdo_oe, scl_o, scl_oe, sda_o, sda_oe, miso_o, miso_oe,
    input wire [1:0] gpio_o, gpio_oe,
    input wire tdo, i2c_scl, i2c_sda, gpio0, gpio1, spis_miso
);
    // an enabled pad shows its output (the I2C pads are open drain on the board: the chip only
    // drives them low, so "shows its output" is checked for the value 0)
    a_pad_tdo:  assert property (@(posedge refclk) disable iff (!ext_rst_n) tdo_oe |-> tdo === tdo_o )
        else $error("[SVA-FAIL] a_pad_tdo: TDO pad does not carry tdo_o while enabled");
    a_pad_miso: assert property (@(posedge refclk) disable iff (!ext_rst_n) miso_oe |-> spis_miso === miso_o )
        else $error("[SVA-FAIL] a_pad_miso: MISO pad does not carry miso_o while enabled");
    a_pad_gpio0: assert property (@(posedge refclk) disable iff (!ext_rst_n) gpio_oe[0] |-> gpio0 === gpio_o[0] )
        else $error("[SVA-FAIL] a_pad_gpio0: GPIO0 pad does not carry its output while enabled");
    a_pad_gpio1: assert property (@(posedge refclk) disable iff (!ext_rst_n) gpio_oe[1] |-> gpio1 === gpio_o[1] )
        else $error("[SVA-FAIL] a_pad_gpio1: GPIO1 pad does not carry its output while enabled");
    a_pad_scl_low: assert property (@(posedge refclk) disable iff (!ext_rst_n) (scl_oe && !scl_o) |-> i2c_scl === 1'b0 )
        else $error("[SVA-FAIL] a_pad_scl_low: SCL not low while the chip pulls it");
    a_pad_sda_low: assert property (@(posedge refclk) disable iff (!ext_rst_n) (sda_oe && !sda_o) |-> i2c_sda === 1'b0 )
        else $error("[SVA-FAIL] a_pad_sda_low: SDA not low while the chip pulls it");
endmodule
bind garuda_chip_top chip_pads_sva u_pads_sva (.*);
`endif
`endif
