//overflow_flag.b
//sticky overflow status register.
//Sets on any MAC overlfow or saruration event.
//Cleared by CSR write (csr_clear_overflow pulse)

`timescale 1ns / 1ps

module overflow_flag (
    input wire       clk,
    input wire       rst_n,
    input wire [2:0] mac_overflow,
    input wire       sat_overflow,
    input wire       csr_clear_overflow,
    
    output reg dsu_overflow
);

    wire any_ovf = (|mac_overflow) | sat_overflow;
    
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)                   dsu_overflow <= 1'b0;
        else if (csr_clear_overflow) dsu_overflow <= 1'b0;
        else if (any_ovf)            dsu_overflow <= 1'b1;
    end
    
endmodule
