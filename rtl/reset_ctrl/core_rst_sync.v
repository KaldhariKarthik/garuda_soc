`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - reset_ctrl : the core's reset synchroniser
// core_rst_sync.v
//
// GARUDA-CLKRST-SPEC-001 [N-7.13], [N-7.14], [N-7.17]; GARUDA-CORE-SPEC-001 [N-7.33];
// decision D-36 (2026-11-16).
//
// core_rst_n_o resets the core and the DSU. It falls
//   - at once (asynchronously) while clr_i is high: every system reset, from
//     reset_ctrl's aon-domain request register;
//   - one hclk after hartreset_req_i rises: the Debug Module's hartreset grant, a
//     register on hclk, sampled here.
// It rises synchronously to hclk, two clocks after both have dropped.
//
// A module of its own so that the reset generation is not mixed with other logic
// (HAL RSTGNP), and so that the core benches use this logic rather than a copy of it
// (tb/core/tb_core_halt.sv, tb/core/formal/rdc1_top.sv).
// =============================================================================
module core_rst_sync (
    input  wire hclk_i,
    input  wire clr_i,              // asynchronous, active high
    input  wire hartreset_req_i,    // hclk domain, level
    output wire core_rst_n_o
);
    reg [1:0] sync_q;
    always @(posedge hclk_i or posedge clr_i) begin
        if (clr_i) begin
            sync_q <= 2'b00;
        end else begin
            sync_q <= {sync_q[0] & ~hartreset_req_i, ~hartreset_req_i};
        end
    end
    assign core_rst_n_o = sync_q[1];
endmodule
