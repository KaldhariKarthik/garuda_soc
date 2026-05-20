//dsu_top.v

`timescale 1ns / 1ps
`include "dsu_defs.vh"

module dsu_top (
    input wire clk,
    input wire rst_n,
    input wire flush,
    
    input wire        dsu_en,
    input wire [31:0] instr,
    input wire [31:0] rs1,
    input wire [31:0] rs2,
    input wire        csr_clear_overflow,
    
    output wire        dsu_busy,
    output wire [31:0] dsu_rd_data,
    output wire        dsu_rd_valid,
    output wire [4:0] dsu_rd_addr,
    output wire       dsu_overflow,
    output wire       illegal_instr,
    
    output wire [47:0] dbg_acc_0,
    output wire [47:0] dbg_acc_1,
    output wire [47:0] dbg_acc_2
);

    wire [`MAC_CTRL_W-1:0] control;
    wire [1:0]             acc_sel;
    wire                   sat_op;
    wire                   shift_op;
    wire [5:0]             shift_amt;
    wire                   shift_dir;
    wire [1:0]             shift_acc_sel;
    wire                   rd_lo_op;
    wire                   rd_hi_op;
    wire [1:0]             result_src;
    wire                   writes_regfile;
    wire [4:0]             rd_addr_w;
    wire [4:0]             funct5_w;
    wire [2:0]             funct3_w; 
    wire                   is_custom0_w;
    
    dsu_decoder u_decoder (
        .instr (instr),
        .dsu_en (dsu_en),
        .flush (flush),
        .control (control),
        .acc_sel (acc_sel),
        .sat_op (sat_op),
        .shift_op (shift_op),
        .shift_amt (shift_amt),
        .shift_dir (shift_dir),
        .shift_acc_sel (shift_acc_sel),
        .rd_lo_op (rd_lo_op),
        .rd_hi_op (rd_hi_op),
        .result_src (result_src),
        .writes_regfile (writes_regfile),
        .rd_addr (rd_addr_w),
        .illegal_instr (illegal_instr),
        .funct5 (funct5_w),
        .funct3 (funct3_w),
        .is_custom0 (is_custom0_w)
    );
    
    wire [47:0] cluster_out;
    wire [47:0] sat_writeback;
    wire satwriteback_en;
    wire sat_overflow;
    
    saturation_unit u_sat (
        .cluster_out (cluster_out),
        .sat_op (sat_op),
        .sat_writeback (sat_writeback),
        .sat_writeback_en (sat_writeback_en),
        .sat_overflow (sat_overflow)
    );
    
    wire [2:0] mac_overflow;
    
    mac_cluster u_cluster (
        .clk (clk),
        .rst_n (rst_n),
        .rs1 (rs1),
        .rs2 (rs2),
        .control (control),
        .acc_sel (acc_sel),
        .sat_writeback (sat_writeback),
        .sat_writeback_en (sat_writeback_en),
        .cluster_out (cluster_out),
        .overflow (overflow),
        .dbg_acc_0 (dbg_acc_0),
        .dbg_acc_1 (dbg_acc_1),
        .dbg_acc_2 (dbg_acc_2)        
    );
    
    reg [47:0] shift_input;
    always @(*) begin
        case (shift_acc_sel)
            `ACC_FX:  shift_input = dbg_acc_0;
            `ACC_FY:  shift_input = dbg_acc_1;
            `ACC_MAG: shift_input = dbg_acc_2;
            default:  shift_input = 48'b0;
        endcase
     end
     
     wire [31:0] shift_result;
     barrel_shifter u_shifter (
        .cluster_out (cluster_out),
        .shift_amt (shift_amt),
        .shift_dir (shift_dir),
        .shift_result (shift_result)
     ); 
    
    wire [31:0] rd_lo_data; 
    wire [31:0] rd_hi_data;
    
    readback_mux u_rbmux (
        .cluster_out (cluster_out),
        .rd_lo_op (rd_lo_op),
        .rd_hi_op (rd_hi_op),
        .shift_result (shift_result),
        .dsu_rd_data (dsu_rd_data)
    );
    
    result_selector u_rsel (
        .result_src (result_src),
        .rd_lo_data (rd_lo_data),
        .rd_hi_data (rd_hi_data),
        .shift_result (shift_result),
        .dsu_rd_data (dsu_rd_data)
    );
    
    overflow_flag u_ovf (
        .clk (clk),
        .rst_n (rst_n),
        .mac_overflow (mac_overflow),
        .sat_overflow (sat_overflow),
        .csr_clear_overflow (csr_clear_overflow),
        .dsu_overflow (dsu_overflow)
    );
    
    dsu_stall u_stall (
        .clk (clk),
        .rst_n (rst_n),
        .flush (flush),
        .funct5 (funct5_w),
        .funct3 (funct3_w),
        .is_custom0 (is_custom0_w),
        .acc_sel (acc_sel),
        .dsu_busy (dsu_busy)
    );
    
    assign dsu_rd_valid = writes_regfile & ~dsu_busy;
    assign dsu_rd_addr  = rd_addr_w;
    
endmodule
