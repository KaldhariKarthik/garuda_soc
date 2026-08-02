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
        // ERRATUM DSU-8 (FLAG-E) -- an overflow coinciding with its own clear
        // was LOST. Clear had absolute priority, so a poll-and-clear loop
        // silently dropped any overflow landing on the clear cycle. Standard
        // sticky-status semantics (and RISC-V W1C bits) clear the ACCUMULATED
        // flag while still recording an event in the same cycle, so the clear
        // now takes `any_ovf` rather than zero. Software can still always
        // clear the flag: it just cannot clear an overflow that has not
        // happened yet.
        if(!rst_n)                   dsu_overflow <= 1'b0;
        else if (csr_clear_overflow) dsu_overflow <= any_ovf;
        else if (any_ovf)            dsu_overflow <= 1'b1;
    end
    
endmodule
