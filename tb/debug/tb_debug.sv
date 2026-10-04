`timescale 1ns/1ps
// =============================================================================
// tb_debug.sv -- Block 12 debug subsystem, Rev 4.0
//
// Spec: GARUDA-DEBUG-SPEC-001 §11. JTAG is bit-banged on the pins at 20 MHz,
// asynchronous to hclk (250 MHz), so every DMI access really crosses dmi_cdc.
// SBA reaches the real ISRAM (ILOCK set - SBA must bypass it), an AHB SRAM
// model standing in for DSRAM, and an error window.
//   5x TMS reset, IDCODE 0x0000_0DB1, DTMCS abits 7 / idle 5 / version 1
//   dmactive, dmstatus version/authenticated, haltreq/resumereq -> hartreset
//   ndmreset level out, abstractcs reads 0 (no progbuf, no data regs)
//   SBA write/read, autoincrement bulk, sbreadonaddr + sbreadondata stream
//   ILOCK bypass on ISRAM, sberror 2 (misaligned) / 3 (size) / 4 (bus error)
//   coherent 48-bit DSU tap read while the accumulator runs
//
// Added 2026-10-04 (stage-3 bug hunt):
//   TAP alive with hclk stopped and the DM in reset; 5x TMS from mid-scan states;
//   BYPASS really checked; DMI busy path (status 3 sticky, request refused);
//   DMI crossing scoreboard (every tck-side launch = exactly one hclk-side
//   request with the same payload) run at seven tck/hclk ratios with random
//   phase; hclk-only reset mid-session; tck stopped mid-handshake;
//   sbbusy / sbbusyerror; sbdata0 read in the cycle the transfer completes;
//   every unsupported sbaccess; dmactive=0 resets the DM; DSU hold registers.
// =============================================================================
module tb_debug;
    real hh = 2.0;                          // hclk half period (250 MHz at DIV2)
    reg  hclk = 0, hclk_en = 0;
    always #(hh) if (hclk_en) hclk = ~hclk;
    // TB-22: a reset has to arrive as an edge. Declared `= 0`, a reset is low
    // from time 0 with no negedge ever, so an async-reset flop whose clock is
    // not running - here every tck-side flop, and the hclk side until hclk_en -
    // is never reset. Both resets start high and fall at time 0.
    reg rst_n = 1;                          // hclk side: dm_rst_n and the slaves
    reg por_n = 1;                          // ext_rst_n pin: TAP/DTM power-on reset
    initial #0 begin rst_n = 1'b0; por_n = 1'b0; end
    reg tck = 0, tms = 1, tdi = 0;
    wire tdo, tdo_oe;

    wire ndmreset, hartreset;
    reg  [47:0] acc0 = 48'h1234_5678_9ABC, acc1 = 48'h0000_0000_0001, acc2 = 48'hFFFF_0000_0000;
    reg         ovf = 0;

    wire [31:0] haddr, hwdata, hrdata;
    wire [1:0]  htrans;
    wire        hwrite, hready, hresp;
    wire [2:0]  hsize, hburst;

    debug_top dut (
        .tck_i(tck), .tms_i(tms), .tdi_i(tdi), .tdo_o(tdo), .tdo_oe_o(tdo_oe), .por_n_i(por_n),
        .hclk_i(hclk), .dm_rst_n_i(rst_n), .ndmreset_o(ndmreset), .hartreset_o(hartreset),
        .dsu_acc0_i(acc0), .dsu_acc1_i(acc1), .dsu_acc2_i(acc2), .dsu_ovf_i(ovf),
        .haddr_o(haddr), .htrans_o(htrans), .hwrite_o(hwrite), .hsize_o(hsize),
        .hburst_o(hburst), .hwdata_o(hwdata), .hrdata_i(hrdata), .hready_i(hready),
        .hresp_i(hresp));

    // ---- slaves: ISRAM (real, locked) + DSRAM model --------------------------------
    wire sel_i = haddr[31:28] == 4'h0, sel_d = haddr[31:28] == 4'h2;
    reg  dsel;
    always @(posedge hclk) if (hready && htrans[1]) dsel <= sel_d;
    wire [31:0] rd_i, rd_d; wire ro_i, ro_d, re_i, re_d;
    assign hrdata = dsel ? rd_d : rd_i;
    assign hready = dsel ? ro_d : ro_i;
    assign hresp  = dsel ? re_d : re_i;

    reg [7:0] d_waits = 8'd2;               // DSRAM model wait states
    reg       d_rand  = 1'b1;

    isram_top u_isram (.hclk_i(hclk), .hreset_n_i(rst_n), .hsel_i(sel_i), .haddr_i(haddr),
        .htrans_i(htrans), .hwrite_i(hwrite), .hsize_i(hsize), .hburst_i(hburst),
        .hprot_i(4'h3), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(rd_i), .hreadyout_o(ro_i), .hresp_o(re_i),
        .ilock_i(1'b1), .hmaster_is_sba_i(1'b1));             // only SBA drives this bus
    ahb_lite_sram #(.BASE_ADDR(32'h2000_0000), .SIZE_BYTES(65536)) u_dsram (
        .hclk_i(hclk), .hreset_n_i(rst_n), .waits_i(d_waits), .rand_waits_i(d_rand), .seed_i(32'h7),
        .err_en_i(1'b1), .err_base_i(32'h2000_F000), .err_size_i(32'h10),
        .hsel_i(sel_d), .haddr_i(haddr), .htrans_i(htrans), .hwrite_i(hwrite),
        .hsize_i(hsize), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(rd_d), .hreadyout_o(ro_d), .hresp_o(re_d));

    wire [31:0] v_chk;
    ahb_lite_checker u_chk (.clk_i(hclk), .rst_n_i(rst_n),
        .haddr_i(haddr), .htrans_i(htrans), .hsize_i(hsize), .hburst_i(hburst),
        .hwrite_i(hwrite), .hwdata_i(hwdata), .hready_i(hready), .hresp_i(hresp),
        .viol_count_o(v_chk));

    // ---- JTAG bit-bang, TCK = 20 MHz unless a test changes th ----------------------
    real th = 25.0;                         // tck half period
    task automatic clk1(input bit m, input bit d, output bit q);
        tms = m; tdi = d; #(th); tck = 1; q = tdo; #(th); tck = 0;
    endtask
    task automatic tap_reset;
        bit q; repeat (5) clk1(1, 0, q); clk1(0, 0, q);        // -> Run-Test/Idle
    endtask
    task automatic idle(input int n); bit q; repeat (n) clk1(0, 0, q); endtask
    task automatic shift_ir(input [4:0] v);
        bit q;
        clk1(1, 0, q); clk1(1, 0, q); clk1(0, 0, q); clk1(0, 0, q);   // Sel-DR, Sel-IR, Cap-IR, Shift-IR
        for (int i = 0; i < 5; i++) clk1(i == 4, v[i], q);
        clk1(1, 0, q); clk1(0, 0, q);                                   // Update-IR, RTI
    endtask
    task automatic shift_dr(input [63:0] v, input int n, output [63:0] o);
        bit q;
        o = 0;
        clk1(1, 0, q); clk1(0, 0, q); clk1(0, 0, q);                  // Sel-DR, Cap-DR, Shift-DR
        for (int i = 0; i < n; i++) begin clk1(i == n - 1, v[i], q); o[i] = q; end
        clk1(1, 0, q); clk1(0, 0, q);                                   // Update-DR, RTI
    endtask

    // TDO is updated on the falling edge before each shift clock, so the bit
    // sampled at rising edge i is bit i of the captured register.
    reg [63:0] o;
    task automatic dmi(input [6:0] a, input [31:0] d, input [1:0] op, output [31:0] rd, output [1:0] st);
        reg [63:0] x;
        shift_dr({23'd0, a, d, op}, 41, x);
        idle(8);
        shift_dr({23'd0, a, 32'd0, 2'd0}, 41, x);              // nop: collect the result
        rd = x[33:2]; st = x[1:0];
        idle(4);
    endtask
    task automatic dmw(input [6:0] a, input [31:0] d); reg [31:0] r; reg [1:0] s; dmi(a, d, 2'd2, r, s); endtask
    task automatic dmr(input [6:0] a, output [31:0] r); reg [1:0] s; dmi(a, 0, 2'd1, r, s); endtask

    // One raw DMI scan: shifts a request in, returns what Capture-DR loaded
    // (the result and status of the PREVIOUS operation). No idle cycles added.
    task automatic dmi_scan(input [6:0] a, input [31:0] d, input [1:0] op, output [31:0] rd, output [1:0] st);
        reg [63:0] x;
        shift_dr({23'd0, a, d, op}, 41, x);
        rd = x[33:2]; st = x[1:0];
    endtask
    task automatic dtmcs_rd(output [31:0] v);                  // leaves IR = DMI
        reg [63:0] x;
        shift_ir(5'h10); shift_dr(0, 32, x); v = x[31:0]; shift_ir(5'h11);
    endtask
    task automatic dmireset;                                   // DTMCS.dmireset, leaves IR = DMI
        reg [63:0] x;
        shift_ir(5'h10); shift_dr(64'h1_0000, 32, x); shift_ir(5'h11);
    endtask

    integer checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask

    // ---- DMI crossing scoreboard ([N-7.15], BUGS CDC-1) -----------------------------
    // tck side: every toggle of the request line is one launched request, with
    // the payload the DTM holds at that moment. hclk side: every req pulse into
    // the Debug Module must be the oldest launch still outstanding, with exactly
    // that payload. A pulse with nothing outstanding is a duplicate; a launch
    // left in the queue is a lost request; a mismatch is a corrupted payload.
    reg [40:0] lq [$];
    reg [40:0] lq_e;
    integer n_launch = 0, n_pulse = 0, cdc_err = 0;
    always @(dut.u_dtm.req_tgl_o) if (por_n) begin
        #0.001;
        lq.push_back({dut.u_dtm.req_addr_o, dut.u_dtm.req_data_o, dut.u_dtm.req_op_o});
        n_launch = n_launch + 1;
    end
    always @(posedge hclk) if (rst_n && dut.u_dm.req_i) begin
        n_pulse = n_pulse + 1;
        if (lq.size() == 0) begin
            cdc_err = cdc_err + 1;
            $display("[CDC] request pulse with nothing launched (duplicate) t=%0t", $time);
        end else begin
            lq_e = lq.pop_front();
            if (lq_e !== {dut.u_dm.addr_i, dut.u_dm.wdata_i, dut.u_dm.op_i}) begin
                cdc_err = cdc_err + 1;
                $display("[CDC] payload changed in the crossing: launched %h, delivered %h t=%0t",
                         lq_e, {dut.u_dm.addr_i, dut.u_dm.wdata_i, dut.u_dm.op_i}, $time);
            end
        end
    end
    always @(negedge rst_n) lq.delete();     // an hclk-side reset drops what was in flight (D-18)

    // AHB transfers accepted from the SBA master, and its HSIZE
    integer n_xfer = 0, size_viol = 0;
    always @(posedge hclk) if (rst_n && hready && htrans[1]) begin
        n_xfer = n_xfer + 1;
        if (hsize !== 3'b010) size_viol = size_viol + 1;
    end
    // sbdata0 read arriving in the very cycle the SBA transfer completes
    integer win_hits = 0;
    always @(posedge hclk) if (rst_n && dut.u_dm.req_i && dut.u_dm.op_i == 2'd1 &&
                               dut.u_dm.addr_i == 7'h3C && dut.u_sba.done_o) win_hits = win_hits + 1;
    // DSU tap snapshots: the live value in the cycle the _lo register is read
    reg [47:0] snap0, snap1, snap2;
    always @(posedge hclk) if (rst_n && dut.u_dm.req_i && dut.u_dm.op_i == 2'd1) begin
        if (dut.u_dm.addr_i == 7'h60) snap0 = acc0;
        if (dut.u_dm.addr_i == 7'h62) snap1 = acc1;
        if (dut.u_dm.addr_i == 7'h64) snap2 = acc2;
    end

    // ---- a debugger that follows Debug 0.13 §6.1.5 ---------------------------------
    // Status 3 in a scan means the previous operation was still in progress and
    // THIS scan's request was ignored; the status is sticky until dmireset. The
    // debugger clears it, waits longer between scans and issues the scan again.
    integer nidle = 0, busy_seen = 0, ign_viol = 0;
    task automatic dbg_issue(input [6:0] a, input [31:0] d, input [1:0] op);
        reg [31:0] r; reg [1:0] st; integer l0;
        forever begin
            l0 = n_launch;
            dmi_scan(a, d, op, r, st);
            #0.01;
            if (st == 2'd3) begin
                busy_seen = busy_seen + 1;
                if (n_launch != l0) ign_viol = ign_viol + 1;   // refused request was launched anyway
                dmireset(); nidle = nidle + 1; idle(nidle);
            end else break;
        end
        idle(nidle);
    endtask
    task automatic dbg_collect(output [31:0] rd);
        reg [1:0] st;
        forever begin
            dmi_scan(7'h00, 0, 2'd0, rd, st);
            if (st == 2'd3) begin
                busy_seen = busy_seen + 1; dmireset(); nidle = nidle + 1; idle(nidle);
            end else break;
        end
    endtask

    // n write/readback rounds on sbaddress0 (a plain register while
    // sbreadonaddr = 0) at one tck/hclk ratio, each round at a random phase.
    task automatic cdc_stress(input real hh_, input real th_, input int n, input string name);
        reg [31:0] x, r; integer bad, l0, p0, b0, e0, i0;
        bad = 0; e0 = cdc_err; i0 = ign_viol; b0 = busy_seen;
        hh = hh_; th = th_; nidle = 0;
        idle(12); repeat (8) @(posedge hclk);
        l0 = n_launch; p0 = n_pulse;
        for (int k = 0; k < n; k++) begin
            #($urandom_range(1, 2000) * 0.001 * th_);           // random phase against hclk
            x = $urandom;
            dbg_issue(7'h39, x, 2'd2);
            if (k % 3 == 0) begin x = ~x; dbg_issue(7'h39, x, 2'd2); end   // back-to-back writes
            dbg_issue(7'h39, 0, 2'd1);
            dbg_collect(r);
            if (r !== x) begin bad++; $display("[CDC] %s: wrote %h, read back %h", name, x, r); end
        end
        idle(12); repeat (12) @(posedge hclk); #0.01;
        check(bad == 0 && cdc_err == e0 && lq.size() == 0 && (n_launch - l0) == (n_pulse - p0) && ign_viol == i0,
              $sformatf("[N-7.15] DMI crossing %s: %0d requests launched, %0d delivered, %0d readback errors, %0d lost, %0d duplicated/corrupted, %0d executed after a busy status (%0d busy retries)",
                        name, n_launch - l0, n_pulse - p0, bad, lq.size(), cdc_err - e0, ign_viol - i0, busy_seen - b0));
    endtask

    reg [31:0] r, lo, hi, s;
    reg [1:0]  st;
    int i, ok, l0, p0, x0, stale, w;

    // accumulators keep running during the tap tests
    always @(posedge hclk) if (rst_n) begin
        acc0 <= acc0 + 48'h0000_0010_0001;
        acc1 <= acc1 + 48'h0123_4567_89AB;   // upper half changes every cycle
        acc2 <= acc2 - 48'h0000_FFFF_FFF1;
    end

    initial begin
        $display("=== tb_debug: Block 12 Rev 4.0 ===");
        // ---- hclk stopped, DM held in reset: the TAP still answers ---------------------
        #100 por_n = 1;
        tap_reset();
        shift_dr(0, 32, o);
        check(o[31:0] == 32'h0000_0DB1, "[N-9.2] IDCODE readable with hclk stopped and the DM in reset");
        shift_ir(5'h10); shift_dr(0, 32, o);
        check(o[3:0] == 1 && o[9:4] == 7 && o[14:12] == 5, "[N-9.2] DTMCS readable with hclk stopped and the DM in reset");
        hclk_en = 1; #40 rst_n = 1;
        tap_reset();

        // IDCODE is selected by Test-Logic-Reset
        shift_dr(0, 32, o);
        check(o[31:0] == 32'h0000_0DB1, "IDCODE selected by Test-Logic-Reset");
        shift_ir(5'h01); shift_dr(0, 32, o);
        check(o[31:0] == 32'h0000_0DB1, "[N-6.1] IDCODE = 0x0000_0DB1");
        shift_ir(5'h10); shift_dr(0, 32, o);
        check(o[3:0] == 1 && o[9:4] == 7 && o[14:12] == 5, "[N-6.2] DTMCS: version 1, abits 7, idle 5");
        // BYPASS: a single flop that captures 0, so TDO is TDI one TCK later
        shift_ir(5'h1F); shift_dr(64'h0B5, 9, o);
        check(o[8:0] == {8'hB5, 1'b0}, "BYPASS (IR 0x1F) is a 1-bit register that captures 0");
        shift_ir(5'h05); shift_dr(64'h0D3, 9, o);
        check(o[8:0] == {8'hD3, 1'b0}, "unimplemented IR 0x05 decodes to BYPASS (spec 6.1)");

        // ---- [N-5.1] five TMS-high clocks reach Test-Logic-Reset from mid-scan states ----
        ok = 1;
        for (i = 0; i < 4; i++) begin
            bit q;
            shift_ir(5'h11);                                    // IR = DMI, so IDCODE proves a reset
            case (i)
                0: begin clk1(1,0,q); clk1(0,0,q); clk1(0,0,q); clk1(0,1,q); end                          // Shift-DR
                1: begin clk1(1,0,q); clk1(0,0,q); clk1(0,0,q); clk1(1,0,q); clk1(0,0,q); end             // Pause-DR
                2: begin clk1(1,0,q); clk1(1,0,q); clk1(0,0,q); clk1(0,0,q); clk1(0,1,q); end             // Shift-IR
                default: begin clk1(1,0,q); clk1(1,0,q); clk1(0,0,q); clk1(0,0,q); clk1(1,0,q); clk1(0,0,q); end // Pause-IR
            endcase
            tap_reset();
            shift_dr(0, 32, o);
            if (o[31:0] !== 32'h0000_0DB1) begin ok = 0; $display("  TAP reset from state case %0d failed: %h", i, o[31:0]); end
        end
        check(ok, "[N-5.1] five TMS-high clocks reset the TAP from Shift-DR, Pause-DR, Shift-IR and Pause-IR (no TRST)");

        shift_ir(5'h11);                                        // DMI from here on
        dmw(7'h10, 32'h1);                                      // dmactive
        dmr(7'h10, r); check(r[0] == 1, "[N-7.1] dmactive set");
        dmr(7'h11, r); check(r[3:0] == 2 && r[7] && r[11] && !r[9], "dmstatus: v0.13, authenticated, running");
        dmr(7'h16, r); check(r == 0, "[N-6.3] abstractcs reads 0: datacount 0, progbufsize 0");
        ok = 1;
        dmr(7'h04, r); if (r !== 0) ok = 0;
        dmr(7'h17, r); if (r !== 0) ok = 0;
        dmr(7'h20, r); if (r !== 0) ok = 0;
        dmr(7'h2F, r); if (r !== 0) ok = 0;
        check(ok, "[N-6.3] data0, command and progbuf0/15 read 0");

        dmw(7'h10, 32'h8000_0001);                              // haltreq
        #200 check(hartreset, "[N-7.8] haltreq holds the hart in hartreset");
        dmr(7'h11, r); check(r[9] && r[8] && !r[11] && !r[10], "[N-7.9] dmstatus: any/allhalted mirror hartreset, not running");
        x0 = n_xfer;
        dmw(7'h38, (1 << 20) | (2 << 17));
        dmw(7'h39, 32'h0000_0040); dmr(7'h3C, r);
        check(n_xfer == x0 + 1 && hartreset, "[N-7.13] SBA still reaches memory while the hart is held in hartreset");
        dmw(7'h38, (2 << 17));
        dmw(7'h10, 32'h4000_0001);                              // resumereq
        #200 check(!hartreset, "[N-7.8] resumereq releases hartreset");
        dmw(7'h10, 32'h2000_0001);                              // hartreset bit itself
        #200 check(hartreset, "dmcontrol.hartreset (bit 29) is RW and drives hartreset_o");
        dmr(7'h10, r); check(r[29] && r[0], "dmcontrol reads back hartreset");
        dmw(7'h10, 32'h0000_0001);
        #200 check(!hartreset, "writing hartreset = 0 releases the hart");
        dmw(7'h38, (2 << 17) | (1 << 16));                      // a DM register to watch across ndmreset
        dmw(7'h10, 32'h0000_0003);                              // ndmreset
        #200 check(ndmreset && !hartreset, "[N-7.14] ndmreset is a level out to reset_ctrl");
        #2000 check(ndmreset, "[N-7.14] ndmreset holds until the debugger clears it");
        dmr(7'h10, r); check(r[1:0] == 2'b11, "[N-7.12] dmcontrol.ndmreset and dmactive still set while ndmreset is asserted");
        dmr(7'h38, r); check(r[19:16] == 4'b0101, "[N-7.12] the DM's own registers (sbcs) survive ndmreset");
        dmw(7'h10, 32'h0000_0001);
        #200 check(!ndmreset, "ndmreset released");
        dmw(7'h38, (2 << 17));

        // ---- SBA single write/read to DSRAM ------------------------------------------
        dmr(7'h38, r); check(r[31:29] == 1 && r[19:17] == 2 && r[11:5] == 32 && r[2], "sbcs: v1, sbaccess=2, 32-bit only");
        check(r[4:3] == 0 && r[1:0] == 0, "[N-6.6] sbaccess8/16/64/128 read 0");
        x0 = n_xfer;
        dmw(7'h39, 32'h2000_0100);
        check(n_xfer == x0, "[N-7.3] writing sbaddress0 with sbreadonaddr = 0 starts no transfer");
        dmw(7'h3C, 32'hCAFE_0001);
        check(n_xfer == x0 + 1 && u_dsram.bd_read(32'h2000_0100) == 32'hCAFE_0001,
              "[N-7.3] the write to sbdata0 triggers exactly one AHB write");
        dmw(7'h38, 32'h0010_0000 | (2 << 17));                  // sbreadonaddr
        dmw(7'h39, 32'h2000_0100);
        dmr(7'h3C, r); check(r == 32'hCAFE_0001, "[N-7.2] SBA write then read-on-addr to DSRAM");
        // sbreadonaddr = 0, sbreadondata = 1: the read starts when sbdata0 is read
        u_dsram.bd_write(32'h2000_0110, 32'h0D0D_0110);
        dmw(7'h38, (2 << 17) | (1 << 15));
        x0 = n_xfer;
        dmw(7'h39, 32'h2000_0110);
        check(n_xfer == x0, "[N-7.2] sbreadonaddr = 0: no transfer when sbaddress0 is written");
        dmr(7'h3C, r);                                           // returns the old sbdata0, starts the read
        check(n_xfer == x0 + 1, "[N-7.2] sbreadondata: the transfer starts when sbdata0 is read");
        dmw(7'h38, (2 << 17));
        dmr(7'h3C, r); check(r == 32'h0D0D_0110, "[N-7.2] the next sbdata0 read returns the fetched word");

        // ---- bulk load into LOCKED ISRAM with autoincrement ---------------------------
        dmw(7'h38, (2 << 17) | (1 << 16));                      // autoincrement
        dmw(7'h39, 32'h0000_0000);
        for (i = 0; i < 8; i++) dmw(7'h3C, 32'h1000_0000 + i);
        ok = 1; for (i = 0; i < 8; i++) if (u_isram.bd_read(4*i) !== 32'h1000_0000 + i) ok = 0;
        check(ok, "[N-7.7] 8-word autoincrement load into ISRAM with ILOCK set (SBA bypass)");
        dmr(7'h39, r); check(r == 32'h20, "sbaddress0 advanced by 4 per access");
        // the very top of ISRAM, then wrap of the address register
        dmw(7'h39, 32'h0000_FFFC); dmw(7'h3C, 32'h70F0_FFFC);
        check(u_isram.bd_read(32'h0000_FFFC) == 32'h70F0_FFFC, "[N-7.5] SBA writes the last word of ISRAM (0x0000_FFFC)");

        // stream back with readonaddr + readondata + autoincrement
        dmw(7'h38, (1 << 20) | (2 << 17) | (1 << 16) | (1 << 15));
        dmw(7'h39, 32'h0000_0000);
        ok = 1;
        for (i = 0; i < 8; i++) begin dmr(7'h3C, r); if (r !== 32'h1000_0000 + i) ok = 0; end
        check(ok, "[N-6.5] readonaddr + readondata streams 8 words, one DMI read each");

        // ---- errors --------------------------------------------------------------------
        dmw(7'h38, (2 << 17));
        x0 = n_xfer;
        dmw(7'h39, 32'h2000_0102); dmw(7'h3C, 32'h1);
        dmr(7'h38, r); check(r[14:12] == 2 && n_xfer == x0, "[N-7.6] misaligned sbaddress0 -> sberror 2, no transfer issued");
        dmw(7'h38, (2 << 17) | (7 << 12));                      // W1C
        dmr(7'h38, r); check(r[14:12] == 0, "sberror is W1C");
        dmw(7'h38, (0 << 17));                                  // sbaccess = 8-bit
        dmw(7'h39, 32'h2000_0100); dmw(7'h3C, 32'h1);
        dmr(7'h38, r); check(r[14:12] == 3, "[N-6.6] unsupported size -> sberror 3");
        // every other unsupported size, on a write and on a read
        ok = 1; x0 = n_xfer;
        for (i = 0; i < 8; i++) if (i != 2) begin
            dmw(7'h38, (i << 17) | (7 << 12));
            dmw(7'h39, 32'h2000_0100); dmw(7'h3C, 32'h1);
            dmr(7'h38, r); if (r[14:12] !== 3 || r[19:17] !== i[2:0]) ok = 0;
            dmw(7'h38, (i << 17) | (1 << 20) | (7 << 12));       // read-on-address
            dmw(7'h39, 32'h2000_0100);
            dmr(7'h38, r); if (r[14:12] !== 3) ok = 0;
        end
        check(ok && n_xfer == x0, "[N-6.6] sbaccess 0,1,3..7: sberror 3 on write and on read, no transfer issued");
        dmw(7'h38, (2 << 17) | (7 << 12));
        dmw(7'h39, 32'h2000_F004); dmw(7'h3C, 32'h1);
        dmr(7'h38, r); check(r[14:12] == 4, "[N-7.6] AHB ERROR -> sberror 4");
        dmw(7'h39, 32'h2000_0104); dmw(7'h3C, 32'h55);
        check(u_dsram.bd_read(32'h2000_0104) !== 32'h55, "[N-7.6] sberror is sticky: accesses blocked until cleared");
        dmw(7'h38, (2 << 17) | (2 << 12));                      // W1C of a bit that is not set
        dmr(7'h38, r); check(r[14:12] == 4, "sberror W1C clears only the bits written as 1");
        dmw(7'h38, (2 << 17) | (7 << 12));
        // AHB ERROR on a read; sbdata0 must keep its previous value
        dmw(7'h39, 32'h2000_0100); dmw(7'h3C, 32'h5EED_0100);
        dmw(7'h38, (1 << 20) | (2 << 17));
        dmw(7'h39, 32'h2000_F008);
        dmr(7'h38, r); check(r[14:12] == 4, "[N-7.6] AHB ERROR on an SBA read -> sberror 4");
        dmw(7'h38, (2 << 17) | (7 << 12));
        dmr(7'h3C, r); check(r == 32'h5EED_0100, "an errored SBA read leaves sbdata0 unchanged");
        check(size_viol == 0, "[N-7.5] every SBA transfer is a 32-bit single (HSIZE = 010)");

        // ---- [N-7.4] sbbusy / sbbusyerror: slow hclk, 255 wait states -----------------------
        hh = 16.0; d_rand = 0; d_waits = 8'd255;                // one transfer ~ 8.2 us, a scan 2.3 us
        dmw(7'h38, (2 << 17) | (7 << 12) | (1 << 22));
        dmw(7'h39, 32'h2000_0300);
        x0 = n_xfer;
        dmi_scan(7'h3C, 32'h0BAD_0001, 2'd2, r, st); idle(6);   // starts the long write
        dmi_scan(7'h38, 0, 2'd1, r, st);             idle(6);   // read sbcs while it runs
        dmi_scan(7'h39, 32'h2000_0340, 2'd2, r, st); idle(6);   // sbaddress0 write while busy
        check(r[21] && !r[22], "[N-7.2] sbbusy is high during the AHB transfer");
        idle(120);
        dmr(7'h38, r);
        check(r[22] && !r[21], "[N-7.4] writing sbaddress0 while sbbusy sets sbbusyerror");
        dmr(7'h39, r); check(r == 32'h2000_0300, "[N-7.4] the sbaddress0 write made while busy is discarded");
        check(n_xfer == x0 + 1 && u_dsram.bd_read(32'h2000_0300) == 32'h0BAD_0001, "the transfer that was running completed once");
        d_waits = 8'd0;
        dmw(7'h3C, 32'h0BAD_0002);
        check(n_xfer == x0 + 1, "sbbusyerror blocks new accesses until it is cleared");
        dmw(7'h38, (2 << 17) | (1 << 22));
        dmr(7'h38, r); check(!r[22], "sbbusyerror is W1C");
        // sbdata0 written, and read, while busy
        d_waits = 8'd255;
        x0 = n_xfer;
        dmi_scan(7'h3C, 32'h0BAD_0003, 2'd2, r, st); idle(6);
        dmi_scan(7'h3C, 32'h0BAD_0004, 2'd2, r, st); idle(6);   // sbdata0 write while busy
        idle(160);
        dmr(7'h38, r);
        check(r[22] && n_xfer == x0 + 1 && u_dsram.bd_read(32'h2000_0300) == 32'h0BAD_0003,
              "[N-7.4] writing sbdata0 while sbbusy sets sbbusyerror and is discarded");
        dmw(7'h38, (2 << 17) | (1 << 22));
        dmi_scan(7'h3C, 32'h0BAD_0005, 2'd2, r, st); idle(6);
        dmi_scan(7'h3C, 0, 2'd1, r, st);             idle(6);   // sbdata0 read while busy
        idle(160);
        dmr(7'h38, r); check(r[22], "[N-7.4] reading sbdata0 while sbbusy sets sbbusyerror");
        dmw(7'h38, (2 << 17) | (1 << 22));

        // ---- sbdata0 read in the cycle the transfer completes ----------------------------
        // A read of sbdata0 must return the fetched word, or set sbbusyerror. The
        // wait-state count and the tck phase are swept so the read lands before,
        // on and after the completion cycle (hclk 62.5 MHz, read launched 52 tck
        // after the address; one wait state moves completion by one hclk cycle).
        hh = 8.0; stale = 0; win_hits = 0;
        for (i = 0; i < 40; i++) begin
            w = 155 + (i / 5);
            #(3.3 * (i % 5) + 0.7);                              // tck phase against hclk
            u_dsram.bd_write(32'h2000_0200, 32'hAAAA_0000 | w);
            u_dsram.bd_write(32'h2000_0204, 32'hBBBB_0000 | w);
            d_waits = 8'd0;
            dmw(7'h38, (1 << 20) | (2 << 17) | (1 << 22) | (7 << 12));
            dmw(7'h39, 32'h2000_0200);                           // sbdata0 = old word
            d_waits = w[7:0];
            dmi_scan(7'h39, 32'h2000_0204, 2'd2, r, st); idle(6);   // start the read of the new word
            dmi_scan(7'h3C, 0, 2'd1, r, st);             idle(8);   // read sbdata0 around its completion
            dmi_scan(7'h00, 0, 2'd0, lo, st);            idle(4);
            dmr(7'h38, s);
            if (!s[22] && lo !== (32'hBBBB_0000 | w)) begin
                stale++;
                $display("  waits=%0d: sbdata0 read returned %h (stale) with sbbusyerror clear", w, lo);
            end
        end
        check(win_hits > 0, "stimulus reached the cycle in which the SBA transfer completes");
        check(stale == 0, "[N-7.2] an sbdata0 read returns the fetched word or sets sbbusyerror, never stale data");
        dmw(7'h38, (2 << 17) | (1 << 22) | (7 << 12));
        hh = 2.0; d_rand = 1; d_waits = 8'd2;

        // ---- DMI busy: a request scanned while the previous one is in flight -------------
        dmw(7'h39, 32'hA0A0_0000);
        l0 = n_launch;
        dmi_scan(7'h39, 32'hB1B1_0004, 2'd2, r, st);            // accepted
        dmi_scan(7'h39, 32'hC2C2_0008, 2'd2, r, st);            // no Run-Test/Idle: previous still in flight
        #0.01;
        check(st == 2'd3, "a DMI scan with no idle cycles after a request reports busy (status 3)");
        check(n_launch == l0 + 1, "the request scanned in with a busy status is refused");
        idle(20);
        dtmcs_rd(s); check(s[11:10] == 2'd3, "DTMCS.dmistat busy is sticky");
        dmi_scan(7'h39, 32'hD3D3_000C, 2'd2, r, st); idle(8); #0.01;
        check(st == 2'd3 && n_launch == l0 + 1, "requests are refused while dmistat is sticky");
        dmireset();
        dtmcs_rd(s); check(s[11:10] == 2'd0, "DTMCS.dmireset clears the sticky status");
        dmr(7'h39, r); check(r == 32'hB1B1_0004, "only the accepted request took effect");
        // five TMS-high clocks in the middle of a request: it completes exactly once
        l0 = n_launch; p0 = n_pulse;
        dmi_scan(7'h39, 32'hE4E4_0010, 2'd2, r, st);
        tap_reset(); shift_dr(0, 32, o);
        check(o[31:0] == 32'h0000_0DB1, "TAP reset mid-request: IR back to IDCODE");
        shift_ir(5'h11); idle(8);
        dmr(7'h39, r); #0.01;
        check(r == 32'hE4E4_0010 && n_launch == l0 + 2 && n_pulse == p0 + 2 && cdc_err == 0,
              "TAP reset mid-request: the request in flight was delivered once and the DTM is not stuck");
        // dmihardreset also clears the status
        dmi_scan(7'h39, 32'h1, 2'd2, r, st); dmi_scan(7'h39, 32'h2, 2'd2, r, st); idle(20);
        shift_ir(5'h10); shift_dr(64'h2_0000, 32, o); shift_ir(5'h11);
        dtmcs_rd(s); check(s[11:10] == 2'd0, "DTMCS.dmihardreset clears the sticky status");

        // ---- [N-7.15] the DMI crossing at seven tck/hclk ratios, random phase -------------
        cdc_stress( 2.0, 25.0,  40, "tck 20 MHz, hclk 250 MHz (tck 12.5x slower)");
        cdc_stress(16.0, 25.0,  40, "tck 20 MHz, hclk 31.25 MHz (DIV16: the closest ratio the spec allows)");
        cdc_stress( 2.0, 250.0,  6, "tck 2 MHz, hclk 250 MHz (tck 125x slower)");
        cdc_stress(16.0, 16.07, 40, "tck 31.1 MHz, hclk 31.25 MHz (nearly equal, phase slipping)");
        cdc_stress( 2.0, 1.993, 40, "tck 250.9 MHz, hclk 250 MHz (nearly equal, phase slipping)");
        cdc_stress(16.0, 3.1,   40, "tck 161 MHz, hclk 31.25 MHz (tck 5.2x faster)");
        cdc_stress( 2.0, 0.41,  40, "tck 1.22 GHz, hclk 250 MHz (tck 4.9x faster)");
        hh = 2.0; th = 25.0; idle(12);
        check(busy_seen > 0, "the ratio sweep exercised the busy/retry path");

        // ---- [N-7.17] tck stops mid-handshake: the hclk side finishes on its own ----------
        d_rand = 0; d_waits = 8'd40;
        dmw(7'h38, (2 << 17) | (1 << 22) | (7 << 12));
        dmw(7'h39, 32'h2000_0400);
        x0 = n_xfer;
        dmi_scan(7'h3C, 32'h57A1_0001, 2'd2, r, st);            // Update-DR done, then tck stops dead
        #20000;
        check(n_xfer == x0 + 1 && u_dsram.bd_read(32'h2000_0400) == 32'h57A1_0001 &&
              !dut.u_sba.busy_o && htrans == 2'b00,
              "[N-7.17] tck stopped after Update-DR: the AHB transfer completed and the bus is released");
        idle(8);
        dmr(7'h38, r); check(!r[21] && !r[22] && r[14:12] == 0, "[N-7.17] tck resumes: no busy, no error");
        // stop in the middle of Shift-DR of the collecting scan, and between request and collect
        dmw(7'h38, (1 << 20) | (2 << 17));
        dmi_scan(7'h39, 32'h2000_0400, 2'd2, r, st);
        #15000; idle(8);
        begin
            bit q; reg [63:0] v, y;
            v = {23'd0, 7'h3C, 32'd0, 2'd1}; y = 0;
            clk1(1, 0, q); clk1(0, 0, q); clk1(0, 0, q);
            for (int k = 0; k < 41; k++) begin
                if (k == 20) #30000;                             // probe pauses mid-shift
                clk1(k == 40, v[k], q); y[k] = q;
            end
            clk1(1, 0, q); clk1(0, 0, q);
        end
        #15000; idle(8);
        dmi_scan(7'h00, 0, 2'd0, r, st);
        check(r == 32'h57A1_0001 && st == 2'd0, "[N-11.1] tck stopped before, during and after a scan: the read result is intact");
        d_rand = 1; d_waits = 8'd2;
        dmw(7'h38, (2 << 17));

        // ---- hclk-only reset in the middle of a session (watchdog / SWRST, D-18) ------------
        if (dut.u_dtm.req_tgl_o == 1'b0) dmw(7'h39, 32'h0);     // leave the request line at 1
        idle(8); p0 = n_pulse;
        rst_n = 0; repeat (20) @(posedge hclk); #1 rst_n = 1; repeat (20) @(posedge hclk); #0.01;
        check(n_pulse == p0, "[D-18] an hclk-only reset does not replay the last DMI request");
        dmr(7'h10, r); check(r[0] == 0, "[D-18] dmactive is reset with the DM (watchdog / SWRST)");
        dmw(7'h10, 32'h1);
        dmr(7'h10, r); check(r[0] == 1, "the DTM is not stuck busy after an hclk-only reset: the next request works");
        // the reset lands while a request is in flight
        dmi_scan(7'h39, 32'h7777_0000, 2'd2, r, st);
        rst_n = 0; repeat (20) @(posedge hclk); #1 rst_n = 1; repeat (20) @(posedge hclk);
        idle(12);
        dmi_scan(7'h00, 0, 2'd0, r, st);
        check(st != 2'd3, "an hclk-only reset during a request does not leave the DTM busy for ever");
        dmireset();
        dmw(7'h10, 32'h1); dmw(7'h39, 32'h1357_9BDC);
        dmr(7'h39, r); check(r == 32'h1357_9BDC && cdc_err == 0, "requests are delivered again after the reset, none replayed");

        // ---- dmactive = 0 holds the DM in reset (spec 6.5) -------------------------------------
        dmw(7'h38, (2 << 17) | (1 << 16) | (1 << 15));
        dmw(7'h39, 32'h2000_0102); dmw(7'h3C, 32'h1);           // sberror 2
        dmw(7'h38, (1 << 20) | (2 << 17) | (1 << 16) | (1 << 15));
        dmw(7'h10, 32'h0);
        dmw(7'h10, 32'h1);
        dmr(7'h38, r);
        check(r[22:12] == {1'b0, 1'b0, 1'b0, 3'd2, 1'b0, 1'b0, 3'd0},
              "dmactive = 0 resets the DM: sbcs back to its reset value (sbaccess 2, flags and errors clear)");
        dmr(7'h39, r); check(r == 32'h0, "dmactive = 0 resets the DM: sbaddress0 back to 0");
        dmw(7'h38, (2 << 17) | (7 << 12) | (1 << 22));          // no error pending
        dmw(7'h39, 32'h2000_0500);
        dmw(7'h10, 32'h0);
        x0 = n_xfer;
        dmw(7'h3C, 32'hDEAD_0500);                              // must do nothing: the DM is in reset
        check(n_xfer == x0 && u_dsram.bd_read(32'h2000_0500) !== 32'hDEAD_0500,
              "dmactive = 0 holds the DM in reset: an sbdata0 write starts no transfer until dmactive is written 1");
        dmw(7'h10, 32'h1);
        dmw(7'h38, (2 << 17));

        // ---- DSU taps ---------------------------------------------------------------------
        ok = 1;
        for (i = 0; i < 4; i++) begin
            dmr(7'h60, lo); dmr(7'h61, hi);
            // the snapshot must be a value the counter actually held: low word
            // = 0x...N*1, high = N*0x10 for the same N, since both halves step together
            if ((({hi[15:0], lo} - 48'h1234_5678_9ABC) % 48'h0000_0010_0001) != 0) ok = 0;
            if ({hi[15:0], lo} !== snap0) ok = 0;
        end
        check(ok, "[N-6.8] dsuacc0 lo-then-hi is a coherent 48-bit snapshot while running");
        dmr(7'h62, lo); #3000; dmr(7'h63, hi);
        check({hi[15:0], lo} === snap1 && hi[31:16] == 0,
              "[N-6.8] dsuacc1: _hi returns the half captured by the _lo read, not the live value");
        dmr(7'h63, r); check(r === hi, "[N-6.8] reading _hi alone returns whatever was last captured");
        dmr(7'h64, lo); dmr(7'h65, hi);
        check({hi[15:0], lo} === snap2, "[N-6.8] dsuacc2 lo-then-hi is the value live at the _lo read");
        dmr(7'h60, lo); dmr(7'h60, hi);
        check(lo !== hi, "[N-6.7] the taps are read live while the accumulator runs (no halt needed)");
        dmr(7'h66, r); check(!r[0], "dsuovf reads 0 while no overflow is flagged");
        ovf = 1; dmr(7'h66, r); check(r[0], "dsuovf reports the sticky DSU overflow");

        idle(12); repeat (12) @(posedge hclk); #0.01;
        check(cdc_err == 0 && lq.size() == 0,
              $sformatf("[N-7.16] whole run: %0d DMI requests launched in tck, %0d delivered in hclk, none lost, duplicated or corrupted", n_launch, n_pulse));
        check(v_chk == 0, "AHB-Lite protocol checker clean on the SBA master");
        $display("tb_debug: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end
    initial begin #400_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
