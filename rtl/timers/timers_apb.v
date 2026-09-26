`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 11 : timers APB interface (window 11, 0x4000_B000)
// timers_apb.v
//
// Spec: GARUDA-TIMERS-SPEC-001 Rev 2.0 §6, §9 [N-9.1]; ADR-0002 Rev 2.
//
// -----------------------------------------------------------------------------
// TWO CLOCKS, AND WHY
// -----------------------------------------------------------------------------
// The APB protocol side runs on pclk (125 MHz); the counters and their
// registers stay on hclk (250 MHz), because that is the rate hardware updates
// them at. ADR-0002 Rev 2 asks for exactly that split. There is no CDC: every
// pclk edge is an hclk edge (D-5), so a pclk-domain pulse can be edge-detected
// in hclk to give exactly one hclk strobe.
//
// The reason this matters, and it is a timing reason rather than a functional
// one: PRDATA used to be combinational out of hclk registers. `wdtval_i` is a
// free-running hclk down-counter, so PRDATA moved at every hclk edge -
// including the one in the MIDDLE of a pclk access phase. The bridge captures
// PRDATA at the pclk edge that ends the access, so that path launched from an
// hclk flop 4 ns before the capture instead of 8. Across the chip, from this
// peripheral to the bridge, that is a hard path to close.
//
// PRDATA is now REGISTERED on pclk. The 4 ns hclk-to-pclk hop still exists,
// but it is local - counter flop to this module's own prdata register, a few
// gates away - and what leaves the block towards the bridge is pclk-to-pclk
// with a full period. Trading a chip-crossing 4 ns path for a local one is the
// whole point of the change.
//
// -----------------------------------------------------------------------------
// WHY THE READ STROBE FIRES IN THE *SETUP* PHASE
// -----------------------------------------------------------------------------
// Reading MTIME_LO has a side effect: it latches mtime[63:32] into the shadow
// that MTIME_HI returns, so LO-then-HI is a coherent 64-bit read ([N-7.5]).
// LO and the shadow must therefore be captured on the SAME hclk edge, or a
// rollover between them yields a 64-bit value that never existed.
//
// PRDATA is registered at the setup-to-access edge, so the value it registers
// has to be ready by then - which means the capture must happen during setup,
// not during the access phase as it used to. PADDR is valid throughout setup
// (APB3), so this is legal, and it keeps LO and the shadow on one edge:
//
//   pclk edge Ts    setup phase begins
//   hclk cycle Ts   rs is high for this ONE cycle
//   hclk edge Ts+1  mtime.v latches the shadow; lo_cap latches MTIME_LO  <- same edge
//   pclk edge Ts+2  access phase begins; prdata_q registers lo_cap
//   pclk edge Ts+4  bridge samples PRDATA - stable for the whole phase
//
//   0x00 MTIME_LO   0x04 MTIME_HI (shadow)  0x08 MTIMECMP_LO  0x0C MTIMECMP_HI
//   0x10 WDTCTL     0x14 WDTLOAD            0x18 WDTVAL (RO)  0x1C WDTKICK (W)
//   0x20 WDTWARN    other: PSLVERR
// =============================================================================

module timers_apb (
    input  wire        hclk_i,
    input  wire        hreset_n_i,
    input  wire        pclk_i,          // APB side (ADR-0002 Rev 2)
    input  wire        preset_n_i,

    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [11:0] paddr_i,
    input  wire [31:0] pwdata_i,
    output wire [31:0] prdata_o,
    output wire        pready_o,
    output wire        pslverr_o,

    output wire        wr_mtime_lo_o, wr_mtime_hi_o, wr_cmp_lo_o, wr_cmp_hi_o,
    output wire        rd_mtime_lo_o,
    output wire        wr_wdtctl_o, wr_wdtload_o, wr_wdtkick_o, wr_wdtwarn_o,
    output wire [31:0] wdata_o,

    input  wire [31:0] mtime_lo_i,
    input  wire [31:0] mtime_hi_i,
    input  wire [63:0] mtimecmp_i,
    input  wire [31:0] wdtctl_i, wdtload_i, wdtval_i, wdtwarn_i
);

    wire [5:0] w = paddr_i[7:2];
    wire hit = (paddr_i[11:8] == 4'h0) && (paddr_i[1:0] == 2'b00) && (w <= 6'd8);
    wire ro  = (w == 6'd6);                       // WDTVAL

    // =========================================================================
    // pclk side. An APB phase is one pclk cycle and setup never repeats
    // back-to-back, so `setup` and `acc` are already one-pclk pulses.
    // =========================================================================
    wire setup = psel_i & ~penable_i & hit;
    wire acc   = psel_i &  penable_i & hit;

    wire rd_req = setup & ~pwrite_i;              // capture reads during setup
    wire wr_req = acc   &  pwrite_i;              // apply writes during access

    // =========================================================================
    // hclk side. Each request is high for one pclk = two hclk cycles; the
    // edge detect turns it into exactly one hclk strobe, in the first of them.
    // =========================================================================
    reg rd_d, wr_d;
    always @(posedge hclk_i or negedge hreset_n_i)
        if (!hreset_n_i) begin rd_d <= 1'b0; wr_d <= 1'b0; end
        else             begin rd_d <= rd_req;  wr_d <= wr_req; end

    wire rs = rd_req & ~rd_d;
    wire ws = wr_req & ~wr_d;

    assign wr_mtime_lo_o = ws && w == 6'd0;
    assign wr_mtime_hi_o = ws && w == 6'd1;
    assign wr_cmp_lo_o   = ws && w == 6'd2;
    assign wr_cmp_hi_o   = ws && w == 6'd3;
    assign wr_wdtctl_o   = ws && w == 6'd4;
    assign wr_wdtload_o  = ws && w == 6'd5;
    assign wr_wdtkick_o  = ws && w == 6'd7;
    assign wr_wdtwarn_o  = ws && w == 6'd8;
    assign rd_mtime_lo_o = rs && w == 6'd0;
    assign wdata_o       = pwdata_i;

    // MTIME_LO is captured on the same hclk edge that latches the shadow, so
    // the pair the bridge returns came from one cycle of the counter.
    reg [31:0] lo_cap;
    always @(posedge hclk_i or negedge hreset_n_i)
        if (!hreset_n_i)        lo_cap <= 32'd0;
        else if (rd_mtime_lo_o) lo_cap <= mtime_lo_i;

    // =========================================================================
    // Read mux, and the pclk register in front of the bus
    // =========================================================================
    reg [31:0] rd_mux;
    always @(*) begin
        case (w)
            6'd0: rd_mux = lo_cap;                 // captured during setup
            6'd1: rd_mux = mtime_hi_i;
            6'd2: rd_mux = mtimecmp_i[31:0];
            6'd3: rd_mux = mtimecmp_i[63:32];
            6'd4: rd_mux = wdtctl_i;
            6'd5: rd_mux = wdtload_i;
            6'd6: rd_mux = wdtval_i;
            6'd8: rd_mux = wdtwarn_i;
            default: rd_mux = 32'd0;               // WDTKICK reads 0
        endcase
    end

    reg [31:0] prdata_q;
    always @(posedge pclk_i or negedge preset_n_i)
        if (!preset_n_i)              prdata_q <= 32'd0;
        else if (psel_i & ~penable_i) prdata_q <= hit ? rd_mux : 32'd0;

    assign prdata_o  = prdata_q;
    assign pready_o  = 1'b1;
    assign pslverr_o = psel_i & penable_i & (~hit | (pwrite_i & ro));

endmodule

`default_nettype wire
