// old (b21ef9a) and new (8db2380) ahb2apb_bridge on the same inputs.
// pclk = hclk/2 (clock -factor 2, as in flow/formal/ahb2apb/bridge_fpv.tcl); one reset.
module bridge_miter import garuda_pkg::*; (
    input wire hclk, pclk, rst_n,
    input wire hsel_i, input wire [31:0] haddr_i, input wire [1:0] htrans_i,
    input wire hwrite_i, input wire [2:0] hsize_i, input wire [31:0] hwdata_i,
    input wire hready_i, input wire [12*32-1:0] prdata_i,
    input wire [11:0] pready_i, input wire [11:0] pslverr_i
);
    wire pclk_phase = 1'b0;   // not used by the bridge (as in bridge_fpv.tcl)
`define BRG_PORTS(p) \
        .hclk(hclk), .hreset_n(rst_n), .pclk(pclk), .preset_n(rst_n), .pclk_phase_i(pclk_phase), \
        .hsel_i(hsel_i), .haddr_i(haddr_i), .htrans_i(htrans_i), .hwrite_i(hwrite_i), \
        .hsize_i(hsize_i), .hwdata_i(hwdata_i), .hready_i(hready_i), \
        .hrdata_o(p``_hrdata), .hreadyout_o(p``_hreadyout), .hresp_o(p``_hresp), \
        .psel_o(p``_psel), .penable_o(p``_penable), .pwrite_o(p``_pwrite), .paddr_o(p``_paddr), \
        .pwdata_o(p``_pwdata), .prdata_i(prdata_i), .pready_i(pready_i), .pslverr_i(pslverr_i)
    wire [31:0] o_hrdata, n_hrdata, o_pwdata, n_pwdata;
    wire o_hreadyout, n_hreadyout, o_hresp, n_hresp, o_penable, n_penable, o_pwrite, n_pwrite;
    wire [APB_NWIN-1:0] o_psel, n_psel;
    wire [PADDR_W-1:0] o_paddr, n_paddr;
    ahb2apb_bridge_old u_old (`BRG_PORTS(o));
    ahb2apb_bridge     u_new (`BRG_PORTS(n));
    eq_hrdata:    assert property (@(posedge hclk) o_hrdata == n_hrdata);
    eq_hreadyout: assert property (@(posedge hclk) o_hreadyout == n_hreadyout);
    eq_hresp:     assert property (@(posedge hclk) o_hresp == n_hresp);
    eq_psel:      assert property (@(posedge hclk) o_psel == n_psel);
    eq_penable:   assert property (@(posedge hclk) o_penable == n_penable);
    eq_pwrite:    assert property (@(posedge hclk) o_pwrite == n_pwrite);
    eq_paddr:     assert property (@(posedge hclk) o_paddr == n_paddr);
    // PWDATA means something only in a write transfer (APB3 2.1)
    eq_pwdata_wr: assert property (@(posedge hclk) (|o_psel && o_pwrite) |-> o_pwdata == n_pwdata);
    // and the new bridge drives zero in a read (a_read_wdata_zero)
    new_zero_rd:  assert property (@(posedge hclk) (|n_psel && !n_pwrite) |-> n_pwdata == 32'd0);
    // the cycle the two differ in exists (the proof is not vacuous on PWDATA)
    c_differ:     cover property (@(posedge hclk) o_pwdata != n_pwdata);
endmodule
