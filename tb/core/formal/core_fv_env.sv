// core_fv_env.sv -- whole-core formal environment (tb/core/formal/*.toml).
// Both core resets low for the first 4 cycles, then high for good; every bus
// response, instruction word and interrupt is left free (the solver chooses
// the program and the bus behaviour). Assumption register: ASSUMPTIONS.md.
// Bound into garuda_core_top so it can constrain the top-level inputs.
`timescale 1ns/1ps
module core_fv_env (
    input wire clk_i,
    input wire core_rst_n_i,
    input wire hartreset_n_i
);
    reg [2:0] cyc = 3'd0;
    always @(posedge clk_i) if (cyc != 3'd7) cyc <= cyc + 3'd1;

    always @(*) begin
        if (cyc < 3'd4) begin
            assume (!core_rst_n_i);
            assume (!hartreset_n_i);
        end else begin
            assume (core_rst_n_i);
            assume (hartreset_n_i);
        end
    end
endmodule


bind garuda_core_top core_fv_env u_fv_env (.clk_i(clk_i), .core_rst_n_i(core_rst_n_i),
                                           .hartreset_n_i(hartreset_n_i));
