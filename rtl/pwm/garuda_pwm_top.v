`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 20 : PWM (4 ESC outputs)
// garuda_pwm_top.v - register file over garuda_pwm_core
//
// Spec: GARUDA-PWM-SPEC-001 Rev 1.0; rulings D-17, D-21.
//
// In-house, not adapted (D-22 note 1): see garuda_pwm_core.v for why.
//
// The register file is GARUDA's own, so it uses the house layout - word
// offsets, the D-21 tail at 0xFE0 - with no inherited quirks.
// =============================================================================

module garuda_pwm_top #(
    parameter [7:0]   BLOCK_NUM = 8'd20,
    parameter integer NCH       = 4
)(
    input  wire        pclk_i,
    input  wire        preset_n_i,

    // ---- APB slave, window 8 -------------------------------------------------
    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [11:0] paddr_i,
    input  wire [31:0] pwdata_i,
    output wire [31:0] prdata_o,
    output wire        pready_o,
    output wire        pslverr_o,

    // ---- CLIC ID 21 (no DMA channel) -----------------------------------------
    output wire        irq_o,

    // ---- pins ------------------------------------------------------------------
    output wire [NCH-1:0] pwm_o
);

    localparam [11:0] A_PRESCALE = 12'h000, A_PERIOD = 12'h004,
                      A_CTRL     = 12'h008, A_STATUS = 12'h00C,
                      A_DUTY0    = 12'h010;
    localparam [11:0] IP_LIMIT = 12'h020;   // 0x00..0x1C

    wire        ip_psel, ip_penable, ip_pwrite;
    wire [11:0] ip_paddr;
    wire [31:0] ip_pwdata;
    wire [1:0]  dmactl;

    wire wr_hit = ip_psel & ip_penable & ip_pwrite;

    // =========================================================================
    // Registers
    // =========================================================================
    reg [15:0] prescale_q, period_q;
    reg        en_q;
    reg [NCH-1:0] ch_en_q;
    reg [15:0] duty_q [0:NCH-1];

    wire [NCH*16-1:0] duty_flat;
    genvar g;
    generate for (g = 0; g < NCH; g = g + 1) begin : g_flat
        assign duty_flat[16*g +: 16] = duty_q[g];
    end endgenerate

    integer k;
    always @(posedge pclk_i or negedge preset_n_i) begin
        if (!preset_n_i) begin
            prescale_q <= 16'd0;
            period_q   <= 16'd0;
            en_q       <= 1'b0;                 // motors off out of reset
            ch_en_q    <= {NCH{1'b0}};
            for (k = 0; k < NCH; k = k + 1) duty_q[k] <= 16'd0;
        end else if (wr_hit) begin
            case (ip_paddr)
                A_PRESCALE: prescale_q <= pwdata_i[15:0];
                A_PERIOD:   period_q   <= pwdata_i[15:0];
                A_CTRL:     begin
                    en_q    <= pwdata_i[0];
                    ch_en_q <= pwdata_i[NCH+3:4];
                end
                default: begin
                    for (k = 0; k < NCH; k = k + 1)
                        if (ip_paddr == (A_DUTY0 + 12'(4*k)))
                            duty_q[k] <= pwdata_i[15:0];
                end
            endcase
        end
    end

    // =========================================================================
    // The timing core
    // =========================================================================
    wire [NCH-1:0] clamp;
    wire           wrap;
    wire [15:0]    count;

    garuda_pwm_core #(.NCH(NCH)) u_core (
        .clk_i(pclk_i), .rst_n_i(preset_n_i),
        .en_i(en_q), .ch_en_i(ch_en_q),
        .prescale_i(prescale_q), .period_i(period_q), .duty_i(duty_flat),
        .pwm_o(pwm_o), .wrap_o(wrap), .clamp_o(clamp), .count_o(count));

    // =========================================================================
    // Events (D-21): [0] period boundary, [1] a duty was clamped
    // =========================================================================
    wire [1:0] evt;
    assign evt[0] = wrap;
    assign evt[1] = |clamp;

    // =========================================================================
    // Read mux
    // =========================================================================
    reg [31:0] reg_rdata;
    always @(*) begin
        reg_rdata = 32'd0;
        case (ip_paddr)
            A_PRESCALE: reg_rdata = {16'd0, prescale_q};
            A_PERIOD:   reg_rdata = {16'd0, period_q};
            A_CTRL:     reg_rdata = {{(28-NCH){1'b0}}, ch_en_q, 3'd0, en_q};
            A_STATUS:   reg_rdata = {{(12-NCH){1'b0}}, clamp, count};
            default: begin
                for (k = 0; k < NCH; k = k + 1)
                    if (ip_paddr == (A_DUTY0 + 12'(4*k)))
                        reg_rdata = {16'd0, duty_q[k]};
            end
        endcase
    end

    garuda_apb_shim #(
        .N_EVT(2), .SYNC_W(1), .SYNC_RESET(8'h00), .IP_LIMIT(IP_LIMIT),
        .ADDR_SHIFT(0), .BLOCK_NUM(BLOCK_NUM), .BLOCK_REV(8'd1)
    ) u_shim (
        .pclk_i(pclk_i), .preset_n_i(preset_n_i),
        .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i),
        .paddr_i(paddr_i), .pwdata_i(pwdata_i), .prdata_o(prdata_o),
        .pready_o(pready_o), .pslverr_o(pslverr_o),
        .ip_psel_o(ip_psel), .ip_penable_o(ip_penable), .ip_pwrite_o(ip_pwrite),
        .ip_paddr_o(ip_paddr), .ip_pwdata_o(ip_pwdata), .ip_prdata_i(reg_rdata),
        .ip_pready_i(1'b1),
        .evt_i(evt), .irq_o(irq_o),
        .rx_avail_i(1'b0), .tx_space_i(1'b0),        // no DMA channel
        .dma_ack_i(1'b0), .dma_req_o(), .dmactl_o(dmactl),
        .pad_async_i(1'b0), .pad_sync_o());

    wire _unused = |{dmactl, ip_pwdata};

endmodule

`default_nettype wire
