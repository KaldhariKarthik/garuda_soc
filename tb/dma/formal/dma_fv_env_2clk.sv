// =============================================================================
// dma_fv_env_2clk.sv -- TWO-CLOCK formal environment of dma_top
// (tb/dma/formal/dma_2clk.toml), Track A DMA plan D2: real D-5 clocking, for the
// properties that depend on pclk (PRDATA timing, the ack seen by one pclk edge).
// The deep tasks use the single-clock harness dma_fv_env.sv. Bound into dma_top;
// the design's properties are rtl/dma/dma_props_a.sv (bound through rtl/dma/filelist.f).
//
// Runs under SBY `multiclock on`. The environment's time base is a wire with the
// gclk attribute (yosys-slang has no $global_clock without a global clocking block).
// Measured 2026-10-12: that wire behaves as a free clock the solver toggles, so one
// tick is at least two formal steps (one hclk cycle = 4 steps, one APB write = 16),
// and the solver may also pause the clocks (stuttering), which is sound for safety
// properties. PDR does not depend on the step count; bounded depths must allow for
// it. Every top-level input of dma_top is free except for the assumptions
// below; each is listed in tb/dma/formal/ASSUMPTIONS.md with the simulation check
// that backs it.
//
//   E1 clocks (D-5): hclk toggles every step; pclk = hclk/2, and every pclk rising
//      edge is an hclk rising edge.      ph: 0 1 2 3 | hclk 0 1 0 1 | pclk 0 1 1 0
//   E2 reset: hreset_n and preset_n low for the first RST_STEPS ticks, then high
//      for good (reset in mid-run is a separate harness, F47).
//   E3 APB master (AMBA APB, PREADY tied 1): inputs change only right after a
//      pclk edge; setup is followed by exactly one access with the same address,
//      direction and write data; after an access comes idle or a new setup;
//      PSEL low in reset.
//   E4 AHB-Lite slave (IHI 0033A): inputs change only right after an hclk edge;
//      HREADY may be low in any cycle (wait states, or a lost arbitration that
//      holds M3's address phase); HRESP is OKAY unless a data phase is pending;
//      ERROR is the two-cycle response (HRESP with HREADY low, then HRESP with
//      HREADY high); HREADY high and HRESP OKAY in reset. HRDATA is free.
//   dma_req_i is free: the DMA's own rules must hold for any request pattern,
//   including ones that break the peripheral contract D-21.
// =============================================================================
`timescale 1ns/1ps
module dma_fv_env_2clk #(
    parameter integer RST_STEPS = 2     // environment ticks (each >= 2 formal steps)
)(
    input wire        hclk_i,
    input wire        hreset_n_i,
    input wire        pclk_i,
    input wire        preset_n_i,
    input wire        psel_i,
    input wire        penable_i,
    input wire        pwrite_i,
    input wire [11:0] paddr_i,
    input wire [31:0] pwdata_i,
    input wire [1:0]  htrans_o,
    input wire [31:0] hrdata_i,
    input wire        hready_i,
    input wire        hresp_i
);
    (* gclk *) wire gclk;

    reg [1:0]  ph = 2'd0;
    reg [5:0]  steps = 6'd0;
    // previous-step copies of the free inputs
    reg        psel_q = 1'b0, penable_q = 1'b0, pwrite_q = 1'b0;
    reg [11:0] paddr_q = 12'd0;
    reg [31:0] pwdata_q = 32'd0;
    reg        hready_q = 1'b1, hresp_q = 1'b0;
    reg [31:0] hrdata_q = 32'd0;
    // AHB view at hclk granularity
    reg        dp = 1'b0;            // a data phase is pending
    reg        err1 = 1'b0;          // last hclk cycle was the first cycle of an ERROR

    always @(posedge gclk) begin
        ph <= ph + 2'd1;
        if (steps != 6'h3F) steps <= steps + 6'd1;
        psel_q <= psel_i; penable_q <= penable_i; pwrite_q <= pwrite_i;
        paddr_q <= paddr_i; pwdata_q <= pwdata_i;
        hready_q <= hready_i; hresp_q <= hresp_i; hrdata_q <= hrdata_i;
    end
    always @(posedge hclk_i) begin
        if (!hreset_n_i) begin dp <= 1'b0; err1 <= 1'b0; end
        else begin
            if (hready_i) dp <= htrans_o[1];             // an accepted NONSEQ opens a data phase
            err1 <= hresp_i && !hready_i;
        end
    end

    wire pedge = (ph == 2'd1);       // this step follows a pclk (and hclk) rising edge
    wire hedge = ph[0];              // this step follows an hclk rising edge

    always @(*) begin
        // ---- E1 clocks
        assume (hclk_i == ph[0]);
        assume (pclk_i == (ph == 2'd1 || ph == 2'd2));
        // ---- E2 reset
        if (steps < RST_STEPS) begin assume (!hreset_n_i); assume (!preset_n_i); end
        else                   begin assume (hreset_n_i);  assume (preset_n_i);  end
        // ---- E3 APB master
        if (!pedge)
            assume (psel_i == psel_q && penable_i == penable_q && pwrite_i == pwrite_q &&
                    paddr_i == paddr_q && pwdata_i == pwdata_q);
        else if (psel_q && !penable_q)                   // setup -> access, same transfer
            assume (psel_i && penable_i && pwrite_i == pwrite_q && paddr_i == paddr_q &&
                    pwdata_i == pwdata_q);
        else                                             // idle or access -> idle or setup
            assume (!penable_i);
        if (!preset_n_i) assume (!psel_i);
        // ---- E4 AHB-Lite slave
        if (!hedge)
            assume (hready_i == hready_q && hresp_i == hresp_q && hrdata_i == hrdata_q);
        if (!hreset_n_i) assume (hready_i && !hresp_i);
        else begin
            if (!dp) assume (!hresp_i);                  // OKAY when no data phase is pending
            if (hresp_i && hready_i) assume (err1);      // second ERROR cycle follows the first
            if (err1) assume (hresp_i && hready_i);      // the first is always followed by the second
        end
    end
endmodule

bind dma_top dma_fv_env_2clk u_fv_env (
    .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .pclk_i(pclk_i), .preset_n_i(preset_n_i),
    .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i), .paddr_i(paddr_i),
    .pwdata_i(pwdata_i), .htrans_o(htrans_o), .hrdata_i(hrdata_i), .hready_i(hready_i),
    .hresp_i(hresp_i));
