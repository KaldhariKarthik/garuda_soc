// =============================================================================
// GARUDA SoC - Block 13 : system bus access master state machine
// sba_fsm.sv
//
// Spec: GARUDA-DEBUG-SPEC-001 Sec.6.5
//
// One SINGLE AHB-Lite transfer: IDLE -> ADDR (address phase, until HREADY)
// -> DATA (data phase, until HREADY) -> IDLE. On its own (F4, 2026-11-17: HAL
// BADFSM / EXTFSM); sba_master keeps the AHB outputs and the data.
// =============================================================================

module sba_fsm (
    input wire hclk,
    input wire dm_rst_n,
    input wire start_i,
    input wire hready_i,
    output logic idle_o,   // no transfer
    output logic issue_o,  // IDLE: a transfer starts (the address goes out)
    output logic acc_o,    // ADDR: the address phase is accepted
    output logic end_o     // DATA: the data phase completes
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned ST_W = 32'd2;

    localparam [1:0] S_IDLE = 2'd0, S_ADDR = 2'd1, S_DATA = 2'd2;

    reg [ST_W-1:0] st;
    logic [ST_W-1:0] st_next;

    always_ff @(posedge hclk or negedge dm_rst_n) begin : p_st
        if (!dm_rst_n) begin
            st <= S_IDLE;
        end else begin
            st <= st_next;
        end
    end

    always_comb begin : c_next
        st_next = st;
        idle_o = 1'b0;
        issue_o = 1'b0;
        acc_o = 1'b0;
        end_o = 1'b0;
        case (st)
            S_IDLE: begin
                idle_o = 1'b1;
                if (start_i) begin
                    issue_o = 1'b1;
                    st_next = S_ADDR;
                end
            end
            S_ADDR: begin
                if (hready_i) begin
                    acc_o = 1'b1;
                    st_next = S_DATA;
                end
            end
            default: begin  // S_DATA
                if (hready_i) begin
                    end_o = 1'b1;
                    st_next = S_IDLE;
                end
            end
        endcase
    end

endmodule
