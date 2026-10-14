// apb_div_fv.sv -- formal top: ahb2apb_bridge with every APB_DIV value in use
// (bus plan B2, R-5 / a_apb_div). Windows 0..11 take /1, /2, /4, /8 in turn
// (2 bits per window: 00 01 10 11 -> 24'hE4E4E4), all twelve windows present.
`timescale 1ns/1ps
module apb_div_fv (
    input  wire        hclk_i, hreset_n_i, pclk_i, preset_n_i, pclk_phase_i,
    input  wire        hsel_i,
    input  wire [31:0] haddr_i,
    input  wire [1:0]  htrans_i,
    input  wire        hwrite_i,
    input  wire [2:0]  hsize_i,
    input  wire [31:0] hwdata_i,
    input  wire        hready_i,
    output wire [31:0] hrdata_o,
    output wire        hreadyout_o, hresp_o,
    output wire [11:0] psel_o,
    output wire        penable_o, pwrite_o,
    output wire [11:0] paddr_o,
    output wire [31:0] pwdata_o,
    input  wire [12*32-1:0] prdata_i,
    input  wire [11:0] pready_i, pslverr_i
);
    ahb2apb_bridge #(.WINDOW_MASK(16'h0FFF), .APB_DIV(24'hE4E4E4)) u_br (
        .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .pclk_i(pclk_i), .preset_n_i(preset_n_i),
        .pclk_phase_i(pclk_phase_i), .hsel_i(hsel_i), .haddr_i(haddr_i), .htrans_i(htrans_i),
        .hwrite_i(hwrite_i), .hsize_i(hsize_i), .hwdata_i(hwdata_i), .hready_i(hready_i),
        .hrdata_o(hrdata_o), .hreadyout_o(hreadyout_o), .hresp_o(hresp_o),
        .psel_o(psel_o), .penable_o(penable_o), .pwrite_o(pwrite_o), .paddr_o(paddr_o),
        .pwdata_o(pwdata_o), .prdata_i(prdata_i), .pready_i(pready_i), .pslverr_i(pslverr_i));
endmodule
