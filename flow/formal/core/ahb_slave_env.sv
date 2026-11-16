// =============================================================================
// ahb_slave_env.sv - what an AHB-Lite slave may answer, as assumptions on the
// two bus ports of the core (formal only; used by pipe_ctrl_core.tcl).
//
// AMBA 3 AHB-Lite, section 5.1: a transfer's response comes in its data phase.
//   - With no data phase outstanding the response is OKAY.
//   - A master presenting nothing, with no data phase outstanding, sees HREADY high.
//   - A master presenting an address with no data phase outstanding may see HREADY
//     low: GARUDA's interconnect holds an ungranted master's address phase until the
//     arbiter grants it (rtl/ahb/ahb_master_port.v, hready_o; GARUDA-SYS Sec. 7.3).
//     Until 2026-11-16 this file assumed HREADY high whenever no data phase was
//     outstanding, which ruled that wait out of every whole-core proof (and left the
//     D-port's a_dport_addr_stable vacuous here).
//   - An ERROR response takes two cycles: HRESP high with HREADY low, then
//     HRESP high with HREADY high. HRESP is never high in any other way.
// Wait states are free: HREADY may stay low for any number of cycles.
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

    env_idle_ready:  assume property (@(posedge clk) disable iff (!rst_n) (!dph && !htrans[1]) |-> hready);
    env_idle_okay:   assume property (@(posedge clk) disable iff (!rst_n) !dph |-> !hresp);
    env_err_first:   assume property (@(posedge clk) disable iff (!rst_n) (hresp && !hready) |=> (hresp && hready));
    env_err_second:  assume property (@(posedge clk) disable iff (!rst_n) (hresp && hready) |-> $past(hresp && !hready));
endmodule

bind garuda_core_top ahb_slave_env u_env_i (.clk(clk_i), .rst_n(core_rst_n_i), .htrans(i_htrans_o), .hready(i_hready_i), .hresp(i_hresp_i));
bind garuda_core_top ahb_slave_env u_env_d (.clk(clk_i), .rst_n(core_rst_n_i), .htrans(d_htrans_o), .hready(d_hready_i), .hresp(d_hresp_i));
