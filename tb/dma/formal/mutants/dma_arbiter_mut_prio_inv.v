// MUTANT dma_arbiter_mut_prio_inv: rtl/dma/dma_arbiter.sv with ONE change (DMA plan D7: the LOWEST priority wins).
// Formal negative control: must FAIL.
// =============================================================================
// GARUDA SoC - Block 9 : channel arbiter (combinational)
// dma_arbiter.v
//
// Spec: GARUDA-DMA-SPEC-001 Rev 3.0 Sec.6.3, Sec.7.4; yaml dma.assignment
//
// Fixed priority, PRIO[3n +: 3] per channel, larger = higher. Default from the
// system definition: ch0 IMU 5, ch4 spare 4, ch1 I2C 3, ch3 UART1 2,
// ch2 UART0 1, ch5 console 0. Equal priorities fall back to the lower channel.
// Evaluated only when the engine is idle, i.e. at a beat boundary ([N-7.11]).
// =============================================================================

module dma_arbiter
    import garuda_pkg::*;
#(
    parameter [17:0] PRIO = {3'd0, 3'd4, 3'd2, 3'd1, 3'd3, 3'd5}  // ch5..ch0
)(
    input wire [DMA_NCH-1:0] eligible_i,
    output wire grant_valid_o,
    output wire [DMA_CH_W-1:0] grant_ch_o
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned BEST_W = 32'd3;

    // {valid, channel}: the eligible channel with the highest PRIO; on a tie
    // the lower channel (F4: the running best is a local of the function)
    function automatic [DMA_CH_W:0] arbitrate(input [DMA_NCH-1:0] el);
        logic [BEST_W-1:0] best;
        logic found;
        logic [DMA_CH_W-1:0] pick;
        found = 1'b0;
        pick = '0;
        best = '0;
        for (int c = 0; c < DMA_NCH; c++) begin
            if (el[c] && (!found || PRIO[BEST_W*c +: BEST_W] < best)) begin  // MUTANT
                found = 1'b1;
                pick = DMA_CH_W'(c);
                best = PRIO[BEST_W*c +: BEST_W];
            end
        end
        arbitrate = {found, pick};
    endfunction

    assign {grant_valid_o, grant_ch_o} = arbitrate(eligible_i);
endmodule
