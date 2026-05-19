//mac_cluster.v
//Three MAC instances
//Steers control to the mac selected by acc_sel
//Saturation writeback comes from DSU-top Saturation and is
//routed to the selected MAC by the writeback router below

`timescale 1ns / 1ps
`include "dsu_defs.vh"

module mac_cluster (
    input wire clk, 
    input wire rst_n,
    
    input wire [31:0] rs1,
    input wire [31:0] rs2, 
    
    input wire [`MAC_CTRL_W-1:0] control,
    input wire [1:0]             acc_sel,
    
    input wire [47:0] sat_writeback,
    input wire        sat_writeback_en,
    
    output wire [47:0] cluster_out,
    output wire [2:0]  overflow,
    
    output wire [47:0] dbg_acc_0,
    output wire [47:0] dbg_acc_1,
    output wire [47:0] dbg_acc_2
);

    wire ctrl_en     = control[`MAC_CTRL_EN];
    wire ctrl_addsub = control[`MAC_CTRL_ADDSUB];
    wire ctrl_clear  = control[`MAC_CTRL_CLEAR];
    wire ctrl_load   = control[`MAC_CTRL_LOAD];
    wire ctrl_abs    = control[`MAC_CTRL_ABS];
    wire ctrl_dot    = control[`MAC_CTRL_DOT];
    wire ctrl_flush  = control[`MAC_CTRL_FLUSH];
    
    wire [2:0] en_onehot;
    assign en_onehot[0] = ctrl_en & (acc_sel == `ACC_FX);
    assign en_onehot[1] = ctrl_en & (acc_sel == `ACC_FY);
    assign en_onehot[2] = ctrl_en & (acc_sel == `ACC_MAG);
    
    wire [2:0] sat_we_onehot;
    assign sat_we_onehot[0] = sat_writeback_en & (acc_sel == `ACC_FX);
    assign sat_we_onehot[1] = sat_writeback_en & (acc_sel == `ACC_FY);
    assign sat_we_onehot[2] = sat_writeback_en & (acc_sel == `ACC_MAG);
    
    wire [47:0] mac_out_0, mac_out_1, mac_out_2;
    
    mac_unit u_mac0 (
        .clk              (clk),
        .rst_n            (rst_n),
        .rs1              (rs1),
        .rs2              (rs2),
        .en               (en_onehot[0]),
        .add_sub          (ctrl_addsub),
        .clear            (ctrl_clear),
        .load             (ctrl_load),
        .abs_en           (ctrl_abs),
        .dot_en           (ctrl_dot),
        .flush            (ctrl_flush),
        .sat_writeback    (sat_writeback),
        .sat_writeback_en (sat_we_onehot[0]),
        .mac_out          (mac_out_0),
        .overflow         (overflow[0])
    );
    
    mac_unit u_mac1 (
        .clk              (clk),
        .rst_n            (rst_n),
        .rs1              (rs1),
        .rs2              (rs2),
        .en               (en_onehot[1]),
        .add_sub          (ctrl_addsub),
        .clear            (ctrl_clear),
        .load             (ctrl_load),
        .abs_en           (ctrl_abs),
        .dot_en           (ctrl_dot),
        .flush            (ctrl_flush),
        .sat_writeback    (sat_writeback),
        .sat_writeback_en (sat_we_onehot[1]),
        .mac_out          (mac_out_1),
        .overflow         (overflow[1])
    );
    
    mac_unit u_mac2 (
        .clk              (clk),
        .rst_n            (rst_n),
        .rs1              (rs1),
        .rs2              (rs2),
        .en               (en_onehot[2]),
        .add_sub          (ctrl_addsub),
        .clear            (ctrl_clear),
        .load             (ctrl_load),
        .abs_en           (ctrl_abs),
        .dot_en           (ctrl_dot),
        .flush            (ctrl_flush),
        .sat_writeback    (sat_writeback),
        .sat_writeback_en (sat_we_onehot[2]),
        .mac_out          (mac_out_2),
        .overflow         (overflow[2])
    );
    
    reg [47:0] cluster_out_r;
    always @(*) begin
        case (acc_sel)
            `ACC_FX:  cluster_out_r = mac_out_0;
            `ACC_FY:  cluster_out_r = mac_out_1;
            `ACC_MAG: cluster_out_r = mac_out_2;
            default: cluster_out_r = 48'b0;
        endcase
    end
    
    assign cluster_out = cluster_out_r;
    
    assign dbg_acc_0 = mac_out_0;
    assign dbg_acc_1 = mac_out_1;
    assign dbg_acc_2 = mac_out_2;
    
endmodule
