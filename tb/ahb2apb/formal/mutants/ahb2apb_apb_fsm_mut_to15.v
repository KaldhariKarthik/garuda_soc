// MUTANT to15 (bus plan B2 negative control): timeout one sample early (15)
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
    parameter integer TIMEOUT = 32'd16
)(
    input wire pclk,
    input wire preset_n,
    input wire req_tgl_i,
    input wire [APB_WIN_W-1:0] win_i,
    input wire [PADDR_W-1:0] addr_i,
    input wire write_i,
    input wire [WORD_W-1:0] wdata_i,
    output reg ack_tgl_o,
    output reg err_o,
    output reg [WORD_W-1:0] rdata_o,
    output reg [APB_NWIN-1:0] psel_o,
    output reg penable_o,
    output wire pwrite_o,
    output wire [PADDR_W-1:0] paddr_o,
    output wire [WORD_W-1:0] pwdata_o,
    input wire [WORD_W-1:0] prdata_sel_i,
    input wire pready_sel_i,
    input wire pslverr_sel_i
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned DIV_LOAD_W = 32'd3;
    localparam int unsigned STATE_W = 32'd2;
    localparam int unsigned DIV_CNT_W = 32'd3;
    localparam int unsigned TO_CNT_W = 32'd5;

    localparam [1:0] P_IDLE = 2'd0, P_SETUP = 2'd1, P_ACCESS = 2'd2, P_DONE
        = 2'd3;

    reg  [STATE_W-1:0] state;
    reg        req_seen;
    reg  [DIV_CNT_W-1:0] div_cnt;
    reg  [TO_CNT_W-1:0] to_cnt;

    wire [DIV_SEL_W-1:0] div_sel
        = (win_i < 4'd12) ? APB_DIV[2*win_i +: 2] : 2'b00;
    // 0,1,3,7 extra cycles
    wire [DIV_LOAD_W-1:0] div_load = (3'd1 << div_sel) - 3'd1;

    // Address, direction and write data come straight from the stable capture.
    assign pwrite_o = write_i;
    assign paddr_o  = addr_i;
    assign pwdata_o = write_i ? wdata_i : 32'd0;

    always_ff @(posedge pclk or negedge preset_n) begin : p_state
        if (!preset_n) begin
            state <= P_IDLE;
            req_seen <= 1'b0;
            ack_tgl_o <= 1'b0;
            err_o <= 1'b0;
            rdata_o <= 32'd0;
            psel_o <= 12'd0;
            penable_o <= 1'b0;
            div_cnt <= 3'd0;
            to_cnt <= 5'd0;
        end else begin
            case (state)
                P_IDLE: begin
                    if (req_tgl_i != req_seen) begin
                        req_seen <= req_tgl_i;
                        psel_o <= 12'd1 << win_i;
                        state <= P_SETUP;
                    end
                end
                P_SETUP: begin
                    penable_o <= 1'b1;
                    div_cnt <= div_load;
                    to_cnt <= 5'd0;
                    state <= P_ACCESS;
                end
                P_ACCESS: begin
                    if (div_cnt != 3'd0) begin
                        div_cnt <= div_cnt - 3'd1;
                    end else if (pready_sel_i) begin
                        rdata_o <= prdata_sel_i;
                        err_o <= pslverr_sel_i;
                        psel_o <= 12'd0;
                        penable_o <= 1'b0;
                        ack_tgl_o <= ~ack_tgl_o;
                        state <= P_DONE;
                    end else if (to_cnt == TIMEOUT - 2) begin
                        rdata_o <= 32'd0;
                        err_o <= 1'b1;  // timeout
                        psel_o <= 12'd0;
                        penable_o <= 1'b0;
                        ack_tgl_o <= ~ack_tgl_o;
                        state <= P_DONE;
                    end else begin
                        to_cnt <= to_cnt + 5'd1;
                    end
                end
                default: state <= P_IDLE;  // P_DONE: one idle pclk
            endcase
        end
    end

endmodule
