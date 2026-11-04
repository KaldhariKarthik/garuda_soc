`timescale 1ns/1ps
// =============================================================================
// tb_dmi_cdc.sv -- the tck <-> hclk crossing in simulation (Track A plan 6A.5 G2).
// The REAL dmi_cdc and debug_module; on tck a requester with the DTM's protocol
// (toggle only when not busy, payload held, ack seen through the 2-flop
// synchroniser, response taken when the ack is seen), so the timing can be placed
// exactly. Every acknowledged request is checked: a read returns what the DM held
// when it answered, and the DM executed the request before it was acknowledged.
//
//   T1 normal traffic at several clock ratios, no resets: every ack genuine
//   T2 DBG-6: a DM-only reset (watchdog / software reset: dm_rst_n low, POR not)
//      while the requester is idle with toggle parity 1, tck faster than hclk; the
//      next request must not be acknowledged before the DM executed it
//   T3 the same reset with parity 0 (control: no fake ack possible)
// =============================================================================
module tb_dmi_cdc;
    reg tck = 0, hclk = 0, por_n = 0, dm_rst_n = 0;
    real th = 50.0, hh = 2.0;                    // half periods (ns): tck 10 MHz, hclk 250 MHz
    always #(th) tck = ~tck;
    always #(hh) hclk = ~hclk;

    // ---- requester (DTM protocol) on tck ----------------------------------------------
    reg        req_tgl = 0, ack_seen = 0;
    reg [6:0]  req_addr = 0;
    reg [31:0] req_data = 0, rsp = 0;
    reg [1:0]  req_op = 0;
    wire       ack_sync;
    wire       busy = (req_tgl != ack_seen);
    integer    n_acked = 0;   // (reported, not checked)
    always @(posedge tck or negedge por_n)
        if (!por_n) begin req_tgl <= 0; ack_seen <= 0; end
        else if (busy && ack_sync == req_tgl) begin
            ack_seen <= ack_sync; rsp <= dm_rdata; n_acked <= n_acked + 1;
        end

    // ---- DUT: crossing + Debug Module ---------------------------------------------------
    wire        req_pulse, dm_done, ack_tgl, ndmreset, hartreset, halt_req;
    wire [31:0] dm_rdata;
    wire        sba_start, sba_write;
    wire [31:0] sba_addr, sba_wdata;
    dmi_cdc u_cdc (.tck_i(tck), .tck_rst_n_i(por_n), .req_tgl_i(req_tgl), .ack_tgl_sync_o(ack_sync),
        .hclk_i(hclk), .hrst_n_i(dm_rst_n), .req_pulse_o(req_pulse), .ack_pulse_i(dm_done), .ack_tgl_o(ack_tgl));
    debug_module u_dm (.hclk_i(hclk), .dm_rst_n_i(dm_rst_n), .req_i(req_pulse), .addr_i(req_addr),
        .wdata_i(req_data), .op_i(req_op), .rdata_o(dm_rdata), .done_o(dm_done),
        .ndmreset_o(ndmreset), .hartreset_o(hartreset), .halt_req_o(halt_req), .halt_safe_i(1'b1),
        .dsu_acc0_i(48'h0000_1111_2222), .dsu_acc1_i(48'd0), .dsu_acc2_i(48'd0), .dsu_ovf_i(1'b0),
        .sba_start_o(sba_start), .sba_write_o(sba_write), .sba_addr_o(sba_addr), .sba_wdata_o(sba_wdata),
        .sba_done_i(1'b0), .sba_err_i(1'b0), .sba_rdata_i(32'd0), .sba_busy_i(1'b0));

    // ---- what the DM really executed (hclk side) ------------------------------------------
    integer n_exec = 0;
    reg     exec_after_ack = 0;
    reg [31:0] last_answer;
    always @(posedge hclk) if (dm_rst_n && req_pulse) n_exec <= n_exec + 1;
    always @(posedge hclk) if (dm_done) last_answer <= dm_rdata;

    integer checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask

    // issue one request at a tck falling edge and wait for its acknowledgement
    task automatic request(input [6:0] a, input [31:0] d, input [1:0] o, output [31:0] r,
                           output integer exec_at_issue, output integer exec_at_ack);
        @(negedge tck);
        while (busy) @(negedge tck);
        req_addr = a; req_data = d; req_op = o; exec_at_issue = n_exec;
        @(posedge tck); req_tgl <= ~req_tgl;
        @(posedge tck);
        while (busy) @(posedge tck);
        #1; r = rsp; exec_at_ack = n_exec;
    endtask

    localparam [6:0] A_DMCONTROL = 7'h10, A_ACC0L = 7'h60, A_SBADDR0 = 7'h39;
    reg [31:0] r;
    integer e0, e1, k, fake;
    initial begin
        $display("=== tb_dmi_cdc: tck <-> hclk crossing, real dmi_cdc + debug_module ===");
        #333; por_n = 1; #60; dm_rst_n = 1;
        // ---- T1 normal traffic at several ratios -------------------------------------------
        fake = 0;
        for (k = 0; k < 24; k++) begin
            th = (k % 3 == 0) ? 50.0 : (k % 3 == 1) ? 3.1 : 1.3;      // tck slower, similar, faster than hclk
            request(A_DMCONTROL, 32'h1, 2'd2, r, e0, e1);              // write dmactive
            // a different word every iteration (sbaddress0; sbreadonaddr is 0, so no bus access),
            // so a stale response from the previous read cannot look right (TB-A12, 2026-11-01)
            request(A_SBADDR0, 32'hA500_0000 | k, 2'd2, r, e0, e1);
            request(A_SBADDR0, 0, 2'd1, r, e0, e1);
            if (r !== (32'hA500_0000 | k) || r !== last_answer || e1 != e0 + 1) fake++;
            request(A_ACC0L, 0, 2'd1, r, e0, e1);
            if (r !== 32'h1111_2222 || r !== last_answer || e1 != e0 + 1) fake++;
        end
        check(fake == 0, "T1: 24 x (write + read) at three clock ratios: every read genuine, each executed once before its ack");
        th = 50.0;

        // ---- T2 DBG-6: DM-only reset with the requester idle at parity 1 ----------------------
        // make the toggle parity 1 (an odd number of requests so far is not guaranteed: count)
        if (req_tgl == 1'b0) request(A_DMCONTROL, 32'h1, 2'd2, r, e0, e1);
        // DBG-6 needs tck not much slower than hclk (a fast JTAG adapter, or hclk divided down):
        // with tck at 10 MHz and hclk at 250 MHz the DM executes before the stale ack is used.
        // Here tck runs faster than hclk; the DM reset spans several tck edges, so the
        // synchroniser samples ack at its reset value; the next request follows at once.
        th = 1.3;
        // a marker the DM reset clears: a stale (pre-reset) answer would carry it
        request(A_SBADDR0, 32'h5EA1_0000, 2'd2, r, e0, e1);
        if (req_tgl == 1'b0) request(A_SBADDR0, 32'h5EA1_0000, 2'd2, r, e0, e1);   // parity back to 1
        @(posedge tck);
        dm_rst_n = 0; #12; dm_rst_n = 1;                     // 3 hclk cycles of DM reset
        request(A_DMCONTROL, 32'h1, 2'd2, r, e0, e1);        // the debugger restarts the session (spec 6.4)
        check(e1 == e0 + 1, "T2 DBG-6: after a DM-only reset the next request is executed before it is acknowledged");
        request(A_SBADDR0, 0, 2'd1, r, e0, e1);
        check(r === 32'd0 && r === last_answer && e1 == e0 + 1,
              "T2 DBG-6: the read after it returns the DM's post-reset answer (sbaddress0 = 0, not the marker)");

        // ---- T3 control: same reset at parity 0 ---------------------------------------------------
        if (req_tgl == 1'b1) request(A_DMCONTROL, 32'h1, 2'd2, r, e0, e1);
        @(posedge tck);
        dm_rst_n = 0; #12; dm_rst_n = 1;
        request(A_DMCONTROL, 32'h1, 2'd2, r, e0, e1);
        check(e1 == e0 + 1, "T3 control: parity 0, the next request is executed before it is acknowledged");

        $display("tb_dmi_cdc: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end
    initial begin #2_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
