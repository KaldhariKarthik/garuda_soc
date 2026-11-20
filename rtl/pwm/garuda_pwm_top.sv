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

module garuda_pwm_top
    import garuda_pkg::*;
#(
    parameter [7:0]   BLOCK_NUM = 8'd20,
    parameter integer NUM_CHAN       = 32'd4
)(
    input wire pclk,
    input wire preset_n,
    // ---- APB slave, window 8 ------------------------------------------------
    input wire psel_i,
    input wire penable_i,
    input wire pwrite_i,
    input wire [PADDR_W-1:0] paddr_i,
    input wire [WORD_W-1:0] pwdata_i,
    output wire [WORD_W-1:0] prdata_o,
    output wire pready_o,
    output wire pslverr_o,
    // ---- CLIC ID 21 (no DMA channel) ----------------------------------------
    output wire irq_o,
    // ---- pins ---------------------------------------------------------------
    output wire [NUM_CHAN - 1:0] pwm_o
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned EVT_W = 32'd2;

    localparam [11:0] A_PRESCALE = 12'h000, A_PERIOD = 12'h004,
                      A_CTRL     = 12'h008, A_STATUS = 12'h00C,
                      A_DUTY0    = 12'h010;
    // DUTY0..DUTY3 sit at A_DUTY0 | 4k: A_DUTY0 is 16-byte aligned and
    // NUM_CHAN is at most 4, so the offsets need no adder
    localparam [11:0] IP_LIMIT = 12'h020;  // 0x00..0x1C
    // all eight words are registers
    localparam [63:0] IP_MAP   = 64'h0000_0000_0000_00FF;

    wire ip_psel;

    wire wr_hit = ip_psel & penable_i & pwrite_i;

    // =========================================================================
    // Registers
    // =========================================================================
    reg [HALF_W-1:0] prescale_q;
    reg [HALF_W-1:0] period_q;
    reg        en_q;
    reg [NUM_CHAN-1:0] ch_en_q;
    reg [DUTY_W-1:0] duty_q [0:NUM_CHAN-1];

    wire [NUM_CHAN*DUTY_W-1:0] duty_flat;
    genvar g;
    generate for (g = 0; g < NUM_CHAN; g = g + 1) begin : g_flat
        assign duty_flat[16*g +: 16] = duty_q[g];
    end endgenerate

    integer kw;  // write-side loop index only (PWM-3)
    always_ff @(posedge pclk or negedge preset_n) begin : p_prescale
        if (!preset_n) begin
            prescale_q <= 16'd0;
            period_q <= 16'd0;
            en_q <= 1'b0;  // motors off out of reset
            ch_en_q <= {NUM_CHAN {1'b0}};
            for (kw = 0; kw < NUM_CHAN; kw = kw + 1) begin
                duty_q[kw] <= 16'd0;
            end
        end else if (wr_hit) begin
            case (paddr_i)
                A_PRESCALE: prescale_q <= pwdata_i[15:0];
                A_PERIOD: period_q <= pwdata_i[15:0];
                A_CTRL: begin
                    en_q <= pwdata_i[0];
                    ch_en_q <= pwdata_i[NUM_CHAN + 3:4];
                end
                default: begin
                    for (kw = 0; kw < NUM_CHAN; kw = kw + 1) begin
                        if (at12(paddr_i, A_DUTY0 | {8'd0, kw[1:0], 2'b00})) begin
                            duty_q[kw] <= pwdata_i[15:0];
                        end
                    end
                end
            endcase
        end
    end

    // =========================================================================
    // The timing core
    // =========================================================================
    wire [NUM_CHAN-1:0] clamp;
    wire           wrap;
    wire [HALF_W-1:0]    count;

    garuda_pwm_core #(.NUM_CHAN(NUM_CHAN)) u_core (
        .pclk(pclk), .preset_n(preset_n),
        .en_i(en_q), .ch_en_i(ch_en_q),
        .prescale_i(prescale_q), .period_i(period_q), .duty_i(duty_flat),
        .pwm_o(pwm_o), .wrap_o(wrap), .clamp_o(clamp), .count_o(count));

    // =========================================================================
    // Events (D-21): [0] period boundary, [1] a duty was clamped
    // =========================================================================
    wire [EVT_W-1:0] evt;
    assign evt[0] = wrap;
    assign evt[1] = |clamp;

    // =========================================================================
    // Read mux
    // =========================================================================
    // PWM-3: the DUTY read select runs its loop on every evaluation, outside
    // the case. With the loop inside `default:` the index was assigned on one
    // branch only and synthesis inferred a latch for it; it also shared `k`
    // with the write block above, so two processes drove one variable.
    // (F4 2026-11-20: a function, so no process reads a variable another
    // process assigns with blocking assignments, HAL REVROP. The duties are an
    // argument: a continuous assignment is re-evaluated only when its operands
    // change, and a function reading duty_q from the module returned a stale
    // value in simulation, gate_b tb_pwm R-4.)
    function automatic logic [DUTY_W-1:0] duty_of(input logic [11:0] a,
                                                   input logic [DUTY_W-1:0] d [NUM_CHAN]);
        logic [DUTY_W-1:0] r;
        r = 16'd0;
        for (int unsigned kr = 0; kr < NUM_CHAN; kr++) begin
            if (at12(a, A_DUTY0 | {8'd0, 2'(kr), 2'b00})) begin
                r = d[kr];
            end
        end
        return r;
    endfunction
    wire [DUTY_W-1:0] duty_rd = duty_of(paddr_i, duty_q);

    reg [WORD_W-1:0] reg_rdata;
    always_comb begin : c_reg_rdata
        case (paddr_i)
            A_PRESCALE: reg_rdata = {16'd0, prescale_q};
            A_PERIOD: reg_rdata = {16'd0, period_q};
            A_CTRL: reg_rdata = {{(28 - NUM_CHAN) {1'b0}}, ch_en_q, 3'd0, en_q};
            A_STATUS: reg_rdata = {{(16 - NUM_CHAN) {1'b0}}, clamp, count};
            default: reg_rdata = {16'd0, duty_rd};
        endcase
    end

    garuda_apb_shim #(
        .N_EVT(2), .IP_LIMIT(IP_LIMIT),
            .IP_MAP(IP_MAP), .BLOCK_NUM(BLOCK_NUM), .BLOCK_REV(8'd1)
    ) u_shim (
        .pclk(pclk), .preset_n(preset_n),
        .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i),
        .paddr_i(paddr_i), .pwdata_i(pwdata_i), .prdata_o(prdata_o),
        .pready_o(pready_o), .pslverr_o(pslverr_o),
        .ip_psel_o(ip_psel), .ip_prdata_i(reg_rdata),
        .evt_i(evt), .irq_o(irq_o));


endmodule
