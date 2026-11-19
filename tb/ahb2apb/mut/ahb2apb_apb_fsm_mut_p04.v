// MUTANT P04 (bus plan B2): timeout one sample early (15)
// =============================================================================
// GARUDA SoC - Block 8 : APB3 master state machine (pclk)
// ahb2apb_apb_fsm.v
//
// Spec: GARUDA-AHB2APB-SPEC-001 Sec.7.1 (IDLE->SETUP->ACCESS->DONE), Sec.7.3
//       (per-window APB_DIV), Sec.7.5 (16-pclk timeout)
//
// Inputs from the hclk side (win/addr/write/wdata, req toggle) are hclk flops
// that are stable whenever this FSM samples them; the paths are synchronous
// (pclk edges are hclk edges). A request is a change of req_tgl_i; completion
// is signalled by flipping ack_tgl_o, with err_o/rdata_o already valid.
//
// ACCESS: PENABLE is held for (1 << APB_DIV[win]) pclk cycles before PREADY is
// first sampled ([N-7.9]); after that the timeout counts pclk cycles with
// PREADY low and abandons the transfer on the 16th ([N-7.15]).
// =============================================================================

module ahb2apb_apb_fsm
    import garuda_pkg::*;
#(
    parameter [23:0] APB_DIV = 24'h000000,
    parameter int unsigned TIMEOUT = 32'd16
)(
    input wire pclk,
    input wire preset_n,
    input wire req_tgl_i,
    input wire [APB_WIN_W-1:0] win_i,
    output reg ack_tgl_o,
    output reg err_o,
    output reg [WORD_W-1:0] rdata_o,
    output reg [APB_NWIN-1:0] psel_o,
    output reg penable_o,
    input wire [WORD_W-1:0] prdata_sel_i,
    input wire pready_sel_i,
    input wire pslverr_sel_i
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned DIV_LOAD_W = 32'd3;
    localparam int unsigned DIV_CNT_W = 32'd3;
    localparam int unsigned TO_CNT_W = 32'd5;
    localparam int unsigned WIN_SLOTS = 32'd16;  // 2**APB_WIN_W

    reg        req_seen;
    reg  [DIV_CNT_W-1:0] div_cnt;
    reg  [TO_CNT_W-1:0] to_cnt;

    // F4 (2026-11-17): the window's divider and select from arrays and
    // compares, not from a product index or a shift (HAL INDXOP, SHFTNC); the
    // windows past 11 have no divider (0)
    wire [DIV_SEL_W-1:0] div_a [0:WIN_SLOTS-1];
    genvar k;
    generate for (k = 0; k < WIN_SLOTS; k = k + 1) begin : g_win
        if (k < 12) begin : g_div
            assign div_a[k] = APB_DIV[2*k +: 2];
        end else begin : g_none
            assign div_a[k] = 2'b00;
        end
    end endgenerate
    wire [DIV_SEL_W-1:0] div_sel = div_a[win_i];
    // extra pclk cycles: 0, 1, 3, 7
    wire [DIV_LOAD_W-1:0] div_load = (div_sel == 2'd0) ? 3'd0 :
                                     (div_sel == 2'd1) ? 3'd1 :
                                     (div_sel == 2'd2) ? 3'd3 : 3'd7;
    wire [APB_NWIN-1:0] win_hot;
    generate for (k = 0; k < APB_NWIN; k = k + 1) begin : g_hot
        assign win_hot[k] = (win_i == APB_WIN_W'(k));
    end endgenerate

    // ---- the transfer's state machine (apb_phase_fsm) -----------------------
    wire start;
    wire arm;
    wire div_dec;
    wire done_ok;
    wire done_to;
    wire to_inc;
    wire new_req = (req_tgl_i != req_seen);
    wire div_zero = (div_cnt == '0);
    wire to_last = (to_cnt == TO_CNT_W'(TIMEOUT - 32'd2));
    apb_phase_fsm u_phase (
        .pclk(pclk), .preset_n(preset_n), .new_req_i(new_req),
        .div_zero_i(div_zero), .pready_i(pready_sel_i), .to_last_i(to_last),
        .start_o(start), .arm_o(arm), .div_dec_o(div_dec),
        .done_ok_o(done_ok), .done_to_o(done_to), .to_inc_o(to_inc)
    );
    wire done = done_ok || done_to;

    // F4: one process per register (HAL MULNBA, BADFSM)
    always_ff @(posedge pclk or negedge preset_n) begin : p_req_seen
        if (!preset_n) begin
            req_seen <= 1'b0;
        end else if (start) begin
            req_seen <= req_tgl_i;
        end
    end

    always_ff @(posedge pclk or negedge preset_n) begin : p_psel
        if (!preset_n) begin
            psel_o <= 12'd0;
            penable_o <= 1'b0;
        end else if (start) begin
            psel_o <= win_hot;
        end else if (arm) begin
            penable_o <= 1'b1;
        end else if (done) begin
            psel_o <= 12'd0;
            penable_o <= 1'b0;
        end
    end

    always_ff @(posedge pclk or negedge preset_n) begin : p_cnt
        if (!preset_n) begin
            div_cnt <= 3'd0;
            to_cnt <= 5'd0;
        end else if (arm) begin
            div_cnt <= div_load;
            to_cnt <= 5'd0;
        end else if (div_dec) begin
            div_cnt <= DIV_CNT_W'(div_cnt - 3'd1);
        end else if (to_inc) begin
            to_cnt <= TO_CNT_W'(to_cnt + 5'd1);
        end
    end

    // the answer: the window's read data and PSLVERR, or a timeout error
    always_ff @(posedge pclk or negedge preset_n) begin : p_answer
        if (!preset_n) begin
            rdata_o <= 32'd0;
            err_o <= 1'b0;
            ack_tgl_o <= 1'b0;
        end else if (done) begin
            rdata_o <= done_ok ? prdata_sel_i : 32'd0;
            err_o <= done_ok ? pslverr_sel_i : 1'b1;
            ack_tgl_o <= ~ack_tgl_o;
        end
    end

endmodule
