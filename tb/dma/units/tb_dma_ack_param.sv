`timescale 1ns/1ps
// =============================================================================
// tb_dma_ack_param.sv -- the DMA-13 parameter check (Track A, 2026-11-02).
// dma_engine's acknowledge counter is two bits wide, so the DMA-13 ruling refuses an
// ACK_CYCLES outside 1..4 at time 0 ($fatal) instead of giving a wrong dma_ack width.
// The bench instantiates the engine with ACK_CYCLES = ACK, runs one P2M word beat for
// channel 0 against an always-ready OKAY slave, and checks that dma_ack[0] is high for
// exactly ACK hclk cycles (review 2026-11-03: the edges 1 and 4 of the counter).
// tb/dma/run/units.toml sets ACK with -GACK=<n>: 1 and 4 must reach the PASSED line,
// 0 and 5 must stop with the engine's message (negative controls, XFAIL PLANTED).
// =============================================================================
module tb_dma_ack_param;
    parameter integer ACK = 2;
    logic clk = 0, rst_n = 0;
    always #2 clk = ~clk;
    logic gv = 0;
    wire [5:0] bdone, berr, ack, infl; wire [2:0] eph; wire [1:0] bsz;
    wire [31:0] haddr, hwdata; wire [1:0] htrans; wire hwrite; wire [2:0] hsize, hburst; wire busy;
    // channel 0: SAR 2000_0000, DAR 2080_0000, word, peripheral mode (an acknowledge is due)
    wire [191:0] sar = {160'd0, 32'h2000_0000};
    wire [191:0] dar = {160'd0, 32'h2080_0000};
    wire [11:0]  size = {10'd0, 2'd2};

    dma_engine #(.ACK_CYCLES(ACK)) dut (.hclk_i(clk), .hreset_n_i(rst_n), .grant_valid_i(gv), .grant_ch_i(3'd0),
        .sar_i(sar), .dar_i(dar), .size_i(size), .m2m_i(6'd0),
        .beat_done_o(bdone), .beat_err_o(berr), .err_phase_o(eph), .dma_ack_o(ack),
        .beat_size_o(bsz), .inflight_o(infl),
        .haddr_o(haddr), .htrans_o(htrans), .hwrite_o(hwrite), .hsize_o(hsize), .hburst_o(hburst),
        .hwdata_o(hwdata), .hrdata_i(32'h1234_5678), .hready_i(1'b1), .hresp_i(1'b0), .busy_o(busy));

    int ack_len = 0, waited = 0;
    initial begin
        repeat (2) @(posedge clk);
        rst_n = 1;
        @(posedge clk); gv <= 1;                          // one grant: the engine takes the beat
        @(posedge clk); gv <= 0;
        while (bdone[0] !== 1'b1 && berr[0] !== 1'b1 && waited < 50) begin @(posedge clk); waited++; end
        if (bdone[0] !== 1'b1) begin
            $display("[FAIL] the beat did not complete (done %b err %b after %0d cycles)", bdone, berr, waited);
            $finish;
        end
        while (ack[0] === 1'b1) begin ack_len++; @(posedge clk); end
        if (ack_len != ACK) begin
            $display("[FAIL] dma_ack[0] high %0d hclk, ACK_CYCLES = %0d", ack_len, ACK);
            $finish;
        end
        repeat (2) @(posedge clk);
        if (busy || ack !== 6'd0) begin
            $display("[FAIL] the engine is busy or acknowledges after the beat (ACK_CYCLES = %0d)", ACK);
            $finish;
        end
        $display("RESULT: PASSED (ACK_CYCLES = %0d accepted, one beat, dma_ack %0d hclk)", ACK, ack_len);
        $finish;
    end
endmodule
