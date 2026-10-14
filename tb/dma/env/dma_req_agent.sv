`timescale 1ns/1ps
// =============================================================================
// dma_req_agent.sv -- the six peripheral request lines of the DMA, in the pclk
// domain (Track A, DMA plan D4; decisions D-16, D-21; vPlan F21-F25, F50).
//
// Per channel, set by the test:
//   mode[n]    REQ_OFF       request low
//              REQ_D21       the peripheral contract: raise the request after a
//                            random gap of 0..gap_max[n] pclk, drop it at the first
//                            pclk edge that sees dma_ack, hold off at least one pclk
//              REQ_HELD      negative mode: once raised, never dropped (D-21 broken;
//                            the DMA must give one beat, dma_req_checker must fire)
//              REQ_WITHDRAW  like REQ_D21, but sometimes (withdraw_pct %) drops the
//                            request after 1..3 pclk without waiting for an ack (F23)
//   todo[n]    requests still to make (the test sets it to the beats it expects);
//              a request counts as made when its ack is seen
// dma_ack is 2 hclk wide and seen high by exactly one pclk edge (D-16, a_ack_width,
// a_ack_one_pclk_edge), so sampling it on pclk sees every ack once.
// =============================================================================
module dma_req_agent
    import dma_env_pkg::*;
(
    input  wire       pclk,
    input  wire       rst_n,
    input  wire [5:0] ack,
    output logic [5:0] req
);
    // modes: dma_env_pkg::REQ_OFF / REQ_D21 / REQ_HELD / REQ_WITHDRAW
    int          mode [6];
    int          todo [6];
    int unsigned gap_max [6];
    int unsigned withdraw_pct = 0;
    int          n_ack [6];          // acks seen per channel
    int          n_withdrawn [6];    // requests dropped before an ack

    int          gap [6];
    int          hold [6];           // pclk left in the hold-off after a drop
    int          age [6];            // pclk the current request has been high
    int          wd_at [6];          // withdraw after this many pclk (-1 = no)

    initial for (int n = 0; n < 6; n++) begin
        mode[n] = REQ_OFF; todo[n] = 0; gap_max[n] = 3; n_ack[n] = 0; n_withdrawn[n] = 0;
        gap[n] = 0; hold[n] = 0; age[n] = 0; wd_at[n] = -1; req[n] = 1'b0;
    end

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            req <= 6'd0;
            for (int n = 0; n < 6; n++) begin gap[n] <= 0; hold[n] <= 0; age[n] <= 0; wd_at[n] <= -1; end
        end else begin
            for (int n = 0; n < 6; n++) begin
                if (ack[n]) n_ack[n]++;
                if (req[n]) begin
                    age[n] <= age[n] + 1;
                    if (mode[n] == REQ_OFF) begin
                        req[n] <= 1'b0; age[n] <= 0;                                      // switched off
                    end else if (mode[n] == REQ_HELD) begin
                        // never dropped
                    end else if (ack[n]) begin
                        req[n] <= 1'b0; todo[n]--; hold[n] <= 1; age[n] <= 0;  // drop on ack
                        gap[n] <= (gap_max[n] > 0) ? $urandom_range(gap_max[n], 0) : 0;
                    end else if (mode[n] == REQ_WITHDRAW && wd_at[n] >= 0 && age[n] >= wd_at[n]) begin
                        req[n] <= 1'b0; n_withdrawn[n]++; hold[n] <= 1; age[n] <= 0;   // withdrawn (F23)
                        gap[n] <= (gap_max[n] > 0) ? $urandom_range(gap_max[n], 0) : 0;
                    end
                end else if (hold[n] > 0) begin
                    hold[n] <= hold[n] - 1;                                           // hold-off (D-21)
                end else if (gap[n] > 0) begin
                    gap[n] <= gap[n] - 1;
                end else if (mode[n] != REQ_OFF && todo[n] > 0) begin
                    req[n] <= 1'b1; age[n] <= 0;
                    wd_at[n] <= (mode[n] == REQ_WITHDRAW && $urandom_range(99, 0) < withdraw_pct)
                                ? $urandom_range(3, 1) : -1;
                end
            end
        end
    end
endmodule
