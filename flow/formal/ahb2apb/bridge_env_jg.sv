// =============================================================================
// bridge_env_jg.sv -- the JasperGold form of the bridge's formal environment
// (2026-11-21, TOOL-A34). The same assumptions as tb/ahb2apb/formal/apb_fv_env.sv,
// which the SymbiYosys suite (tb/ahb2apb/formal/apb.toml) uses, written as concurrent
// assumptions: that file relies on initial values and immediate assumes, which
// JasperGold does not read the same way. Reset is JasperGold's own (`reset` in
// bridge_fpv.tcl): both resets are held for the reset phase and released together
// (FB-1; the split-reset gap of [N-9.2] is the simulation test t_apb_reset_skew).
// Unlike the SBY suite, pclk here is hclk / 2 as on the chip.
//   FB-2 AHB-Lite master: HTRANS IDLE or NONSEQ (GARUDA's masters send no BUSY or
//        SEQ into the bridge region); HSIZE at most a word; an address phase
//        presented while HREADY is low is held; HWDATA is held through the bridge's
//        data phase.
//   FB-3 global HREADY: during the bridge's own data phase it is the bridge's
//        HREADYOUT; otherwise free.
// The APB targets (PREADY, PSLVERR, PRDATA) stay completely free.
// =============================================================================
module bridge_env_jg (
    input wire        hclk,
    input wire        hreset_n,
    input wire        hsel_i,
    input wire [31:0] haddr_i,
    input wire [1:0]  htrans_i,
    input wire        hwrite_i,
    input wire [2:0]  hsize_i,
    input wire [31:0] hwdata_i,
    input wire        hready_i,
    input wire        hreadyout_o
);
    reg dp;  // the bridge owns the data phase
    always @(posedge hclk or negedge hreset_n) begin
        if (!hreset_n)    dp <= 1'b0;
        else if (hready_i) dp <= hsel_i && htrans_i[1];
    end

    default clocking cb @(posedge hclk); endclocking
    default disable iff (!hreset_n);

    assume_fb2_trans: assume property (htrans_i == 2'b00 || htrans_i == 2'b10);
    assume_fb2_size:  assume property (hsize_i <= 3'd2);
    assume_fb2_hold:  assume property ((htrans_i[1] && !hready_i) |=>
        (htrans_i == $past(htrans_i) && haddr_i == $past(haddr_i) && hsize_i == $past(hsize_i) &&
         hwrite_i == $past(hwrite_i) && hsel_i == $past(hsel_i)));
    assume_fb2_wdata: assume property ((dp && !hready_i) |=> hwdata_i == $past(hwdata_i));
    assume_fb3_ready: assume property (dp |-> hready_i == hreadyout_o);
endmodule

bind ahb2apb_bridge bridge_env_jg u_jg_env (.hclk(hclk), .hreset_n(hreset_n), .hsel_i(hsel_i),
    .haddr_i(haddr_i), .htrans_i(htrans_i), .hwrite_i(hwrite_i), .hsize_i(hsize_i),
    .hwdata_i(hwdata_i), .hready_i(hready_i), .hreadyout_o(hreadyout_o));
