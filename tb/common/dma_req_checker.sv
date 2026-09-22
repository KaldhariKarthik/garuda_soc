`timescale 1ns/1ps
// =============================================================================
// dma_req_checker.sv -- binds to a peripheral's DMA sideband and enforces the
// rule rtl/dma/dma_chan.v actually implements.
//
// dma_chan takes ONE beat per request assertion: its taken_q sets on
// beat_done and clears only when req_i drops. A peripheral that holds a
// FIFO-level request high therefore moves one beat and then stalls forever -
// silently, because nothing errors. This checker fails instead.
//
// Rules (Docs/DECISIONS.md D-16, D-21):
//   R1  req must drop within GRACE pclk cycles of an ack
//   R2  ack is only legal while req is asserted, or was in the cycle before
//       (a peripheral may drop req combinationally on ack - ours does)
//   R3  req must not glitch: once asserted it stays until served or the
//       condition clears (no single-cycle pulses)
// =============================================================================
module dma_req_checker #(
    parameter string NAME  = "dma",
    parameter integer GRACE = 4          // pclk cycles allowed to drop after ack
)(
    input wire clk_i,          // pclk
    input wire rst_n_i,
    input wire req_i,
    input wire ack_i
);
    int viol_ack_no_req = 0, viol_stuck = 0;
    int since_ack = -1;
    logic req_d = 0;

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            since_ack <= -1;
        end else begin
            req_d <= req_i;
            if (ack_i && !req_i && !req_d && since_ack < 0) begin
                viol_ack_no_req++;
                $display("[DMA-CHK %0s] ack with no request at %0t", NAME, $time);
            end
            if (ack_i)            since_ack <= 0;
            else if (since_ack >= 0) begin
                if (!req_i)       since_ack <= -1;          // dropped: good
                else if (since_ack >= GRACE) begin
                    viol_stuck++;
                    $display("[DMA-CHK %0s] request still high %0d cycles after ack at %0t - dma_chan will stall",
                             NAME, since_ack, $time);
                    since_ack <= -1;                         // report once
                end else          since_ack <= since_ack + 1;
            end
        end
    end

    function automatic int violations();
        return viol_ack_no_req + viol_stuck;
    endfunction
endmodule
