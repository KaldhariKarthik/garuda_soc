// dsu_fv_env.sv -- DSU formal environment (tb/dsu/formal/dsu.toml): reset low
// for the first 2 cycles, then high for good; every other input (instruction,
// operands, enable, flush, overflow clear) is free. Bound into dsu_top.
`timescale 1ns/1ps
module dsu_fv_env (input wire clk, input wire rst_n);
    reg [1:0] cyc = 2'd0;
    always @(posedge clk) if (cyc != 2'd3) cyc <= cyc + 2'd1;
    always @(*) begin
        if (cyc < 2'd2) assume (!rst_n);
        else            assume (rst_n);
    end
endmodule
bind dsu_top dsu_fv_env u_fv_env (.clk(clk), .rst_n(rst_n));
