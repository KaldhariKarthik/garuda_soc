// =============================================================================
// GARUDA SoC - Block 9 : channel arbiter (combinational)
// dma_arbiter.v
//
// Spec: GARUDA-DMA-SPEC-001 Rev 3.0 §6.3, §7.4; yaml dma.assignment
//
// Fixed priority, PRIO[3n +: 3] per channel, larger = higher. Default from the
// system definition: ch0 IMU 5, ch4 spare 4, ch1 I2C 3, ch3 UART1 2,
// ch2 UART0 1, ch5 console 0. Equal priorities fall back to the lower channel.
// Evaluated only when the engine is idle, i.e. at a beat boundary ([N-7.11]).
// =============================================================================

module tb2 #(
    parameter [17:0] PRIO = {3'd0, 3'd4, 3'd2, 3'd1, 3'd3, 3'd5}  // ch5..ch0
)(
);
    reg [5:0] eligible_i; reg grant_valid_o; reg [2:0] grant_ch_o;
    initial begin for (int i = 0; i < 64; i++) begin eligible_i = 6'(i); #1; end $finish; end
    integer n;
    reg [2:0] best;
    always @(*) begin
        grant_valid_o = 1'b0;
        grant_ch_o    = 3'd0;
        best          = 3'd0;
        for (n = 0; n < 6; n = n + 1)
            if (eligible_i[n] && (!grant_valid_o || PRIO[3*n +: 3] > best)) begin
                grant_valid_o = 1'b1;
                grant_ch_o    = n[2:0];
                best          = PRIO[3*n +: 3];
            end
    end
endmodule

