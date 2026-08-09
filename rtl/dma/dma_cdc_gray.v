`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 9: DMA Controller
// dma_cdc_gray.v - Gray-coded multi-bit value crossing (counter -> other domain)
//
// Spec reference: GARUDA-DMA-SPEC-001 Rev 2.0, Sec. 6.7 (SR.REMAINING)
//
// THE PROBLEM THIS SOLVES
// SR.REMAINING (SR[31:16]) is a live readback of xfer_cnt. xfer_cnt is a
// 16-bit down-counter in the hclk domain; the APB read that returns it is in
// the pclk domain. Pushing 16 raw binary bits through a two-flop synchronizer
// is wrong: on the beat where the count rolls 0x0100 -> 0x00FF, nine bits
// change at once, and any of them may resolve on the far side of the capture
// edge. Firmware polling progress would occasionally read a number the counter
// never held - 0x01FF, say - which is the worst kind of defect because it is
// rare, unreproducible, and looks like a DMA that skipped beats.
//
// Gray coding makes exactly ONE bit change per decrement, so a skewed capture
// can only ever return the value before or the value after. Both are real.
//
// THE DOCUMENTED LIMIT
// xfer_cnt does not only decrement. It is LOADED from TCR when the channel
// enters CONFIGURED, and forced to 0 when the channel is IDLE or COMPLETE
// (Sec. 6.7: "Reads 0 when channel is IDLE or transfer is complete"). Those
// are multi-bit jumps, and across one of them the gray code guarantee does not
// hold - a read landing in that ~2-pclk window can return a mixture.
//
// This is accepted, not overlooked, for three reasons:
//   1. SR.REMAINING is explicitly advisory - Sec. 16.7 justifies it as "poll
//      transfer progress for debugging or adaptive scheduling". No control
//      decision in the programming model depends on it.
//   2. The window is two pclk cycles at the start and end of a transfer, and
//      the value settles to the correct one immediately after.
//   3. Closing it properly needs a full req/ack data handshake (~4x the area,
//      6 instances) to harden a debug field. That is not a trade worth making
//      on a block budgeted at 14-18k gates.
// Firmware that needs an exact count must read SR.REMAINING twice and compare,
// or use SR.COMPLETE. This is stated in docs/DMA_RTL_LOG.md as a known limit.
//
// The binary->gray register is in the SOURCE domain, so the synchronizer only
// ever sees a clean registered value - never combinational logic mid-settle.
// =============================================================================

module dma_cdc_gray #(
    parameter integer WIDTH = 16
)(
    // Source domain
    input  wire             src_clk_i,
    input  wire             src_rst_n_i,
    input  wire [WIDTH-1:0] src_bin_i,

    // Destination domain
    input  wire             dst_clk_i,
    input  wire             dst_rst_n_i,
    output reg  [WIDTH-1:0] dst_bin_o
);

    // ---------------- source domain: binary -> gray, registered -------------
    wire [WIDTH-1:0] src_gray = src_bin_i ^ (src_bin_i >> 1);

    reg [WIDTH-1:0] gray_q;
    always @(posedge src_clk_i or negedge src_rst_n_i) begin
        if (!src_rst_n_i) gray_q <= {WIDTH{1'b0}};
        else              gray_q <= src_gray;
    end

    // ---------------- destination domain: two-flop synchronizer -------------
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] sync_meta;
    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] sync_q;

    always @(posedge dst_clk_i or negedge dst_rst_n_i) begin
        if (!dst_rst_n_i) begin
            sync_meta <= {WIDTH{1'b0}};
            sync_q    <= {WIDTH{1'b0}};
        end else begin
            sync_meta <= gray_q;
            sync_q    <= sync_meta;
        end
    end

    // ---------------- destination domain: gray -> binary --------------------
    // bin[MSB] = gray[MSB];  bin[i] = bin[i+1] ^ gray[i]
    integer i;
    always @(*) begin
        dst_bin_o[WIDTH-1] = sync_q[WIDTH-1];
        for (i = WIDTH-2; i >= 0; i = i - 1)
            dst_bin_o[i] = dst_bin_o[i+1] ^ sync_q[i];
    end

endmodule

`default_nettype wire
