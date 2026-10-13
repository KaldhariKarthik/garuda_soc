// =============================================================================
// ahb_slave_env.sv - what an AHB-Lite slave may answer, as assumptions on the
// two bus ports of the core (formal only; used by pipe_ctrl_core.tcl).
//
// AMBA 3 AHB-Lite, section 5.1: a transfer's response comes in its data phase.
//   - With no data phase outstanding the bus is ready and the response is OKAY.
//   - An ERROR response takes two cycles: HRESP high with HREADY low, then
//     HRESP high with HREADY high. HRESP is never high in any other way.
// Wait states are free: the slave may hold HREADY low for any number of cycles.
// =============================================================================
module ahb_slave_env (
    input wire       clk,
    input wire       rst_n,
    input wire [1:0] htrans,
    input wire       hready,
    input wire       hresp
);
    // a data phase is outstanding
    reg dph;
    always @(posedge clk or negedge rst_n)
        if (!rst_n)      dph <= 1'b0;
        else if (hready) dph <= htrans[1];

    env_idle_ready:  assume property (@(posedge clk) disable iff (!rst_n) !dph |-> (hready && !hresp));
    env_err_first:   assume property (@(posedge clk) disable iff (!rst_n) (hresp && !hready) |=> (hresp && hready));
    env_err_second:  assume property (@(posedge clk) disable iff (!rst_n) (hresp && hready) |-> $past(hresp && !hready));
endmodule

bind garuda_core_top ahb_slave_env u_env_i (.clk(clk_i), .rst_n(rst_n_i), .htrans(i_htrans_o), .hready(i_hready_i), .hresp(i_hresp_i));
bind garuda_core_top ahb_slave_env u_env_d (.clk(clk_i), .rst_n(rst_n_i), .htrans(d_htrans_o), .hready(d_hready_i), .hresp(d_hresp_i));
