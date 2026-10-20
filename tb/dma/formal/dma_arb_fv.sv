// =============================================================================
// dma_arb_fv.sv -- formal harness of dma_arbiter for five PRIO settings
// (tb/dma/formal/arb.toml), Track A DMA plan D2, vPlan F26 / R-4 / [N-7.4].
// The expected grant comes from the specification's rule, written here without
// the RTL's loop: the eligible channel with the highest priority wins, and on a
// tie the lowest channel number wins; grant_valid is high exactly when some
// channel is eligible. The five settings cover the shipped map (GARUDA-SYS-001
// dma.assignment), all equal (ties everywhere), rising, falling and pairs. The
// shipped map alone cannot show a tie bug (planted defect M12).
// =============================================================================
`timescale 1ns/1ps
module dma_arb_check #(parameter [17:0] PRIO = 18'd0, parameter bit TIES = 1'b0) (input wire [5:0] eligible);
    wire       gv;
    wire [2:0] gch;
    dma_arbiter #(.PRIO(PRIO)) u_arb (.eligible_i(eligible), .grant_valid_o(gv), .grant_ch_o(gch));
    function automatic [2:0] f_prio(input [2:0] n);
        return PRIO[3*n +: 3];
    endfunction
    // reference: scan priority levels from 7 down; inside a level, channels from 0 up
    reg       ref_v;
    reg [2:0] ref_ch;
    always @(*) begin
        ref_v = 1'b0; ref_ch = 3'd0;
        for (int p = 7; p >= 0; p--)
            for (int n = 0; n < 6; n++)
                if (!ref_v && eligible[n] && f_prio(n) == p[2:0]) begin ref_v = 1'b1; ref_ch = n[2:0]; end
    end
    // a tie is decided: another eligible channel has the winner's priority
    reg tie;
    always @(*) begin
        tie = 1'b0;
        for (int n = 0; n < 6; n++)
            if (ref_v && eligible[n] && n[2:0] != ref_ch && f_prio(n) == f_prio(ref_ch)) tie = 1'b1;
    end
    always @(*) begin
        a_grant_valid: assert (gv == (|eligible));
        a_grant:       assert (!gv || gch == ref_ch);
        c_all:         cover  (eligible == 6'h3F);   // identical in every instance: yosys keeps one
    end
    // a tie can only be decided in a setting with equal priorities
    generate if (TIES) begin : g_tie
        always @(*) c_tie: cover (tie);
    end endgenerate
endmodule

module dma_arb_fv (input wire clk, input wire [5:0] eligible);
    //                       ch5   ch4   ch3   ch2   ch1   ch0
    dma_arb_check #(.PRIO({3'd0, 3'd4, 3'd2, 3'd1, 3'd3, 3'd5})) u_shipped (.eligible(eligible));
    dma_arb_check #(.PRIO({3'd0, 3'd0, 3'd0, 3'd0, 3'd0, 3'd0}), .TIES(1)) u_equal   (.eligible(eligible));
    dma_arb_check #(.PRIO({3'd5, 3'd4, 3'd3, 3'd2, 3'd1, 3'd0})) u_rising  (.eligible(eligible));
    dma_arb_check #(.PRIO({3'd0, 3'd1, 3'd2, 3'd3, 3'd4, 3'd5})) u_falling (.eligible(eligible));
    dma_arb_check #(.PRIO({3'd3, 3'd3, 3'd5, 3'd5, 3'd1, 3'd1}), .TIES(1)) u_pairs   (.eligible(eligible));
endmodule
