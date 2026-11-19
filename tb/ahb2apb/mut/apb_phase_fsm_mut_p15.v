// MUTANT P15 (bus plan B2): a second acknowledge toggle after DONE (one request, two responses)
// =============================================================================
// GARUDA SoC - Block 6 : AHB-to-APB bridge, APB phase state machine
// apb_phase_fsm.sv
//
// Spec: GARUDA-AHB2APB-SPEC-001 Sec.7.2, Sec.7.3
//
// One APB transfer: IDLE -> SETUP -> ACCESS (waits out the window's divider,
// then PREADY or the timeout) -> DONE (one idle pclk) -> IDLE. On its own (F4,
// 2026-11-17: HAL BADFSM / EXTFSM); ahb2apb_apb_fsm keeps the counters, PSEL,
// PENABLE and the captured answer, and acts on the events named here.
// =============================================================================

module apb_phase_fsm (
    input wire pclk,
    input wire preset_n,
    input wire new_req_i,  // a request toggle not yet seen
    input wire div_zero_i, // the divider count has run out
    input wire pready_i,   // the selected window's PREADY
    input wire to_last_i,  // the timeout count is at its last value
    output logic start_o,  // IDLE: the request is taken (SETUP next)
    output logic arm_o,    // SETUP: PENABLE rises, the counters load
    output logic div_dec_o,  // ACCESS: the divider counts down
    output logic done_ok_o,  // ACCESS: PREADY ends the transfer
    output logic done_to_o,  // ACCESS: the timeout ends it
    output logic to_inc_o    // ACCESS: the timeout counts up
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned STATE_W = 32'd2;

    localparam [1:0] P_IDLE = 2'd0, P_SETUP = 2'd1, P_ACCESS = 2'd2;
    localparam [1:0] P_DONE = 2'd3;

    reg [STATE_W-1:0] state;
    logic [STATE_W-1:0] state_next;

    always_ff @(posedge pclk or negedge preset_n) begin : p_state
        if (!preset_n) begin
            state <= P_IDLE;
        end else begin
            state <= state_next;
        end
    end

    always_comb begin : c_next
        state_next = state;
        start_o = 1'b0;
        arm_o = 1'b0;
        div_dec_o = 1'b0;
        done_ok_o = 1'b0;
        done_to_o = 1'b0;
        to_inc_o = 1'b0;
        case (state)
            P_IDLE: begin
                if (new_req_i) begin
                    start_o = 1'b1;
                    state_next = P_SETUP;
                end
            end
            P_SETUP: begin
                arm_o = 1'b1;
                state_next = P_ACCESS;
            end
            P_ACCESS: begin
                if (!div_zero_i) begin
                    div_dec_o = 1'b1;
                end else if (pready_i) begin
                    done_ok_o = 1'b1;
                    state_next = P_DONE;
                end else if (to_last_i) begin
                    done_to_o = 1'b1;
                    state_next = P_DONE;
                end else begin
                    to_inc_o = 1'b1;
                end
            end
            default: begin  // P_DONE: one idle pclk
                done_ok_o = 1'b1;
                state_next = P_IDLE;
            end
        endcase
    end

endmodule
