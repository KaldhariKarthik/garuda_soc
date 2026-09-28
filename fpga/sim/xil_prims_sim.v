`timescale 1ns/1ps
// =============================================================================
// Minimal behavioural models of the Xilinx primitives used by rtl/fpga/.
// SIMULATION ONLY (Verilator/iverilog here, where UNISIM is unavailable).
// Vivado uses the real UNISIM cells, and this file is never in the synth list.
// =============================================================================

// MMCM: CLKOUT0 is modelled as CLKIN1 passed through. The testbench feeds
// the hclk-rate clock directly, and LOCKED rises after 16 input cycles.
module MMCME4_BASE #(
    parameter real CLKIN1_PERIOD = 10.0, parameter integer DIVCLK_DIVIDE = 1,
    parameter real CLKFBOUT_MULT_F = 12.0, parameter real CLKOUT0_DIVIDE_F = 24.0
)(
    input CLKIN1, input CLKFBIN, output CLKFBOUT, output CLKFBOUTB,
    output CLKOUT0, output CLKOUT0B, output CLKOUT1, output CLKOUT1B,
    output CLKOUT2, output CLKOUT2B, output CLKOUT3, output CLKOUT3B,
    output CLKOUT4, output CLKOUT5, output CLKOUT6,
    output reg LOCKED, input PWRDWN, input RST
);
    reg [4:0] n;
    initial begin n = 0; LOCKED = 0; end
    always @(posedge CLKIN1 or posedge RST)
        if (RST) begin n <= 0; LOCKED <= 0; end
        else if (n != 5'd16) n <= n + 1'b1;
        else LOCKED <= 1'b1;
    assign CLKOUT0 = CLKIN1;
    assign CLKFBOUT = CLKIN1;
    assign {CLKFBOUTB, CLKOUT0B, CLKOUT1, CLKOUT1B, CLKOUT2, CLKOUT2B,
            CLKOUT3, CLKOUT3B, CLKOUT4, CLKOUT5, CLKOUT6} = 11'd0;
endmodule

module BUFG (input I, output O);
    assign O = I;
endmodule

// Divide by N: output rises on the input rising edges where the count wraps,
// so every output rising edge is an input rising edge.
module BUFGCE_DIV #(parameter integer BUFGCE_DIVIDE = 1)
    (input I, input CE, input CLR, output O);
    generate if (BUFGCE_DIVIDE == 1) begin : g1
        assign O = I;
    end else begin : gn
        reg [3:0] c;
        reg o;
        initial begin c = 0; o = 0; end
        always @(posedge I) begin
            c <= (c == BUFGCE_DIVIDE - 1) ? 4'd0 : c + 1'b1;
            if (c == 0) o <= 1'b1;
            else if (c == BUFGCE_DIVIDE / 2) o <= 1'b0;
        end
        // posedge-aligned: o rises as the NBA of the same input edge
        assign O = o;
    end endgenerate
endmodule

// Glitch-free enable: enable latched while I is low (ICG behaviour).
module BUFGCE #(parameter CE_TYPE = "SYNC") (input I, input CE, output O);
    reg en;
    initial en = 1'b0;
    always @(I or CE) if (!I) en = CE;
    assign O = I & en;
endmodule
