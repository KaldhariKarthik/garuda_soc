// =============================================================================
// GARUDA SoC - Block 9 : DMA engine beat state machine
// dma_eng_fsm.sv
//
// Spec: GARUDA-DMA-SPEC-001 Rev 3.0 Sec.7.2, Sec.7.4
//
// The state machine of one beat (read, then write), on its own (F4,
// 2026-11-17: HAL BADFSM / EXTFSM ask for the state register and one
// combinational block that forms the next state and the outputs, with no
// datapath beside them). dma_engine holds the datapath and the AHB outputs and
// acts on the events this block names.
//
//   IDLE -> RA   a grant is taken
//   RA   -> RD   the read address goes out (both addresses are allowed)
//   RA   -> IDLE a forbidden or misaligned SAR (read) or DAR (write) address
//   RD   -> WA   the read data phase ends OKAY
//   RD   -> IDLE the read data phase ends in ERROR
//   WA   -> WD   the write address goes out
//   WD   -> IDLE the write data phase ends (OKAY or ERROR)
//
// In RD and WD the address phase is pending while HTRANS is NONSEQ
// (addr_pend_i); HREADY then accepts it, and the next HREADY ends the data
// phase.
// =============================================================================

module dma_eng_fsm (
    input wire hclk,
    input wire hreset_n,
    input wire take_i,      // a grant is taken (only in IDLE)
    input wire sar_bad_i,   // the beat's source address is refused
    input wire dar_bad_i,   // the beat's destination address is refused
    input wire addr_pend_i, // an address phase is on the bus (HTRANS[1])
    input wire hready_i,
    input wire hresp_i,
    output logic idle_o,    // no beat in progress
    output logic addr_ok_o, // RA: the read address goes out
    output logic ra_rd_err_o,  // RA: the source address is refused
    output logic ra_wr_err_o,  // RA: the destination address is refused
    output logic wa_o,      // WA: the write address goes out
    output logic rd_acc_o,  // RD: the read address is accepted
    output logic wd_acc_o,  // WD: the write address is accepted
    output logic rd_end_o,  // RD: the read data phase ends
    output logic wd_end_o   // WD: the write data phase ends
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned ST_W = 32'd3;

    localparam [2:0] E_IDLE = 3'd0, E_RA = 3'd1, E_RD = 3'd2, E_WA = 3'd3;
    localparam [2:0] E_WD = 3'd4;

    reg [ST_W-1:0] st;
    logic [ST_W-1:0] st_next;

    always_ff @(posedge hclk or negedge hreset_n) begin : p_st
        if (!hreset_n) begin
            st <= E_IDLE;
        end else begin
            st <= st_next;
        end
    end

    always_comb begin : c_next
        st_next = st;
        idle_o = 1'b0;
        addr_ok_o = 1'b0;
        ra_rd_err_o = 1'b0;
        ra_wr_err_o = 1'b0;
        wa_o = 1'b0;
        rd_acc_o = 1'b0;
        wd_acc_o = 1'b0;
        rd_end_o = 1'b0;
        wd_end_o = 1'b0;
        case (st)
            E_IDLE: begin
                idle_o = 1'b1;
                if (take_i) begin
                    st_next = E_RA;
                end
            end
            E_RA: begin
                if (sar_bad_i) begin
                    ra_rd_err_o = 1'b1;
                    st_next = E_IDLE;
                end else if (dar_bad_i) begin
                    ra_wr_err_o = 1'b1;
                    st_next = E_IDLE;
                end else begin
                    addr_ok_o = 1'b1;
                    st_next = E_RD;
                end
            end
            E_RD: begin
                if (hready_i) begin
                    if (addr_pend_i) begin
                        rd_acc_o = 1'b1;
                    end else begin
                        rd_end_o = 1'b1;
                        st_next = hresp_i ? E_IDLE : E_WA;
                    end
                end
            end
            E_WA: begin
                wa_o = 1'b1;
                st_next = E_WD;
            end
            E_WD: begin
                if (hready_i) begin
                    if (addr_pend_i) begin
                        wd_acc_o = 1'b1;
                    end else begin
                        wd_end_o = 1'b1;
                        st_next = E_IDLE;
                    end
                end
            end
            default: begin
                st_next = E_IDLE;
            end
        endcase
    end

endmodule
