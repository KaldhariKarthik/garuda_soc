`timescale 1ns/1ps
// mem_fv_top.sv - formal harness: the shared memory front end in front of a 16-word array.
// The front end and the array are the RTL of rtl/mem unchanged; only the size is small, so
// the proof of data integrity covers the array as well. The checker mem_sva is bound to
// ahb_mem_slave_if as in simulation.
module mem_fv_top #(parameter integer WRITABLE = 1) (
    input  wire        hclk_i, hreset_n_i,
    input  wire        hsel_i, hwrite_i, hready_i,
    input  wire [31:0] haddr_i, hwdata_i,
    input  wire [1:0]  htrans_i,
    input  wire [2:0]  hsize_i,
    input  wire        wr_lock_i, lock_bypass_i,
    output wire [31:0] hrdata_o,
    output wire        hreadyout_o, hresp_o
);
    wire ce, we; wire [3:0] addr; wire [3:0] be; wire [31:0] wdata, rdata;
    ahb_mem_slave_if #(.AW(4), .WRITABLE(WRITABLE)) u_if (
        .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .hsel_i(hsel_i), .haddr_i(haddr_i),
        .htrans_i(htrans_i), .hwrite_i(hwrite_i), .hsize_i(hsize_i), .hwdata_i(hwdata_i),
        .hready_i(hready_i), .hrdata_o(hrdata_o), .hreadyout_o(hreadyout_o), .hresp_o(hresp_o),
        .wr_lock_i(wr_lock_i), .lock_bypass_i(lock_bypass_i),
        .arr_ce_o(ce), .arr_addr_o(addr), .arr_we_o(we), .arr_be_o(be),
        .arr_wdata_o(wdata), .arr_rdata_i(rdata));
    sram_wrapper #(.WORDS(16), .AW(4), .ROM(WRITABLE == 0)) u_array (
        .clk(hclk_i), .ce(ce), .addr(addr), .wdata(wdata), .rdata(rdata), .we(we), .be(be));
    // the AHB master holds an address phase until it is accepted; while this slave owns the data
    // phase, the global HREADY is its own HREADYOUT
    assume_hold: assume property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (htrans_i[1] && !hready_i) |=> $stable({htrans_i, haddr_i, hwrite_i, hsize_i, hsel_i}));
    assume_own_dphase: assume property (@(posedge hclk_i) disable iff (!hreset_n_i)
        u_if.dp_valid |-> hready_i == hreadyout_o);
endmodule
