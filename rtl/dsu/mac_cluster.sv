//mac_cluster.v
//Three MAC instances
//Steers control to the mac selected by acc_sel
//Saturation writeback comes from DSU-top Saturation and is
//routed to the selected MAC by the writeback router below

module mac_cluster
    import garuda_pkg::*;
    import dsu_pkg::*;
(
    input wire gclk,
    input wire core_rst_n,
    input wire [WORD_W-1:0] rs1_val,
    input wire [WORD_W-1:0] rs2_val,
    input wire [MAC_CTRL_W - 1:0] control,
    input wire [ACC_SEL_W-1:0] acc_sel,
    input wire [ACC_W-1:0] sat_writeback,
    input wire sat_writeback_en,
    output wire [ACC_W-1:0] cluster_out,
    output wire [NUM_ACC-1:0] overflow,
    // per unit: a fold commits this cycle (DSU-14)
    output wire [NUM_ACC-1:0] pending,
    output wire [ACC_W-1:0] dbg_acc_fx,
    output wire [ACC_W-1:0] dbg_acc_fy,
    output wire [ACC_W-1:0] dbg_acc_mag
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned EN_ONEHOT_W = 32'd3;
    localparam int unsigned SAT_WE_ONEHOT_W = 32'd3;

    wire ctrl_en     = control[MAC_CTRL_EN];
    wire ctrl_addsub = control[MAC_CTRL_ADDSUB];
    wire ctrl_clear  = control[MAC_CTRL_CLEAR];
    wire ctrl_load   = control[MAC_CTRL_LOAD];
    wire ctrl_abs    = control[MAC_CTRL_ABS];
    wire ctrl_dot    = control[MAC_CTRL_DOT];
    wire ctrl_flush  = control[MAC_CTRL_FLUSH];

    wire [EN_ONEHOT_W-1:0] en_onehot;
    assign en_onehot[0] = ctrl_en & (acc_sel == ACC_FX);
    assign en_onehot[1] = ctrl_en & (acc_sel == ACC_FY);
    assign en_onehot[2] = ctrl_en & (acc_sel == ACC_MAG);

    wire [SAT_WE_ONEHOT_W-1:0] sat_we_onehot;
    assign sat_we_onehot[0] = sat_writeback_en & (acc_sel == ACC_FX);
    assign sat_we_onehot[1] = sat_writeback_en & (acc_sel == ACC_FY);
    assign sat_we_onehot[2] = sat_writeback_en & (acc_sel == ACC_MAG);

    wire [ACC_W-1:0] mac_out_fx;
    wire [ACC_W-1:0] mac_out_fy;
    wire [ACC_W-1:0] mac_out_mag;

    mac_unit u_mac0 (
        .gclk              (gclk),
        .core_rst_n            (core_rst_n),
        .rs1_val              (rs1_val),
        .rs2_val              (rs2_val),
        .en               (en_onehot[0]),
        .add_sub          (ctrl_addsub),
        .clear            (ctrl_clear),
        .load             (ctrl_load),
        .abs_en           (ctrl_abs),
        .dot_en           (ctrl_dot),
        .flush            (ctrl_flush),
        .sat_writeback    (sat_writeback),
        .sat_writeback_en (sat_we_onehot[0]),
        .mac_out          (mac_out_fx),
        .overflow         (overflow[0]),
        .pending_o        (pending[0])
    );

    mac_unit u_mac1 (
        .gclk              (gclk),
        .core_rst_n            (core_rst_n),
        .rs1_val              (rs1_val),
        .rs2_val              (rs2_val),
        .en               (en_onehot[1]),
        .add_sub          (ctrl_addsub),
        .clear            (ctrl_clear),
        .load             (ctrl_load),
        .abs_en           (ctrl_abs),
        .dot_en           (ctrl_dot),
        .flush            (ctrl_flush),
        .sat_writeback    (sat_writeback),
        .sat_writeback_en (sat_we_onehot[1]),
        .mac_out          (mac_out_fy),
        .overflow         (overflow[1]),
        .pending_o        (pending[1])
    );

    mac_unit u_mac2 (
        .gclk              (gclk),
        .core_rst_n            (core_rst_n),
        .rs1_val              (rs1_val),
        .rs2_val              (rs2_val),
        .en               (en_onehot[2]),
        .add_sub          (ctrl_addsub),
        .clear            (ctrl_clear),
        .load             (ctrl_load),
        .abs_en           (ctrl_abs),
        .dot_en           (ctrl_dot),
        .flush            (ctrl_flush),
        .sat_writeback    (sat_writeback),
        .sat_writeback_en (sat_we_onehot[2]),
        .mac_out          (mac_out_mag),
        .overflow         (overflow[2]),
        .pending_o        (pending[2])
    );

    reg [ACC_W-1:0] cluster_out_r;
    always_comb begin : c_cluster_out
        case (acc_sel)
            ACC_FX: cluster_out_r = mac_out_fx;
            ACC_FY: cluster_out_r = mac_out_fy;
            ACC_MAG: cluster_out_r = mac_out_mag;
            default : cluster_out_r
                = 48'b000000000000000000000000000000000000000000000000;
        endcase
    end

    assign cluster_out = cluster_out_r;

    assign dbg_acc_fx = mac_out_fx;
    assign dbg_acc_fy = mac_out_fy;
    assign dbg_acc_mag = mac_out_mag;

endmodule
