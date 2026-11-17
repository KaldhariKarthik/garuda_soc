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

module garuda_i2c_top
    import garuda_pkg::*;
#(
    parameter [7:0] BLOCK_NUM = 8'd15
)(
    input wire pclk,
    input wire preset_n,
    // ---- APB slave, window 2 ------------------------------------------------
    input wire psel_i,
    input wire penable_i,
    input wire pwrite_i,
    input wire [PADDR_W-1:0] paddr_i,
    input wire [WORD_W-1:0] pwdata_i,
    output wire [WORD_W-1:0] prdata_o,
    output wire pready_o,
    output wire pslverr_o,
    // ---- CLIC ID 16 / DMA channel 1 -----------------------------------------
    output wire irq_o,
    output wire dma_req_o,
    input wire dma_ack_i,
    // ---- pins (open drain) --------------------------------------------------
    input wire i2c_scl_i,
    output wire i2c_scl_o,
    output wire i2c_scl_oe,
    input wire i2c_sda_i,
    output wire i2c_sda_o,
    output wire i2c_sda_oe
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned PAD_SYNC_W = 32'd2;
    localparam int unsigned IRQSTAT_CLR_W = 32'd4;
    localparam int unsigned ABORT_W = 32'd3;
    localparam int unsigned EVT_W = 32'd4;
    localparam int unsigned ABORTB_W = 32'd3;

    localparam [11:0] A_PRESCALE = 12'h000, A_CTRL   = 12'h004,
                      A_TXDATA   = 12'h008, A_RXDATA = 12'h00C,
                      A_CMD      = 12'h010, A_STATUS = 12'h014,
                      A_TIMEOUT  = 12'h018;
    localparam [11:0] IP_LIMIT = 12'h020;
    // 0x00 to 0x18; 0x1C is not a register
    localparam [63:0] IP_MAP   = 64'h0000_0000_0000_007F;

    wire ip_psel;
    wire ip_penable;
    wire ip_pwrite;
    wire [PADDR_W-1:0] ip_paddr;
    wire [WORD_W-1:0] ip_pwdata;
    wire [DMACTL_W-1:0]  dmactl;
    wire [PAD_SYNC_W-1:0]  pad_sync;
    wire        scl_sync = pad_sync[0];
    wire        sda_sync = pad_sync[1];

    wire wr_hit = ip_psel & ip_penable & ip_pwrite;

    // =========================================================================
    // Registers
    // =========================================================================
    reg [HALF_W-1:0] prescale_q;
    reg [HALF_W-1:0] timeout_q;
    reg        en_q;
    reg [BYTE_W-1:0]  txdata_q;
    reg [BYTE_W-1:0]  rxdata_q;
    reg        rxvalid_q;
    // sticky status
    reg al_q;
    reg to_q;
    reg rxnack_q;
    reg        tip_q;
    reg c_sta;
    reg c_sto;
    reg c_rd;
    reg c_wr;
    reg c_nack;

    // I2C-6: a command can only be outstanding while the vendored core is
    // running. core_held is ~en_q | (|abort_q) - the core in reset - and while
    // it is true a CMD is not accepted and any command in hand is dropped.
    // Before this, only an ABORT cleared TIP: a plain CTRL.EN = 0 in the middle
    // of a transfer left TIP and the command bits latched with the core in
    // reset, so with TIMEOUT = 0 (its reset value) firmware polling TIP never
    // returned, and the next CTRL.EN = 1 sent the stale START + byte out on the
    // bus unasked. A CMD written while disabled was kept the same way.
    wire       core_held;
    wire       cmd_write = wr_hit & (ip_paddr == A_CMD);
    // I2C-7: a CMD with none of RD, WR and STO has nothing to put on the bus.
    // The vendored byte controller starts only on one of those three, so such a
    // CMD used to set TIP and nothing ever cleared it. It is refused
    // ([N-6.2c]).
    wire       cmd_noop  = cmd_write & ~(|pwdata_i[3:1]);
    // ignored while busy
    wire       cmd_ok    = cmd_write & ~tip_q & ~core_held & ~cmd_noop;

    // vendored core status
    wire core_ack;
    wire core_ackout;
    wire core_busy;
    wire core_al;
    wire [BYTE_W-1:0] core_dout;
    wire scl_oen;
    wire sda_oen;
    wire tail_w1c;
    wire shim_slverr;
    wire to_pulse;
    wire [IRQSTAT_CLR_W-1:0] irqstat_clr;

    // ---- abort: a CTRL.ABORT write, or the timeout expiring -----------------
    //
    // It has to RESET the vendored controllers, not disable them. Dropping
    // their `ena` looks like the gentler option and is in fact dangerous: the
    // bit controller's divider is
    // else if (~|cnt || !ena || scl_sync) begin cnt <= clk_cnt; clk_en <= 1;
    // end so with ena low, clk_en is asserted EVERY cycle and the bit state
    // machine free-runs at pclk instead of at 4x SCL - sprinting through the
    // rest of a transfer and toggling the pins at 125 MHz. Its state machine
    // returns to idle only on !nReset or on arbitration loss.
    //
    // So ena is tied high and nReset holds the core in reset whenever the block
    // is disabled or aborting. That also makes CTRL.EN = 0 a clean state rather
    // than a free-running one.
    //
    // The core's asynchronous reset comes straight from ONE flop, i2c_rst_q -
    // the CRG-2 rule. It used to be `preset_n_i & en_q & ~(|abort_q)`: flops
    // behind it, but an AND and a 3-input OR in the reset path, and abort_q is
    // a down-counter whose 4->3 and 2->1 steps move bits in opposite
    // directions, so the OR could glitch and release the reset mid-abort (HAL
    // GLTASR, BUGS_HISTORY.md I2C-5). The flop is loaded from the NEXT values
    // of en_q and abort_q, so it changes in the same cycle the old expression
    // did.
    wire abort_req = (wr_hit & (ip_paddr == A_CTRL) & pwdata_i[1]) |to_pulse;
    reg  [ABORTB_W-1:0] abort_q;
    wire [ABORT_W-1:0] abort_d   = abort_req  ? 3'd4            :
                           (|abort_q) ? abort_q - 3'd1  : 3'd0;
    wire       en_d      = (wr_hit & (ip_paddr == A_CTRL)) ? pwdata_i[0] : en_q;
    reg        i2c_rst_q;
    wire       i2c_rst_n = i2c_rst_q;
    assign     core_held  = ~i2c_rst_q;

    always_ff @(posedge pclk or negedge preset_n) begin : p_ic_rst
        if (!preset_n) begin
            i2c_rst_q <= 1'b0;
        end else begin
            i2c_rst_q <= en_d & ~(|abort_d);
        end
    end

    // =========================================================================
    // Bus timeout ([N-7.5]). Counts pclk while a command is outstanding; a
    // slave stretching SCL freezes the vendored divider, not this counter.
    // =========================================================================
    reg  [HALF_W-1:0] tocnt_q;
    assign to_pulse = tip_q & (timeout_q != 16'd0) & (tocnt_q == 16'd1);

    always_ff @(posedge pclk or negedge preset_n) begin : p_tocnt
        if (!preset_n) begin
            tocnt_q <= 16'd0;
            abort_q <= 3'd0;
        end else begin
            if (!tip_q) begin
                tocnt_q <= timeout_q;
            end else if (tocnt_q != 16'd0) begin
                tocnt_q <= tocnt_q - 16'd1;
            end
            abort_q <= abort_d;
        end
    end

    // =========================================================================
    // Register file
    // =========================================================================
    always_ff @(posedge pclk or negedge preset_n) begin : p_prescale
        if (!preset_n) begin
            prescale_q <= 16'd0;
            timeout_q <= 16'd0;
            en_q <= 1'b0;
            txdata_q <= 8'd0;
            rxdata_q <= 8'd0;
            rxvalid_q <= 1'b0;
            al_q <= 1'b0;
            to_q <= 1'b0;
            rxnack_q <= 1'b0;
            tip_q <= 1'b0;
            c_sta <= 1'b0;
            c_sto <= 1'b0;
            c_rd <= 1'b0;
            c_wr <= 1'b0;
            c_nack <= 1'b0;
        end else begin
            if (wr_hit) begin
                case (ip_paddr)
                    // I2C-10 (ruling D-32, 2026-11-04): PRESCALE and TIMEOUT
                    // are ignored while TIP is set; a mid-transfer write used
                    // to change the bit timing inside a bit, or disable the
                    // timeout already running (R-8). CTRL stays writable: EN =
                    // 0 and ABORT are the specified ways to stop ([N-6.3]).
                    A_PRESCALE: begin
                        if (!tip_q) begin
                            prescale_q <= pwdata_i[15:0];
                        end
                    end
                    A_CTRL: en_q <= pwdata_i[0];
                    A_TXDATA: txdata_q <= pwdata_i[7:0];
                    A_TIMEOUT: begin
                        if (!tip_q) begin
                            timeout_q <= pwdata_i[15:0];
                        end
                    end
                    default: begin
                    end
                endcase
            end
            // CMD is write-only and self-clearing: the bits are handed to the
            // byte controller for exactly one transfer.
            if (cmd_ok) begin
                c_sta <= pwdata_i[0];
                c_sto <= pwdata_i[1];
                c_rd <= pwdata_i[2];
                c_wr <= pwdata_i[3];
                c_nack <= pwdata_i[4];
                tip_q <= 1'b1;
            end else if (core_ack) begin
                c_sta <= 1'b0;
                c_sto <= 1'b0;
                c_rd <= 1'b0;
                c_wr <= 1'b0;
                tip_q <= 1'b0;
                if (c_rd) begin
                    rxdata_q <= core_dout;
                    rxvalid_q <= 1'b1;
                end
                if (c_wr) begin
                    rxnack_q <= core_ackout;  // 1 = the slave did not ACK
                end
            end else if (core_al | core_held) begin
                // arbitration loss, abort and disable (I2C-6) all return the
                // core to idle with no cmd_ack, so TIP has to be cleared here
                // or firmware hangs
                c_sta <= 1'b0;
                c_sto <= 1'b0;
                c_rd <= 1'b0;
                c_wr <= 1'b0;
                tip_q <= 1'b0;
            end
            // reading RXDATA consumes the byte
            if (ip_psel &ip_penable &~ip_pwrite &(ip_paddr == A_RXDATA)) begin
                rxvalid_q <= 1'b0;
            end
            // the sticky status bits clear with their interrupt bits, so
            // firmware has one place to acknowledge a fault rather than two
            if (irqstat_clr[1]) begin
                al_q <= 1'b0;
            end
            if (irqstat_clr[2]) begin
                to_q <= 1'b0;
            end
            // I2C-9: the event is written after the clear, so that an event in
            // the cycle of its own clear is kept, as it is in IRQSTAT (the
            // shim). Before, the clear came last: STATUS lost a fault IRQSTAT
            // still showed.
            if (core_al) begin
                al_q <= 1'b1;
            end
            if (to_pulse) begin
                to_q <= 1'b1;
            end
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
    reg core_ack_q;
    reg was_wr_q;
    reg nacked_q;
    always_ff @(posedge pclk or negedge preset_n) begin : p_core_ack
        if (!preset_n) begin
            core_ack_q <= 1'b0;
            was_wr_q <= 1'b0;
            nacked_q <= 1'b0;
        end else begin
            core_ack_q <= core_ack;
            if (core_ack) begin
                was_wr_q <= c_wr;
                nacked_q <= core_ackout;
            end
        end
    end

    wire [EVT_W-1:0] evt;
    assign evt[0] = core_ack_q;  // transfer complete
    assign evt[1] = core_al;  // arbitration lost
    assign evt[2] = to_pulse;  // bus timeout
    assign evt[3] = core_ack_q & was_wr_q & nacked_q;  // NACK on a written byte

    // =========================================================================
    // Read mux for our own registers
    // =========================================================================
    wire [WORD_W-1:0] reg_rdata =
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
    wire cmd_busy_err = (cmd_write & tip_q) | cmd_noop;

    garuda_apb_shim #(
        .N_EVT(4), .SYNC_W(2), .SYNC_RESET(8'h03), .IP_LIMIT(IP_LIMIT),
            .IP_MAP(IP_MAP),
        .ADDR_SHIFT(0), .BLOCK_NUM(BLOCK_NUM), .BLOCK_REV(8'd1)
    ) u_shim (
        .pclk(pclk), .preset_n(preset_n),
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
    wire core_scl_o;
    wire core_sda_o;

    i2c_byte_ctrl u_byte (
        .pclk(pclk), .i2c_rst_n(i2c_rst_n), .ena(1'b1),
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
