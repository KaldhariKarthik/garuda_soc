// =============================================================================
// GARUDA SoC - Block 11 : machine timer
// mtime.v
//
// Spec: GARUDA-TIMERS-SPEC-001 Rev 2.0 Sec.7.1-Sec.7.4; ADR-0010
//
//   mtime     64-bit up counter, +1 every hclk ([N-7.1]); writable ([N-7.3])
//   mtimecmp  resets to all ones so mtip cannot assert before firmware sets
//             it ([N-6.1])
//   mtip_o    (mtime >= mtimecmp), unsigned 64-bit, registered once
//             ([N-7.8], [N-7.9]); level until firmware advances mtimecmp
//   shadow    reading MTIME_LO latches mtime[63:32]; MTIME_HI returns the
//             shadow, so LO-then-HI is a coherent 64-bit read ([N-7.5])
// =============================================================================

module mtime
    import garuda_pkg::*;
(
    input wire hclk,
    input wire hreset_n,
    input wire wr_lo_i,  // MTIME_LO write strobe (one hclk)
    input wire wr_hi_i,
    input wire wr_cmp_lo_i,
    input wire wr_cmp_hi_i,
    input wire rd_lo_i,  // MTIME_LO read strobe: latch the shadow
    input wire [WORD_W-1:0] wdata_i,
    output wire [WORD_W-1:0] mtime_lo_o,
    output wire [WORD_W-1:0] mtime_hi_shadow_o,
    output wire [DWORD_W-1:0] mtimecmp_o,
    output reg mtip_o
);
    timeunit 1ns;
    timeprecision 1ps;

    reg [DWORD_W-1:0] mtime_q;
    reg [DWORD_W-1:0] cmp_q;
    reg [WORD_W-1:0] shadow_q;

    always_ff @(posedge hclk or negedge hreset_n) begin : p_mtime
        if (!hreset_n) begin
            mtime_q <= 64'd0;
            cmp_q <= {64{1'b1}};
            shadow_q <= 32'd0;
            mtip_o <= 1'b0;
        end else begin
            if (wr_lo_i) begin
                mtime_q <= {mtime_q[63:32], wdata_i};
            end else if (wr_hi_i) begin
                mtime_q <= {wdata_i, mtime_q[31:0]};
            end else begin
                mtime_q <= mtime_q + 64'd1;
            end
            if (wr_cmp_lo_i) begin
                cmp_q[31:0] <= wdata_i;
            end
            if (wr_cmp_hi_i) begin
                cmp_q[63:32] <= wdata_i;
            end
            if (rd_lo_i) begin
                shadow_q <= mtime_q[63:32];
            end
            mtip_o <= (mtime_q >= cmp_q);
        end
    end

    assign mtime_lo_o        = mtime_q[31:0];
    assign mtime_hi_shadow_o = shadow_q;
    assign mtimecmp_o        = cmp_q;

endmodule
