//dsu_stall.v

`timescale 1ns / 1ps
`include "dsu_defs.vh"

module dsu_stall (
    input wire clk,
    input wire rst_n,
    input wire flush,
    
    input wire [4:0] funct5,
    input wire [2:0] funct3,
    input wire       is_custom0,
    input wire [1:0] acc_sel,
    
    output wire dsu_busy
);

    wire cur_is_rtype = is_custom0 & (funct3 == 3'b000);
    wire cur_is_itype = is_custom0 & (funct3 == 3'b001);
    
    wire cur_is_2cycle = cur_is_rtype & ((funct5 == `FUNCT5_MACRD_LO) | (funct5 == `FUNCT5_MACRD_HI) | (funct5 == `FUNCT5_MACSAT));
    wire cur_reads_acc = (cur_is_rtype & ((funct5 == `FUNCT5_MACRD_LO) | (funct5 == `FUNCT5_MACRD_HI) | (funct5 == `FUNCT5_MACSAT))) | cur_is_itype;
    
    reg       prev_was_2cycle;
    reg [1:0] prev_acc_sel;
    
    wire stall_now;
    
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            prev_was_2cycle <= 1'b0;
            prev_acc_sel <= 2'b00;
        end
        else if (flush) begin   
            prev_was_2cycle <= 1'b0;
            prev_acc_sel <= 2'b00;
        end
        else if (~stall_now) begin
            prev_was_2cycle <= cur_is_2cycle;
            prev_acc_sel <= acc_sel;
        end
    end
    
    assign stall_now = prev_was_2cycle & cur_reads_acc & (acc_sel == prev_acc_sel);
    
    assign dsu_busy = stall_now;
         
endmodule        
