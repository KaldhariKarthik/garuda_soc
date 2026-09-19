`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 11 : machine timer
// mtime.v
//
// Spec: GARUDA-TIMERS-SPEC-001 Rev 2.0 §7.1-§7.4; ADR-0010
//
//   mtime     64-bit up counter, +1 every hclk ([N-7.1]); writable ([N-7.3])
//   mtimecmp  resets to all ones so mtip cannot assert before firmware sets
//             it ([N-6.1])
//   mtip_o    (mtime >= mtimecmp), unsigned 64-bit, registered once
//             ([N-7.8], [N-7.9]); level until firmware advances mtimecmp
//   shadow    reading MTIME_LO latches mtime[63:32]; MTIME_HI returns the
//             shadow, so LO-then-HI is a coherent 64-bit read ([N-7.5])
// =============================================================================

module mtime (
    input  wire        hclk_i,
    input  wire        hreset_n_i,

    input  wire        wr_lo_i,        // MTIME_LO write strobe (one hclk)
    input  wire        wr_hi_i,
    input  wire        wr_cmp_lo_i,
    input  wire        wr_cmp_hi_i,
    input  wire        rd_lo_i,        // MTIME_LO read strobe: latch the shadow
    input  wire [31:0] wdata_i,

    output wire [31:0] mtime_lo_o,
    output wire [31:0] mtime_hi_shadow_o,
    output wire [63:0] mtimecmp_o,
    output reg         mtip_o
);

    reg [63:0] mtime_q, cmp_q;
    reg [31:0] shadow_q;

    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            mtime_q  <= 64'd0;
            cmp_q    <= {64{1'b1}};
            shadow_q <= 32'd0;
            mtip_o   <= 1'b0;
        end else begin
            if      (wr_lo_i) mtime_q <= {mtime_q[63:32], wdata_i};
            else if (wr_hi_i) mtime_q <= {wdata_i, mtime_q[31:0]};
            else              mtime_q <= mtime_q + 64'd1;

            if (wr_cmp_lo_i) cmp_q[31:0]  <= wdata_i;
            if (wr_cmp_hi_i) cmp_q[63:32] <= wdata_i;

            if (rd_lo_i) shadow_q <= mtime_q[63:32];

            mtip_o <= (mtime_q >= cmp_q);
        end
    end

    assign mtime_lo_o        = mtime_q[31:0];
    assign mtime_hi_shadow_o = shadow_q;
    assign mtimecmp_o        = cmp_q;

endmodule

`default_nettype wire
