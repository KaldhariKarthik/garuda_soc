// debug_fv_env.v -- step-clocked environment of the debug baseline proof, read with
// Yosys's Verilog frontend (yosys-slang ignores (* gclk *), 2026-10-16). Bound from
// tb/debug/formal/debug_fv_env.sv.
`timescale 1ns/1ps
module debug_fv_env #(parameter integer RST_TICKS = 14) (
    input wire por_n_i, dm_rst_n_i, tck_i, hclk_i
);
    // the solver's own step clock: (* gclk *) is honoured by Yosys's Verilog frontend
    // only, so this module is read with read_verilog (manifest pre_verilog)
    (* gclk *) wire gclk;
    reg [4:0] g = 5'd0;
    always @(posedge gclk) if (g != 5'd31) g <= g + 5'd1;
    always @(*) begin
        // FD-1: in reset both clocks are driven (7 rising edges each), so every $past register
        // holds a reset-time value when the reset ends; afterwards the clocks are free
        if (g < RST_TICKS) begin assume (!por_n_i); assume (!dm_rst_n_i);
                                 assume (tck_i == g[0]); assume (hclk_i == g[0]); end
        else               begin assume (por_n_i);  assume (dm_rst_n_i);  end
    end
endmodule
