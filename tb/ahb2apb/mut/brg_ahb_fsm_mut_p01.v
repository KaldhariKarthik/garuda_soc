// MUTANT P01 (bus plan B2): BRG-1 reverted: a new transfer is accepted only from H_IDLE
// =============================================================================
// GARUDA SoC - Block 6 : AHB-to-APB bridge, AHB side state machine
// brg_ahb_fsm.sv
//
// Spec: GARUDA-AHB2APB-SPEC-001 Sec.7.1, Sec.7.4, Sec.8
//
// IDLE / OK / ERR2 take a transfer: a refused one (window masked or not a
// word) answers ERROR in two cycles (ERR1, ERR2); an allowed one is captured
// (CAPT), sent to the APB side as a toggle (WAIT) and answered when the APB
// side toggles back (OK, or ERR1 for an APB error). While the APB domain is in
// reset the bridge holds ERR2 (HREADYOUT low). On its own (F4, 2026-11-17:
// HAL BADFSM / EXTFSM); ahb2apb_bridge keeps the captured transfer.
// =============================================================================

module brg_ahb_fsm (
    input wire hclk,
    input wire hreset_n,
    input wire prst_ok_i,   // the APB domain is out of reset
    input wire xfer_i,      // an AHB transfer is presented to the bridge
    input wire allowed_i,   // ... to an open window, as a word
    input wire ack_new_i,   // the APB side answered
    input wire apb_err_i,   // ... with an error
    output logic capture_o, // the allowed transfer is captured
    output logic send_o,    // CAPT: the request goes to the APB side
    output logic answer_o,  // WAIT: the APB answer is taken
    output logic hreadyout_o,
    output logic hresp_o
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned HSTATE_W = 32'd3;

    localparam [2:0] H_IDLE = 3'd0, H_CAPT = 3'd1, H_WAIT = 3'd2;
    localparam [2:0] H_OK = 3'd3, H_ERR1 = 3'd4, H_ERR2 = 3'd5;

    reg [HSTATE_W-1:0] hstate;
    logic [HSTATE_W-1:0] hstate_next;

    always_ff @(posedge hclk or negedge hreset_n) begin : p_hstate
        if (!hreset_n) begin
            hstate <= H_IDLE;
        end else begin
            hstate <= hstate_next;
        end
    end

    always_comb begin : c_next
        hstate_next = hstate;
        capture_o = 1'b0;
        send_o = 1'b0;
        answer_o = 1'b0;
        hreadyout_o = 1'b0;
        hresp_o = 1'b0;
        case (hstate)
            H_IDLE, H_OK, H_ERR2: begin
                hreadyout_o = prst_ok_i;
                hresp_o = (hstate == H_ERR2);
                if (!prst_ok_i && hstate == H_ERR2) begin
                    hstate_next = H_ERR2;  // hold the 2nd ERROR cycle
                end else if (xfer_i && hstate == H_IDLE) begin
                    if (!allowed_i) begin
                        hstate_next = H_ERR1;
                    end else begin
                        capture_o = 1'b1;
                        hstate_next = H_CAPT;
                    end
                end else begin
                    hstate_next = H_IDLE;
                end
            end
            H_CAPT: begin
                send_o = 1'b1;
                hstate_next = H_WAIT;
            end
            H_WAIT: begin
                if (ack_new_i) begin
                    answer_o = 1'b1;
                    hstate_next = apb_err_i ? H_ERR1 : H_OK;
                end
            end
            H_ERR1: begin
                hresp_o = 1'b1;
                hstate_next = H_ERR2;
            end
            default: begin
                hstate_next = H_IDLE;
            end
        endcase
    end

endmodule
