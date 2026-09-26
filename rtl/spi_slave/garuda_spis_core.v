`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 14 : SPI slave shift engine
// garuda_spis_core.v - oversampled in pclk. No second clock domain.
//
// Spec: GARUDA-SPIS-SPEC-001 Rev 1.0 [N-7.1], [N-7.2], [N-7.3].
//
// -----------------------------------------------------------------------------
// WHY THERE IS NO sclk DOMAIN HERE
// -----------------------------------------------------------------------------
// An SPI slave's shift clock comes from the other end of the wire, so the
// obvious implementation clocks the shifter on sclk and hands bytes across to
// pclk through an asynchronous FIFO. This does not do that.
//
// GARUDA-DEBUG-SPEC-001 [N-7.16] says the JTAG dmi_cdc crossing is the ONLY
// asynchronous crossing in the chip. That sentence is worth a lot at signoff -
// one CDC to constrain, review and defend - and adding a second on a
// peripheral to save a few flops spends it. So sclk, mosi and cs_n arrive
// already synchronised (the shim's two flops) and this block oversamples them.
//
// The price is a maximum SCLK: the half period must be at least three pclk for
// an edge to be seen reliably, so SCLK <= pclk/6 = 20.8 MHz, specified as
// 20 MHz ([N-7.1a]). It scales with DIVSEL ([N-7.1b]).
//
// Mode 0: sclk idles low, mosi sampled on the RISING edge, miso launched on
// the FALLING edge, MSB first, 8 bits ([N-7.2]).
// =============================================================================

module garuda_spis_core (
    input  wire       pclk_i,
    input  wire       preset_n_i,

    input  wire       en_i,            // CTRL.EN

    // already synchronised by the shim
    input  wire       sclk_s_i,
    input  wire       mosi_s_i,
    input  wire       cs_n_s_i,

    output wire       miso_o,
    output wire       miso_oe_o,

    input  wire [7:0] txdata_i,        // loaded at the start of each byte

    output reg  [7:0] rx_byte_o,
    output reg        rx_push_o,       // one pclk per completed byte
    output wire       cs_active_o,
    output reg        cs_rise_o,       // one pclk, end of packet
    output reg        cs_fall_o        // one pclk, start of packet
);

    // ---- edge detection on the synchronised inputs ---------------------------
    reg sclk_q, cs_n_q;
    always @(posedge pclk_i or negedge preset_n_i)
        if (!preset_n_i) begin sclk_q <= 1'b0; cs_n_q <= 1'b1; end
        else             begin sclk_q <= sclk_s_i; cs_n_q <= cs_n_s_i; end

    wire sclk_rise = ~sclk_q &  sclk_s_i;
    wire sclk_fall =  sclk_q & ~sclk_s_i;

    assign cs_active_o = ~cs_n_s_i & en_i;

    always @(posedge pclk_i or negedge preset_n_i)
        if (!preset_n_i) begin cs_fall_o <= 1'b0; cs_rise_o <= 1'b0; end
        else begin
            cs_fall_o <=  cs_n_q & ~cs_n_s_i & en_i;
            cs_rise_o <= ~cs_n_q &  cs_n_s_i & en_i;
        end

    // ---- receive shifter -------------------------------------------------------
    // The bit counter is cleared on every cs_n falling edge, so a packet always
    // starts byte-aligned whatever preceded it ([N-7.3]).
    reg [7:0] rx_sh;
    reg [2:0] bitcnt;

    always @(posedge pclk_i or negedge preset_n_i) begin
        if (!preset_n_i) begin
            rx_sh     <= 8'd0;
            bitcnt    <= 3'd0;
            rx_byte_o <= 8'd0;
            rx_push_o <= 1'b0;
        end else begin
            rx_push_o <= 1'b0;

            if (!cs_active_o) begin
                // Deselected: hold the shifter cleared. A partial byte left by
                // a short packet is DISCARDED, never pushed - a truncated
                // ESP-NOW frame must not look like a valid short one
                // ([N-7.3a]).
                bitcnt <= 3'd0;
                rx_sh  <= 8'd0;
            end else if (sclk_rise) begin
                rx_sh  <= {rx_sh[6:0], mosi_s_i};
                bitcnt <= bitcnt + 3'd1;
                if (bitcnt == 3'd7) begin
                    rx_byte_o <= {rx_sh[6:0], mosi_s_i};
                    rx_push_o <= 1'b1;
                end
            end
        end
    end

    // ---- transmit shifter --------------------------------------------------------
    // Loaded from txdata_i at the start of each byte and advanced on the
    // falling edge, so the bit is stable across the master's sampling edge.
    reg [7:0] tx_sh;

    always @(posedge pclk_i or negedge preset_n_i) begin
        if (!preset_n_i) begin
            tx_sh <= 8'd0;
        end else if (cs_fall_o) begin
            tx_sh <= txdata_i;                       // new packet: first byte
        end else if (cs_active_o && sclk_fall) begin
            if (bitcnt == 3'd0) tx_sh <= {txdata_i[6:0], 1'b0};  // next byte
            else                tx_sh <= {tx_sh[6:0], 1'b0};
        end
    end

    // MSB first. Driven only while selected and enabled: a slave that drives
    // MISO when it is not selected is a contention fault on a shared bus
    // ([N-9.2]).
    assign miso_o    = tx_sh[7];
    assign miso_oe_o = cs_active_o;

endmodule

`default_nettype wire
