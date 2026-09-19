`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 22 : reset controller APB registers (window 9, 0x4000_9000)
// reset_ctrl_apb.v
//
// Spec: GARUDA-CLKRST-SPEC-001 §6, GARUDA-MEM-SPEC-001 §6 (MEMCTL)
//
//   0x00 RSTREASON  R/W1C  {BOOTFAIL, SW, NDM, WDT, EXT}   (flops live in reset_ctrl)
//   0x04 RSTCTL     RW     [0] SWRST (W, self-clearing)
//                          [4] SETBOOTFAIL (W, self-clearing)      - D-14
//                          [9:8] DIVSEL (RW, ext-only reset, [N-6.5])
//   0x08 CLKSTAT    RO     [1:0] DIVACT, [2] DIVBUSY, [8] BOOTSEL (pin, 2-flop
//                          synchronised - D-19: the bootloader reads it here)
//   0x20 MEMCTL     RW1S   [0] ILOCK, sticky, cleared only by reset ([N-6.1])
//   other offsets   PSLVERR
//
// RSTREASON is W1C and must be settable by the bootloader (CLKRST [N-6.2] "bit
// 4 is set by software"). A W1C bit cannot also be set by the same write, so
// the set path is RSTCTL[4] (D-14).
//
// APB3, zero wait states: PREADY is tied high. The bridge enforces word-only
// access, so PSTRB is not needed here.
// =============================================================================

module reset_ctrl_apb (
    input  wire        pclk_i,
    input  wire        preset_n_i,
    input  wire        ext_prst_n_i,

    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [11:0] paddr_i,
    input  wire [31:0] pwdata_i,
    output reg  [31:0] prdata_o,
    output wire        pready_o,
    output wire        pslverr_o,

    input  wire [4:0]  reason_i,
    output wire [4:0]  reason_w1c_o,
    output wire        bootfail_set_o,
    output wire        swrst_o,

    output wire [1:0]  div_sel_o,
    input  wire [1:0]  div_act_i,
    input  wire        div_busy_i,
    input  wire        boot_sel_i,

    output wire        ilock_o
);

    localparam [11:0] A_RSTREASON = 12'h000,
                      A_RSTCTL    = 12'h004,
                      A_CLKSTAT   = 12'h008,
                      A_MEMCTL    = 12'h020;

    wire access = psel_i & penable_i;
    wire wr     = access &  pwrite_i;

    wire hit = (paddr_i == A_RSTREASON) | (paddr_i == A_RSTCTL) |
               (paddr_i == A_CLKSTAT)   | (paddr_i == A_MEMCTL);

    // ---- strobes -----------------------------------------------------------
    assign reason_w1c_o   = (wr && paddr_i == A_RSTREASON) ? pwdata_i[4:0] : 5'b0;
    assign swrst_o        =  wr && paddr_i == A_RSTCTL && pwdata_i[0];
    assign bootfail_set_o =  wr && paddr_i == A_RSTCTL && pwdata_i[4];

    // ---- DIVSEL: survives every reset but the pin ---------------------------
    reg [1:0] div_sel_q;
    always @(posedge pclk_i or negedge ext_prst_n_i)
        if (!ext_prst_n_i)                  div_sel_q <= 2'b00;
        else if (wr && paddr_i == A_RSTCTL) div_sel_q <= pwdata_i[9:8];
    assign div_sel_o = div_sel_q;

    // ---- MEMCTL.ILOCK: RW1S, sticky -----------------------------------------
    reg ilock_q;
    always @(posedge pclk_i or negedge preset_n_i)
        if (!preset_n_i)                                    ilock_q <= 1'b0;
        else if (wr && paddr_i == A_MEMCTL && pwdata_i[0])  ilock_q <= 1'b1;
    assign ilock_o = ilock_q;

    // ---- boot_sel pin: asynchronous input, two-flop synchroniser ------------
    reg [1:0] bsel_q;
    always @(posedge pclk_i or negedge ext_prst_n_i)
        if (!ext_prst_n_i) bsel_q <= 2'b00;
        else               bsel_q <= {bsel_q[0], boot_sel_i};

    // ---- read mux ----------------------------------------------------------
    always @(*) begin
        case (paddr_i)
            A_RSTREASON: prdata_o = {27'b0, reason_i};
            A_RSTCTL:    prdata_o = {22'b0, div_sel_q, 8'b0};
            A_CLKSTAT:   prdata_o = {23'b0, bsel_q[1], 5'b0, div_busy_i, div_act_i};
            A_MEMCTL:    prdata_o = {31'b0, ilock_q};
            default:     prdata_o = 32'b0;
        endcase
    end

    assign pready_o  = 1'b1;
    assign pslverr_o = access & ~hit;

endmodule

`default_nettype wire
