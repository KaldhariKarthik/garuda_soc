// =============================================================================
// dma_fv_env.sv -- SINGLE-CLOCK formal environment of dma_top (the main DMA
// harness: tb/dma/formal/dma.toml), Track A DMA plan D2. Bound into dma_top; the
// properties are rtl/dma/dma_props_a.sv (bound through rtl/dma/filelist.f).
//
// Without `multiclock on`, SBY clocks every flop once per step, so hclk and pclk
// are the same clock here. For the hclk-domain logic (channels, arbiter, engine,
// write strobes) this is an over-approximation of D-5: an APB write takes 2 hclk
// cycles instead of 4 and may start on any cycle, so every real sequence of
// register writes is included. Consequences, recorded in ASSUMPTIONS.md:
//   - a property PROVEN here holds on the real design (hclk-domain properties);
//   - a counterexample may need writes faster than real software can make them,
//     so every counterexample is replayed with real timing before it is filed (H6);
//   - the pclk-specific property a_ack_one_pclk_edge is false by construction here
//     (a 2-hclk ack is seen by two "pclk" edges) and is left out (DMA_FV_ONECLK);
//     it is proven in the two-clock harness (dma_fv_env_2clk.sv).
//
//   S1 reset: hreset_n and preset_n low for the first RST_CYCLES cycles, then high.
//   S2 APB master (PREADY tied 1): setup is followed by exactly one access with the
//      same address, direction and write data; after an access comes idle or a
//      new setup; PSEL low in reset.
//   S3 AHB-Lite slave: HREADY may be low in any cycle; HRESP is OKAY unless a data
//      phase is pending; ERROR is the two-cycle response; HREADY high and HRESP
//      OKAY in reset. HRDATA is free.
//   dma_req_i is free (the DMA's own rules must hold for any request pattern).
// =============================================================================
`timescale 1ns/1ps
module dma_fv_env #(
    parameter integer RST_CYCLES = 2
)(
    input wire        clk,
    input wire        hreset_n_i,
    input wire        preset_n_i,
    input wire        psel_i,
    input wire        penable_i,
    input wire        pwrite_i,
    input wire [11:0] paddr_i,
    input wire [31:0] pwdata_i,
    input wire [1:0]  htrans_o,
    input wire        hready_i,
    input wire        hresp_i
);
    reg [2:0]  cyc = 3'd0;
    reg        psel_q = 1'b0, penable_q = 1'b0, pwrite_q = 1'b0;
    reg [11:0] paddr_q = 12'd0;
    reg [31:0] pwdata_q = 32'd0;
    reg        dp = 1'b0;            // an AHB data phase is pending
    reg        err1 = 1'b0;          // last cycle was the first cycle of an ERROR

    always @(posedge clk) begin
        if (cyc != 3'd7) cyc <= cyc + 3'd1;
        psel_q <= psel_i; penable_q <= penable_i; pwrite_q <= pwrite_i;
        paddr_q <= paddr_i; pwdata_q <= pwdata_i;
        if (!hreset_n_i) begin dp <= 1'b0; err1 <= 1'b0; end
        else begin
            if (hready_i) dp <= htrans_o[1];
            err1 <= hresp_i && !hready_i;
        end
    end

    always @(*) begin
        // ---- S1 reset
        if (cyc < RST_CYCLES) begin assume (!hreset_n_i); assume (!preset_n_i); end
        else                  begin assume (hreset_n_i);  assume (preset_n_i);  end
        // ---- S2 APB master
        if (psel_q && !penable_q)                        // setup -> access, same transfer
            assume (psel_i && penable_i && pwrite_i == pwrite_q && paddr_i == paddr_q &&
                    pwdata_i == pwdata_q);
        else                                             // idle or access -> idle or setup
            assume (!penable_i);
        if (!preset_n_i) assume (!psel_i);
        // ---- S3 AHB-Lite slave
        if (!hreset_n_i) assume (hready_i && !hresp_i);
        else begin
            if (!dp) assume (!hresp_i);
            if (hresp_i && hready_i) assume (err1);
            if (err1) assume (hresp_i && hready_i);
        end
    end
endmodule

bind dma_top dma_fv_env u_fv_env (
    .clk(hclk_i), .hreset_n_i(hreset_n_i), .preset_n_i(preset_n_i),
    .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i), .paddr_i(paddr_i),
    .pwdata_i(pwdata_i), .htrans_o(htrans_o), .hready_i(hready_i), .hresp_i(hresp_i));
