// csr_file_fv_env.sv -- csr_file-level formal environment (tb/core/formal/csr_file.toml).
// rst_n_i is low in the first cycle, so every register (including the
// property helper flops) starts from its reset value; afterwards rst_n_i is
// free, so a reset may assert at any time. All other inputs are free.
// Without this, registers start unconstrained and the solver reports states
// no reset can reach (seen 2026-10-11, assumption FA-5 in ASSUMPTIONS.md).
`timescale 1ns/1ps
module csr_file_fv_env (
    input wire clk_i,
    input wire rst_n_i
);
    reg started = 1'b0;
    always @(posedge clk_i) started <= 1'b1;
    always @(*) if (!started) assume (!rst_n_i);
endmodule

bind csr_file csr_file_fv_env u_fv_env (.clk_i(clk_i), .rst_n_i(rst_n_i));
