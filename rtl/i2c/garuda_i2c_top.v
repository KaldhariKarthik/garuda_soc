`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 15 : I2C master
// garuda_i2c_top.v - GARUDA register layer over the OpenCores controllers
//
// Spec: GARUDA-I2C-SPEC-001 Rev 1.0; rulings D-21, D-22, D-23.
//
// This block is the exception to "wrap a vendored register file": PULP's
// apb_i2c.sv, which normally sits on these controllers, carries no licence
// header and its repository has no LICENSE file, so it is deliberately not
// vendored (D-22). Only the bit and byte controllers are taken - those carry
// Richard Herveille's notice - and the register file below is GARUDA's.
//
// That makes this the one peripheral whose register map we designed rather
// than inherited: word offsets throughout, no DLAB, no byte addressing, and
// the D-21 tail in its usual place.
//
// Two things the register layer adds that the controllers do not have:
//
//   1. A BUS TIMEOUT. I2C lets a slave hold SCL low to stall the master, and
//      the vendored bit controller honours that by freezing its divider with
//      no upper bound. A confused slave therefore stalls the transfer for
//      ever and firmware polling TIP never returns - a hang, not an error.
//      TIMEOUT counts pclk while TIP is set and abandons the transfer.
//
//   2. OPEN-DRAIN MAPPING. The controllers hardwire scl_o = sda_o = 0 and
//      express everything through *_oen, so this block can only pull a line
//      low or release it. _o stays tied to 0 here for the same reason
//      ([N-9.2]): a line driven high by one master while another pulls it low
//      is a short across a shared bus.
// =============================================================================

module garuda_i2c_top #(
    parameter [7:0] BLOCK_NUM = 8'd15
)(
    input  wire        pclk_i,
    input  wire        preset_n_i,

    // ---- APB slave, window 2 -------------------------------------------------
    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [11:0] paddr_i,
    input  wire [31:0] pwdata_i,
    output wire [31:0] prdata_o,
    output wire        pready_o,
    output wire        pslverr_o,

    // ---- CLIC ID 16 / DMA channel 1 ------------------------------------------
    output wire        irq_o,
    output wire        dma_req_o,
    input  wire        dma_ack_i,

    // ---- pins (open drain) -----------------------------------------------------
    input  wire        i2c_scl_i,
    output wire        i2c_scl_o,
    output wire        i2c_scl_oe,
    input  wire        i2c_sda_i,
    output wire        i2c_sda_o,
    output wire        i2c_sda_oe
);

    localparam [11:0] A_PRESCALE = 12'h000, A_CTRL   = 12'h004,
                      A_TXDATA   = 12'h008, A_RXDATA = 12'h00C,
                      A_CMD      = 12'h010, A_STATUS = 12'h014,
                      A_TIMEOUT  = 12'h018;
    localparam [11:0] IP_LIMIT = 12'h020;

    wire        ip_psel, ip_penable, ip_pwrite;
    wire [11:0] ip_paddr;
    wire [31:0] ip_pwdata;
    wire [1:0]  dmactl;
    wire [1:0]  pad_sync;
    wire        scl_sync = pad_sync[0];
    wire        sda_sync = pad_sync[1];

    wire wr_hit = ip_psel & ip_penable & ip_pwrite;

    // =========================================================================
    // Registers
    // =========================================================================
    reg [15:0] prescale_q, timeout_q;
    reg        en_q;
    reg [7:0]  txdata_q;
    reg [7:0]  rxdata_q;
    reg        rxvalid_q;
    reg        al_q, to_q, rxnack_q;     // sticky status
    reg        tip_q;
    reg        c_sta, c_sto, c_rd, c_wr, c_nack;

    wire       cmd_write = wr_hit & (ip_paddr == A_CMD);
    wire       cmd_ok    = cmd_write & ~tip_q;      // ignored while busy

    // vendored core status
    wire       core_ack, core_ackout, core_busy, core_al;
    wire [7:0] core_dout;
    wire       scl_oen, sda_oen;
    wire       tail_w1c, shim_slverr, to_pulse;
    wire [3:0] irqstat_clr;

    // ---- abort: a CTRL.ABORT write, or the timeout expiring -------------------
    //
    // It has to RESET the vendored controllers, not disable them. Dropping
    // their `ena` looks like the gentler option and is in fact dangerous: the
    // bit controller's divider is
    //     else if (~|cnt || !ena || scl_sync) begin cnt <= clk_cnt; clk_en <= 1; end
    // so with ena low, clk_en is asserted EVERY cycle and the bit state machine
    // free-runs at pclk instead of at 4x SCL - sprinting through the rest of a
    // transfer and toggling the pins at 125 MHz. Its state machine returns to
    // idle only on !nReset or on arbitration loss.
    //
    // So ena is tied high and nReset holds the core in reset whenever the block
    // is disabled or aborting. That also makes CTRL.EN = 0 a clean state rather
    // than a free-running one.
    //
    // abort_q is a FLOP, so this asynchronous reset is driven from register
    // output and not from combinational logic - the CRG-2 rule.
    wire       abort_req = (wr_hit & (ip_paddr == A_CTRL) & pwdata_i[1]) | to_pulse;
    reg  [2:0] abort_q;
    wire       core_rst_n = preset_n_i & en_q & ~(|abort_q);

    // =========================================================================
    // Bus timeout ([N-7.5]). Counts pclk while a command is outstanding; a
    // slave stretching SCL freezes the vendored divider, not this counter.
    // =========================================================================
    reg  [15:0] tocnt_q;
    assign to_pulse = tip_q & (timeout_q != 16'd0) & (tocnt_q == 16'd1);

    always @(posedge pclk_i or negedge preset_n_i) begin
        if (!preset_n_i) begin
            tocnt_q <= 16'd0;
            abort_q <= 3'd0;
        end else begin
            if (!tip_q)                tocnt_q <= timeout_q;
            else if (tocnt_q != 16'd0) tocnt_q <= tocnt_q - 16'd1;

            if (abort_req)             abort_q <= 3'd4;
            else if (|abort_q)         abort_q <= abort_q - 3'd1;
        end
    end

    // =========================================================================
    // Register file
    // =========================================================================
    always @(posedge pclk_i or negedge preset_n_i) begin
        if (!preset_n_i) begin
            prescale_q <= 16'd0;  timeout_q <= 16'd0;  en_q <= 1'b0;
            txdata_q   <= 8'd0;   rxdata_q  <= 8'd0;   rxvalid_q <= 1'b0;
            al_q <= 1'b0;  to_q <= 1'b0;  rxnack_q <= 1'b0;  tip_q <= 1'b0;
            c_sta <= 1'b0; c_sto <= 1'b0; c_rd <= 1'b0; c_wr <= 1'b0; c_nack <= 1'b0;
        end else begin
            if (wr_hit) begin
                case (ip_paddr)
                    A_PRESCALE: prescale_q <= pwdata_i[15:0];
                    A_CTRL:     en_q       <= pwdata_i[0];
                    A_TXDATA:   txdata_q   <= pwdata_i[7:0];
                    A_TIMEOUT:  timeout_q  <= pwdata_i[15:0];
                    default: ;
                endcase
            end

            // CMD is write-only and self-clearing: the bits are handed to the
            // byte controller for exactly one transfer.
            if (cmd_ok) begin
                c_sta  <= pwdata_i[0];
                c_sto  <= pwdata_i[1];
                c_rd   <= pwdata_i[2];
                c_wr   <= pwdata_i[3];
                c_nack <= pwdata_i[4];
                tip_q  <= 1'b1;
            end else if (core_ack) begin
                c_sta <= 1'b0; c_sto <= 1'b0; c_rd <= 1'b0; c_wr <= 1'b0;
                tip_q <= 1'b0;
                if (c_rd) begin
                    rxdata_q  <= core_dout;
                    rxvalid_q <= 1'b1;
                end
                if (c_wr) rxnack_q <= core_ackout;   // 1 = the slave did not ACK
            end else if (core_al | (|abort_q)) begin
                // arbitration loss and abort both return the core to idle with
                // no cmd_ack, so TIP has to be cleared here or firmware hangs
                c_sta <= 1'b0; c_sto <= 1'b0; c_rd <= 1'b0; c_wr <= 1'b0;
                tip_q <= 1'b0;
            end

            if (core_al)  al_q <= 1'b1;
            if (to_pulse) to_q <= 1'b1;

            // reading RXDATA consumes the byte
            if (ip_psel & ip_penable & ~ip_pwrite & (ip_paddr == A_RXDATA))
                rxvalid_q <= 1'b0;

            // the sticky status bits clear with their interrupt bits, so
            // firmware has one place to acknowledge a fault rather than two
            if (irqstat_clr[1]) al_q <= 1'b0;
            if (irqstat_clr[2]) to_q <= 1'b0;
        end
    end

    // The tail's W1C write is visible here so STATUS.AL / STATUS.TIMEOUT clear
    // with their interrupt bits rather than needing a second register.
    assign tail_w1c    = psel_i & penable_i & pwrite_i & (paddr_i == 12'hFE0);
    assign irqstat_clr = tail_w1c ? pwdata_i[3:0] : 4'd0;

    // =========================================================================
    // Events into the shared sticky tail (D-21)
    // =========================================================================
    // core_ack is a one-cycle pulse, and c_wr / core_ackout are cleared or
    // change in that same cycle - so what the event needs is a snapshot taken
    // WITH the pulse, not the live signals one cycle later.
    reg core_ack_q, was_wr_q, nacked_q;
    always @(posedge pclk_i or negedge preset_n_i)
        if (!preset_n_i) begin
            core_ack_q <= 1'b0; was_wr_q <= 1'b0; nacked_q <= 1'b0;
        end else begin
            core_ack_q <= core_ack;
            if (core_ack) begin
                was_wr_q <= c_wr;
                nacked_q <= core_ackout;
            end
        end

    wire [3:0] evt;
    assign evt[0] = core_ack_q;                        // transfer complete
    assign evt[1] = core_al;                           // arbitration lost
    assign evt[2] = to_pulse;                          // bus timeout
    assign evt[3] = core_ack_q & was_wr_q & nacked_q;  // NACK on a written byte

    // =========================================================================
    // Read mux for our own registers
    // =========================================================================
    wire [31:0] reg_rdata =
        (ip_paddr == A_PRESCALE) ? {16'd0, prescale_q}                       :
        (ip_paddr == A_CTRL)     ? {31'd0, en_q}                             :
        (ip_paddr == A_TXDATA)   ? {24'd0, txdata_q}                         :
        (ip_paddr == A_RXDATA)   ? {24'd0, rxdata_q}                         :
        (ip_paddr == A_STATUS)   ? {26'd0, rxvalid_q, to_q, rxnack_q,
                                           al_q, core_busy, tip_q}           :
        (ip_paddr == A_TIMEOUT)  ? {16'd0, timeout_q}                        :
                                   32'd0;

    // A CMD write while a transfer is running is a firmware error, not a queued
    // command: fault it rather than silently drop it ([N-6.2b]).
    wire cmd_busy_err = cmd_write & tip_q;

    garuda_apb_shim #(
        .N_EVT(4), .SYNC_W(2), .SYNC_RESET(8'h03), .IP_LIMIT(IP_LIMIT),
        .ADDR_SHIFT(0), .BLOCK_NUM(BLOCK_NUM), .BLOCK_REV(8'd1)
    ) u_shim (
        .pclk_i(pclk_i), .preset_n_i(preset_n_i),
        .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i),
        .paddr_i(paddr_i), .pwdata_i(pwdata_i), .prdata_o(prdata_o),
        .pready_o(pready_o), .pslverr_o(shim_slverr),
        .ip_psel_o(ip_psel), .ip_penable_o(ip_penable), .ip_pwrite_o(ip_pwrite),
        .ip_paddr_o(ip_paddr), .ip_pwdata_o(ip_pwdata), .ip_prdata_i(reg_rdata),
        .ip_pready_i(1'b1),
        .evt_i(evt), .irq_o(irq_o),
        .rx_avail_i(rxvalid_q),
        .tx_space_i(en_q & ~tip_q),
        .dma_ack_i(dma_ack_i), .dma_req_o(dma_req_o), .dmactl_o(dmactl),
        .pad_async_i({i2c_sda_i, i2c_scl_i}), .pad_sync_o(pad_sync));

    assign pslverr_o = shim_slverr | cmd_busy_err;

    // =========================================================================
    // The vendored controllers
    // =========================================================================
    wire core_scl_o, core_sda_o;

    i2c_master_byte_ctrl u_byte (
        .clk(pclk_i), .nReset(core_rst_n), .ena(1'b1),
        .clk_cnt(prescale_q),
        .start(c_sta), .stop(c_sto), .read(c_rd), .write(c_wr),
        .ack_in(c_nack), .din(txdata_q),
        .cmd_ack(core_ack), .ack_out(core_ackout), .dout(core_dout),
        .i2c_busy(core_busy), .i2c_al(core_al),
        .scl_i(scl_sync), .scl_o(core_scl_o), .scl_oen(scl_oen),
        .sda_i(sda_sync), .sda_o(core_sda_o), .sda_oen(sda_oen));

    // =========================================================================
    // Open drain ([N-9.2]). The core hardwires its *_o to 0 and says everything
    // with *_oen; _o stays 0 here so this block can only pull a line low or
    // release it, never drive it high against another master.
    // =========================================================================
    assign i2c_scl_o  = 1'b0;
    assign i2c_sda_o  = 1'b0;
    assign i2c_scl_oe = ~scl_oen;
    assign i2c_sda_oe = ~sda_oen;

    wire _unused = |{dmactl, ip_pwdata, core_scl_o, core_sda_o, c_nack};

endmodule

`default_nettype wire
