`timescale 1ns/1ps
// =============================================================================
// tb_fpga_core.sv - garuda_fpga_core driven EXACTLY the way the KV260 host
// script drives it: through the 32-bit ctrl word and the 32-bit stat word,
// with no hierarchical peeking and no backdoor loads.
//
//   1. release reset with boot_sel=1 (ROM -> recovery mailbox loop)
//   2. JTAG: read IDCODE, halt, stream the image into ISRAM over SBA, post
//      the mailbox, resume
//   3. poll tohost (0x2000_F000) over SBA reads until non-zero
//
// The sequences here and in fpga/kv260/host/garuda_host.py must stay
// identical.
//   +TEST=<hex>  +MAXPOLL=<n>  +CONSOLE (uart0 -> host UART, not loopback)  +WDT
//    (tohost polls before timeout, ~30 us each)
// =============================================================================
module tb_fpga_core;
    reg clk = 0;
    always #10 clk = ~clk;                // 50 MHz: MMCM sim model passes it through

    reg  [31:0] ctrl = 32'h0000_0030;     // uart0 loopback, boot_sel=1, rst asserted, tck=0
    wire [31:0] stat;
    wire i2c_scl, i2c_sda, gpio0, gpio1, pwm0, pwm1, pwm2, pwm3, host_rxd;

    pullup   (i2c_scl);
    pullup   (i2c_sda);
    pulldown (gpio0);
    pulldown (gpio1);

    garuda_fpga_core #(.BROM_INIT_FILE("sw/build/bootrom.hex")) dut (
        .clk_100_i(clk), .rst_100_n_i(1'b1),
        .ctrl_i(ctrl), .stat_o(stat),
        .host_uart_txd_i(1'b1), .host_uart_rxd_o(host_rxd),
        .i2c_scl(i2c_scl), .i2c_sda(i2c_sda), .gpio0(gpio0), .gpio1(gpio1),
        .pwm0(pwm0), .pwm1(pwm1), .pwm2(pwm2), .pwm3(pwm3));

    // ---- host-side JTAG over the ctrl word ---------------------------------
    // One "GPIO write" = one ctrl update. Host: write TMS/TDI with TCK=0,
    // write TCK=1, read TDO, write TCK=0.
    localparam real TH = 100.0;           // 5 MHz TCK, slower than the host is
    task automatic clk1(input bit m, input bit d, output bit q);
        // whole-word writes, like the AXI GPIO register (and Verilator 5.020
        // does not propagate a bit-select write to a port - see README)
        ctrl = (ctrl & ~32'h7) | {29'd0, d, m, 1'b0}; #TH;
        ctrl = ctrl | 32'h1;                           #TH; q = stat[0];
        ctrl = ctrl & ~32'h1;
    endtask
    task automatic idle(input int n); bit q; repeat (n) clk1(0, 0, q); endtask
    task automatic tap_reset; bit q; repeat (5) clk1(1, 0, q); clk1(0, 0, q); endtask
    task automatic shift_ir(input [4:0] v);
        bit q;
        clk1(1, 0, q); clk1(1, 0, q); clk1(0, 0, q); clk1(0, 0, q);
        for (int i = 0; i < 5; i++) clk1(i == 4, v[i], q);
        clk1(1, 0, q); clk1(0, 0, q);
    endtask
    task automatic shift_dr(input [63:0] v, input int n, output [63:0] o);
        bit q; o = 0;
        clk1(1, 0, q); clk1(0, 0, q); clk1(0, 0, q);
        for (int i = 0; i < n; i++) begin clk1(i == n - 1, v[i], q); o[i] = q; end
        clk1(1, 0, q); clk1(0, 0, q);
    endtask
    task automatic dmw(input [6:0] a, input [31:0] d);
        reg [63:0] x; shift_dr({23'd0, a, d, 2'd2}, 41, x); idle(6);
    endtask
    task automatic dmr(input [6:0] a, output [31:0] r);
        reg [63:0] x;
        shift_dr({23'd0, a, 32'd0, 2'd1}, 41, x); idle(6);
        shift_dr({23'd0, a, 32'd0, 2'd0}, 41, x); r = x[33:2]; idle(2);
    endtask
    // SBA word read: sbreadonaddr=1, write the address, read sbdata0
    task automatic sba_rd(input [31:0] addr, output [31:0] d);
        dmw(7'h38, (1 << 20) | (2 << 17));
        dmw(7'h39, addr);
        dmr(7'h3C, d);
    endtask

    // Re-attach after anything that may have reset the DM (watchdog): clear a
    // sticky DMI error in the DTM, re-activate the DM, clear SBA errors.
    task automatic dm_attach;
        reg [63:0] y;
        shift_ir(5'h10); shift_dr(64'h1_0000, 32, y);   // dtmcs.dmireset
        shift_ir(5'h11);
        dmw(7'h10, 32'h0000_0001);
        dmw(7'h38, (1 << 22) | (7 << 12) | (2 << 17));
    endtask

    // ---- host UART monitor: 115200 8N1 on GARUDA uart0 TX (console mode) ----
    localparam real BIT = 1.0e9 / 115200.0;       // ns
    reg [7:0] rxb;
    always begin
        @(negedge host_rxd);
        #(BIT * 1.5);
        for (int k = 0; k < 8; k++) begin rxb[k] = host_rxd; #(BIT); end
        if (rxb == 8'h0A) $write("\n"); else if (rxb != 8'h0D) $write("%c", rxb);
    end

    localparam [31:0] TOHOST = 32'h2000_F000, MBOX = 32'h2000_FFF0, MBOX_MAGIC = 32'h4A54_4147;

    reg [1023:0] test_hex;
    reg [31:0]   img [0:16383];
    reg [31:0]   r, th;
    reg [63:0]   x;
    integer      nwords, i, maxus;
    bit          q, wdt, reposted;

    initial begin
        if (!$value$plusargs("TEST=%s", test_hex)) test_hex = "sw/build/t_chip_jtag.hex";
        if (!$value$plusargs("MAXPOLL=%d", maxus)) maxus    = 2000;
        if ($test$plusargs("CONSOLE")) ctrl = ctrl & ~32'h20;   // uart0 rx from host
        for (i = 0; i < 16384; i++) img[i] = 32'hDEAD_BEEF;
        $readmemh(test_hex, img);
        for (nwords = 16384; nwords > 0 && img[nwords-1] === 32'hDEAD_BEEF; nwords--) ;
        $display("=== tb_fpga_core: %0s, %0d words ===", test_hex, nwords);

        #1000;
        if (stat[31:16] != 16'h6A5D) begin $display("[FAIL] signature %h", stat[31:16]); $finish; end
        if (!stat[1])                begin $display("[FAIL] not locked"); $finish; end

        // 1. ClearSRAM is not reset: clear tohost + mailbox over SBA below
        ctrl = ctrl | 32'h8;                                    // ext_rst_n release
        #20000;                                            // reset stretch

        // 2. IDCODE (TLR selects it)
        tap_reset();
        shift_dr(64'd0, 32, x);
        $display("[tb] IDCODE = 0x%08h", x[31:0]);
        if (x[31:0] != 32'h0000_0DB1) begin $display("[FAIL] IDCODE"); $display("RESULT: FAILED"); $finish; end

        shift_ir(5'h11);
        dmw(7'h10, 32'h0000_0001);                         // dmactive
        dmw(7'h10, 32'h8000_0001);                         // haltreq
        dmw(7'h38, (2 << 17));                             // 32-bit
        dmw(7'h39, TOHOST); dmw(7'h3C, 32'h0);             // clear tohost
        dmw(7'h38, (2 << 17) | (1 << 16));                 // 32-bit, autoinc
        dmw(7'h39, 32'h0000_0000);
        for (i = 0; i < nwords; i++) dmw(7'h3C, img[i]);
        dmw(7'h38, (2 << 17));
        dmw(7'h39, MBOX + 4); dmw(7'h3C, 32'h0);
        dmw(7'h39, MBOX);     dmw(7'h3C, MBOX_MAGIC);
        dmr(7'h11, r);
        if (!r[9]) begin $display("[FAIL] not halted, dmstatus=%h", r); $display("RESULT: FAILED"); $finish; end
        // readback check of the first 4 words
        for (i = 0; i < 4 && i < nwords; i++) begin
            sba_rd(4 * i, r);
            if (r != img[i]) begin $display("[FAIL] ISRAM[%0d] = %h exp %h", i, r, img[i]); $display("RESULT: FAILED"); $finish; end
        end
        dmr(7'h38, r);
        if (r[14:12] != 0) begin $display("[FAIL] sberror %0d", r[14:12]); $display("RESULT: FAILED"); $finish; end
        dmw(7'h10, 32'h4000_0001);                         // resumereq
        $display("[tb] %0d words loaded, resumed at %0t", nwords, $time);

        // 3. poll tohost over SBA. +WDT: the program resets the chip once,
        // and the ROM needs the mailbox posted again for run 2 (one-shot).
        wdt = $test$plusargs("WDT");
        reposted = 0;
        forever begin
            if (wdt) begin
                dm_attach();
                if (!reposted) begin
                    sba_rd(32'h4000_9000, r);              // RSTREASON
                    if (r[4:0] == 5'h02) begin             // watchdog reset happened: ROM is polling
                        dmw(7'h38, (2 << 17));
                        dmw(7'h39, MBOX + 4); dmw(7'h3C, 32'h0);
                        dmw(7'h39, MBOX);     dmw(7'h3C, MBOX_MAGIC);
                        reposted = 1;
                        $display("[tb] mailbox re-posted for run 2 at %0t", $time);
                    end
                end
            end
            sba_rd(TOHOST, th);
            if (th != 0) begin
                $display("[tb] tohost = 0x%08h at %0t", th, $time);
                if (th == 1) $display("RESULT: PASSED");
                else begin $display("[FAIL] step %0d", th >> 1); $display("RESULT: FAILED"); end
                $finish;
            end
            maxus = maxus - 1;
            if (maxus == 0) begin
                $display("[FAIL] TIMEOUT, tohost never written"); $display("RESULT: FAILED"); $finish;
            end
        end
    end
endmodule
