// =============================================================================
// rdc1_top.sv -- formal harness for RDC-1: core + the real Debug Module.
//
// Every DMI request (so any sequence of haltreq / resumereq / hartreset / dmactive
// writes), every bus response on both core ports, every interrupt input is free.
// The bus (and the Debug Module) reset only at the start: the properties are
// judged with the BUS reset, never with the hart reset -- that is exactly why
// the simulation checkers missed RDC-1 for so long (they were on the same reset).
// HALT_TIMEOUT is the production value; a forced grant is flagged sticky in
// haltinfo.haltforced and every property is required only while no grant has
// ever been forced (the forced reset is the documented, flagged fallback).
//
// Properties (all PROVEN on the fixed RTL; the negative control
// mutants/debug_module_rawgrant.v -- hartreset_o following the raw request, the
// pre-fix behaviour -- must FAIL):
//   a_d_hwdata_stable   a waited write data phase keeps HWDATA
//   a_d_addr_stable     a waited D-port address phase keeps HTRANS/HADDR/HWRITE/HSIZE
//   a_i_addr_stable     a waited I-port address phase keeps HTRANS/HADDR
//   a_grant_only_safe   the hart reset is granted only at a safe point
// Assumptions: ASSUMPTIONS.md FA-6 (start-up reset), FA-7 (AHB-legal ERROR).
// =============================================================================
`timescale 1ns/1ps
module rdc1_top (
    input wire        clk,
    input wire        rst_n,                 // bus + DM reset (start-up only, FA-6)
    // DMI, free
    input wire        dmi_req,
    input wire [6:0]  dmi_addr,
    input wire [31:0] dmi_wdata,
    input wire [1:0]  dmi_op,
    // slave responses, free
    input wire [31:0] i_hrdata, d_hrdata,
    input wire        i_hready, i_hresp, d_hready, d_hresp,
    // interrupts, free
    input wire        irq_valid,
    input wire [4:0]  irq_id,
    input wire [7:0]  irq_lvl,
    input wire        mtip
);
    wire [31:0] i_haddr, i_hwdata, d_haddr, d_hwdata;
    wire [1:0]  i_htrans, d_htrans;
    wire [2:0]  i_hsize, i_hburst, d_hsize, d_hburst;
    wire [3:0]  i_hprot, d_hprot;
    wire        i_hwrite, d_hwrite;
    wire [47:0] acc0, acc1, acc2;
    wire        dsu_ovf, core_sleep, hartreset, ndmreset, halt_req, halt_safe;
    wire [31:0] dmi_rdata, sba_addr, sba_wdata;
    wire        dmi_done, sba_start, sba_write;

    garuda_core_top #(.RESET_VECTOR(32'h1000_0000), .CLK_GATE(0)) u_core (
        .clk_i(clk), .core_rst_n_i(rst_n), .hartreset_n_i(~hartreset),
        .halt_req_i(halt_req), .halt_safe_o(halt_safe),
        .i_haddr_o(i_haddr), .i_htrans_o(i_htrans), .i_hsize_o(i_hsize), .i_hburst_o(i_hburst),
        .i_hprot_o(i_hprot), .i_hwrite_o(i_hwrite), .i_hwdata_o(i_hwdata),
        .i_hrdata_i(i_hrdata), .i_hready_i(i_hready), .i_hresp_i(i_hresp),
        .d_haddr_o(d_haddr), .d_htrans_o(d_htrans), .d_hsize_o(d_hsize), .d_hburst_o(d_hburst),
        .d_hprot_o(d_hprot), .d_hwrite_o(d_hwrite), .d_hwdata_o(d_hwdata),
        .d_hrdata_i(d_hrdata), .d_hready_i(d_hready), .d_hresp_i(d_hresp),
        .clic_irq_valid_i(irq_valid), .clic_irq_id_i(irq_id), .clic_irq_level_i(irq_lvl),
        .mtip_i(mtip), .dbg_acc_0_o(acc0), .dbg_acc_1_o(acc1), .dbg_acc_2_o(acc2),
        .dsu_ovf_o(dsu_ovf), .core_sleep_o(core_sleep));

    debug_module u_dm (
        .hclk_i(clk), .dm_rst_n_i(rst_n),
        .req_i(dmi_req), .addr_i(dmi_addr), .wdata_i(dmi_wdata), .op_i(dmi_op),
        .rdata_o(dmi_rdata), .done_o(dmi_done),
        .ndmreset_o(ndmreset), .hartreset_o(hartreset),
        .halt_req_o(halt_req), .halt_safe_i(halt_safe),
        .dsu_acc0_i(acc0), .dsu_acc1_i(acc1), .dsu_acc2_i(acc2), .dsu_ovf_i(dsu_ovf),
        .sba_start_o(sba_start), .sba_write_o(sba_write), .sba_addr_o(sba_addr),
        .sba_wdata_o(sba_wdata), .sba_done_i(1'b0), .sba_err_i(1'b0),
        .sba_rdata_i(32'd0), .sba_busy_i(1'b0));

    // ---- FA-6: reset at start-up only ---------------------------------------------
    reg started = 1'b0;
    always @(posedge clk) started <= 1'b1;
    always @(*) begin
        if (!started) assume (!rst_n);
        else          assume (rst_n);
    end
    // ---- FA-7: an ERROR response is AHB's two-cycle response: its first cycle
    // (HRESP=1, HREADY=0) always precedes its second (HRESP=1, HREADY=1) ----------
    reg i_err1, d_err1;
    always @(posedge clk) begin
        i_err1 <= i_hresp & ~i_hready;
        d_err1 <= d_hresp & ~d_hready;
    end
    always @(*) if (started) begin
        assume (!(i_hresp & i_hready) || i_err1);
        assume (!(d_hresp & d_hready) || d_err1);
        assume (!i_err1 || (i_hresp & i_hready));
        assume (!d_err1 || (d_hresp & d_hready));
    end

    // ---- previous-cycle state, on the BUS reset only ---------------------------------
    reg        d_wphase, q_d_wwait, q_d_await, q_i_await, q_safe, q_hart;
    reg [31:0] q_d_hwdata, q_d_haddr, q_i_haddr;
    reg [1:0]  q_d_htrans, q_i_htrans;
    reg        q_d_hwrite;
    reg [2:0]  q_d_hsize;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            d_wphase <= 1'b0; q_d_wwait <= 1'b0; q_d_await <= 1'b0; q_i_await <= 1'b0;
            q_safe <= 1'b0; q_hart <= 1'b0;
            q_d_hwdata <= '0; q_d_haddr <= '0; q_i_haddr <= '0;
            q_d_htrans <= '0; q_i_htrans <= '0; q_d_hwrite <= 1'b0; q_d_hsize <= '0;
        end else begin
            if (d_hready) d_wphase <= d_htrans[1] & d_hwrite;
            q_d_wwait  <= d_wphase & ~d_hready;          // a waited write data phase
            q_d_await  <= d_htrans[1] & ~d_hready;       // a waited D-port address phase
            q_i_await  <= i_htrans[1] & ~i_hready;       // a waited I-port address phase
            q_safe     <= halt_safe;
            q_hart     <= hartreset;
            q_d_hwdata <= d_hwdata; q_d_haddr <= d_haddr; q_d_htrans <= d_htrans;
            q_d_hwrite <= d_hwrite; q_d_hsize <= d_hsize;
            q_i_haddr  <= i_haddr;  q_i_htrans <= i_htrans;
        end
    wire unforced = !u_dm.haltforced;

    a_d_hwdata_stable: assert property (@(posedge clk) disable iff (!rst_n)
        !(q_d_wwait && unforced) || (d_hwdata == q_d_hwdata));
    a_d_addr_stable: assert property (@(posedge clk) disable iff (!rst_n)
        !(q_d_await && unforced) ||
        (d_htrans == q_d_htrans && d_haddr == q_d_haddr && d_hwrite == q_d_hwrite && d_hsize == q_d_hsize));
    a_i_addr_stable: assert property (@(posedge clk) disable iff (!rst_n)
        !(q_i_await && unforced) || (i_htrans == q_i_htrans && i_haddr == q_i_haddr));
    a_grant_only_safe: assert property (@(posedge clk) disable iff (!rst_n)
        !(hartreset && !q_hart && unforced) || q_safe);

    c_halt_on_waited_store: cover property (@(posedge clk) disable iff (!rst_n) halt_req && d_wphase && !d_hready);
    c_grant_safe:           cover property (@(posedge clk) disable iff (!rst_n) hartreset && !q_hart && unforced);
    c_resume:               cover property (@(posedge clk) disable iff (!rst_n) !hartreset && q_hart);
endmodule
