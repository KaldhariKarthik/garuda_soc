`timescale 1ns/1ps
// =============================================================================
// tb_i2c.sv -- Block 15 I2C master (OpenCores controllers + GARUDA registers)
//
// Spec: GARUDA-I2C-SPEC-001 §11. Drives a real slave model over an open-drain
// bus with pull-ups, so the only way a byte gets through is if the protocol is
// right on the wire.
//
// PRESCALE is 7 here (SCL = pclk/32 = 3.9 MHz) to keep the simulation short.
// t_i2c_scl_rate uses the real 100 kHz and 400 kHz values once, because that
// test is about the arithmetic in [N-6.1], not the data path.
// =============================================================================
module tb_i2c;

    logic pclk = 0, preset_n = 0;
    always #4 pclk = ~pclk;                        // 125 MHz

    garuda_apb_bfm bfm (.pclk(pclk), .preset_n(preset_n));

    logic dma_ack = 0;
    wire  irq, dma_req;
    wire  scl_o, scl_oe, sda_o, sda_oe;

    // the bus: open drain with board pull-ups
    wire scl, sda;
    pullup (weak1) p_scl (scl);
    pullup (weak1) p_sda (sda);
    assign scl = scl_oe ? scl_o : 1'bz;
    assign sda = sda_oe ? sda_o : 1'bz;

    garuda_i2c_top dut (
        .pclk_i(pclk), .preset_n_i(preset_n),
        .psel_i(bfm.psel), .penable_i(bfm.penable), .pwrite_i(bfm.pwrite),
        .paddr_i(bfm.paddr), .pwdata_i(bfm.pwdata), .prdata_o(bfm.prdata),
        .pready_o(bfm.pready), .pslverr_o(bfm.pslverr),
        .irq_o(irq), .dma_req_o(dma_req), .dma_ack_i(dma_ack),
        .i2c_scl_i(scl), .i2c_scl_o(scl_o), .i2c_scl_oe(scl_oe),
        .i2c_sda_i(sda), .i2c_sda_o(sda_o), .i2c_sda_oe(sda_oe));

    i2c_slave_model #(.ADDR(7'h48)) u_slv (.scl(scl), .sda(sda));

    dma_req_checker #(.NAME("i2c")) u_dchk (
        .clk_i(pclk), .rst_n_i(preset_n), .req_i(dma_req), .ack_i(dma_ack));

    // ---- permanent monitors -----------------------------------------------------
    int pready_viol = 0, drive_high = 0;
    always @(posedge pclk) begin
        if (preset_n && bfm.psel && !bfm.pready) pready_viol++;
        // R-9: the block may only ever pull a line LOW or release it
        if (preset_n && ((scl_oe && scl_o !== 1'b0) || (sda_oe && sda_o !== 1'b0)))
            drive_high++;
    end
    // The MINIMUM falling-edge gap is one SCL period; single samples catch
    // START/STOP and ACK boundaries, which are longer.
    realtime scl_fall = 0, scl_min = 1e9;
    always @(negedge scl) begin
        if (scl_fall > 0 && ($realtime - scl_fall) < scl_min)
            scl_min = $realtime - scl_fall;
        scl_fall = $realtime;
    end
    task automatic scl_meas_reset(); scl_min = 1e9; scl_fall = 0; endtask

    // A second device on the bus. The testbench can pull either line low the
    // way another master does (arbitration) or the way a board does when it
    // clocks a stuck slave free (OPEN-I1: GARUDA itself cannot).
    logic tb_sda_low = 1'b0, tb_scl_low = 1'b0;
    assign sda = tb_sda_low ? 1'b0 : 1'bz;
    assign scl = tb_scl_low ? 1'b0 : 1'bz;

    // Every change of the DUT's two output enables, counted. "The block went
    // quiet" is then a number that did not move, not a waveform to look at.
    int   oe_edges = 0;
    logic scl_oe_d = 1'b0, sda_oe_d = 1'b0;
    always @(posedge pclk) begin
        if (preset_n && (scl_oe !== scl_oe_d || sda_oe !== sda_oe_d)) oe_edges++;
        scl_oe_d <= scl_oe;
        sda_oe_d <= sda_oe;
    end

    // nine clocks and a STOP, which is how a board frees a slave left mid-byte
    task automatic bus_recover();
        repeat (9) begin
            tb_scl_low = 1'b1; #400; tb_scl_low = 1'b0; #400;
        end
        tb_scl_low = 1'b1; #200; tb_sda_low = 1'b1; #200;
        tb_scl_low = 1'b0; #400;
        tb_sda_low = 1'b0; #400;                   // SDA rises with SCL high: STOP
    endtask

    localparam [11:0] R_PRESCALE = 12'h000, R_CTRL  = 12'h004, R_TXDATA = 12'h008,
                      R_RXDATA   = 12'h00C, R_CMD   = 12'h010, R_STATUS = 12'h014,
                      R_TIMEOUT  = 12'h018,
                      R_IRQSTAT  = 12'hFE0, R_IRQEN = 12'hFE4,
                      R_DMACTL   = 12'hFE8, R_ID    = 12'hFEC;
    localparam CMD_STA = 1, CMD_STO = 2, CMD_RD = 4, CMD_WR = 8, CMD_NACK = 16;
    localparam ST_TIP = 0, ST_BUSY = 1, ST_AL = 2, ST_NACK = 3,
               ST_TO = 4, ST_RXVALID = 5;
    localparam int PRE_FAST = 24;                  // ~870 kHz: fast for sim, but
                                                   // not so fast that the core's
                                                   // own pipelining shows as skew

    // Independent APB protocol observer on this block's config port. The
    // shared garuda_apb_bfm carries no PSTRB, so the strobes are tied high.
    wire [31:0] apbviol;
    apb_checker u_apbchk (
        .clk_i(pclk), .rst_n_i(preset_n),
        .psel_i(bfm.psel), .penable_i(bfm.penable), .pwrite_i(bfm.pwrite),
        .paddr_i({20'h0, bfm.paddr}), .pwdata_i(bfm.pwdata), .pstrb_i(4'hF),
        .pready_i(bfm.pready), .pslverr_i(bfm.pslverr), .viol_count_o(apbviol));

    int checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask

    // issue one command and wait for it to retire
    task automatic cmd(input [31:0] c, output bit ok);
        logic [31:0] d;
        bit e;
        int g = 0;
        bfm.wr(R_CMD, c);
        do begin bfm.read(R_STATUS, d, e); g++; end while (d[ST_TIP] && g < 20000);
        ok = !d[ST_TIP];
    endtask

    task automatic wr_byte(input [7:0] b, input [31:0] extra, output bit ok);
        bfm.wr(R_TXDATA, {24'd0, b});
        cmd(CMD_WR | extra, ok);
    endtask

    logic [31:0] d;
    bit e, ok;
    int i, nbad;
    real f;
    int k, t, e0, stop0, n_held, n_tip, n_noisy, n_lost;

    initial begin
        $display("=== tb_i2c: Block 15 I2C master ===");

        repeat (4) @(posedge pclk);
        check(!scl_oe && !sda_oe, "[R-10] both lines released while in reset");
        preset_n = 1;
        repeat (4) @(posedge pclk);
        check(!scl_oe && !sda_oe, "[R-10] [N-9.4] both lines released out of reset");
        check(scl === 1'b1 && sda === 1'b1, "[R-10] the bus idles high on the pull-ups");
        // The pad synchronisers reset to the bus idle level. If they reset low
        // the core would see SDA fall with SCL high - a START - on the way out
        // of reset and report a busy bus that nobody is using.
        bfm.wr(R_CTRL, 32'h1);
        repeat (40) @(posedge pclk);
        bfm.read(R_STATUS, d, e);
        check(d[5:0] == 6'd0, $sformatf("[N-6.3] STATUS is 0 on an idle bus: no false START out of reset (%02h)", d[5:0]));
        // the input path: synchronisers, then the core's spike filter
        @(posedge pclk); #1 tb_sda_low = 1'b1;
        @(posedge pclk); #1 tb_sda_low = 1'b0;       // SDA low for one pclk
        repeat (40) @(posedge pclk);
        bfm.read(R_STATUS, d, e);
        check(!d[ST_BUSY], "[N-9.3] a one-pclk spike on SDA is filtered, not taken as a START");
        tb_sda_low = 1'b1;                           // another master's START
        repeat (100) @(posedge pclk);
        bfm.read(R_STATUS, d, e);
        check(d[ST_BUSY], "[N-9.3] [N-6.3] a real START from another master reaches the core and sets BUSY");
        tb_sda_low = 1'b0;                           // and its STOP
        repeat (100) @(posedge pclk);
        bfm.read(R_STATUS, d, e);
        check(!d[ST_BUSY], "[N-6.3] and that master's STOP clears BUSY");
        bfm.wr(R_CTRL, 32'h0);

        bfm.read(R_ID, d, e);
        check(d == {16'h6A5D, 8'd15, 8'd1} && !e, "ID register reads block 15");
        bfm.read(12'h800, d, e);
        check(e, "[R-3] PSLVERR on an unmapped offset");

        // ---- registers ------------------------------------------------------------
        bfm.wr(R_PRESCALE, 32'd312);
        bfm.read(R_PRESCALE, d, e);
        check(d == 32'd312, "[R-3] PRESCALE reads back");
        bfm.wr(R_TIMEOUT, 32'd5000);
        bfm.read(R_TIMEOUT, d, e);
        check(d == 32'd5000, "[R-3] TIMEOUT reads back");
        bfm.wr(R_TXDATA, 32'h5A);
        bfm.read(R_TXDATA, d, e);
        check(d == 32'h5A, "[R-3] TXDATA reads back");

        // ---- SCL rate, at the real bus speeds ---------------------------------------
        bfm.wr(R_PRESCALE, 32'd249);                 // 100 kHz
        bfm.wr(R_TIMEOUT, 32'd0);                    // no timeout for this test
        bfm.wr(R_CTRL, 32'h1);                       // EN
        bfm.wr(R_TXDATA, 32'h90);                    // addr 0x48, write
        scl_meas_reset();
        cmd(CMD_STA | CMD_WR, ok);
        f = 1000000.0 / scl_min;                     // ns -> kHz
        check(ok, "[R-2] a transfer ran at PRESCALE 249");
        $display("[MEASURED] PRESCALE 249 -> SCL %0.1f kHz (%0.0f pclk per bit)",
                 f, scl_min / 8.0);
        // I2C bus speeds are MAXIMA, not targets: 94.5 kHz is a legal
        // standard-mode bus. The lower bound only catches a divider that has
        // gone badly wrong.
        check(f <= 100.0 && f > 85.0,
              $sformatf("[R-2] SCL = %0.1f kHz at PRESCALE 249 (<= 100 kHz)", f));
        cmd(CMD_STO, ok);

        bfm.wr(R_PRESCALE, 32'd61);                  // 400 kHz
        bfm.wr(R_TXDATA, 32'h90);
        scl_meas_reset();
        cmd(CMD_STA | CMD_WR, ok);
        f = 1000000.0 / scl_min;
        $display("[MEASURED] PRESCALE 61 -> SCL %0.1f kHz", f);
        check(f <= 400.0 && f > 340.0,
              $sformatf("[R-2] SCL = %0.1f kHz at PRESCALE 61 (<= 400 kHz)", f));
        cmd(CMD_STO, ok);

        // ---- a register write to the slave ([N-7.1]) ---------------------------------
        bfm.wr(R_PRESCALE, PRE_FAST);
        u_slv.clear();
        bfm.wr(R_TXDATA, 32'h90);                    // 0x48 << 1 | write
        cmd(CMD_STA | CMD_WR, ok);
        bfm.read(R_STATUS, d, e);
        check(ok && !d[ST_NACK], "[R-1] the slave acknowledged its address");
        check(d[ST_BUSY], "[N-6.3] BUSY is set between the START and the STOP");
        bfm.read(R_CMD, d, e);
        check(d == 32'd0 && !e, "[N-6.2] CMD is write-only: it reads 0");
        // self-clearing: the command ran once. If the bits stayed set the byte
        // controller would send the address byte again and the bus would move.
        e0 = oe_edges;
        repeat (600) @(posedge pclk);
        check(oe_edges == e0, "[N-6.2] the command dropped when it was acknowledged: the bus is still, nothing repeats");
        wr_byte(8'h10, 0, ok);                       // register pointer
        wr_byte(8'hA5, CMD_STO, ok);                 // data + stop
        check(u_slv.bd_read(8'h10) == 8'hA5,
              $sformatf("[R-1] the slave stored 0xA5 at register 0x10 (got 0x%02h)",
                        u_slv.bd_read(8'h10)));
        check(u_slv.n_start == 1 && u_slv.n_stop == 1, "[R-1] exactly one START and one STOP");
        check(u_slv.n_rx == 1, $sformatf("[N-7.1] the slave stored exactly one data byte (%0d)", u_slv.n_rx));
        // BUSY is the core's own view of the bus, through the synchronisers
        // and the spike filter, so it trails the STOP it has just sent: TIP
        // clears first. Bounded here at half a bit time.
        t = 0;
        do begin bfm.read(R_STATUS, d, e); t = t + 3; end while (d[ST_BUSY] && t < 70);
        $display("[MEASURED] BUSY cleared within %0d pclk of TIP after a STOP", t);
        check(!d[ST_BUSY], "[N-6.3] BUSY clears after the STOP, within half a bit time");

        // ---- a register read, with a repeated start ([N-7.2]) --------------------------
        u_slv.bd_write(8'h20, 8'h3C);
        u_slv.clear();
        bfm.wr(R_TXDATA, 32'h90);
        cmd(CMD_STA | CMD_WR, ok);
        wr_byte(8'h20, 0, ok);                       // pointer
        bfm.wr(R_TXDATA, 32'h91);                    // 0x48 << 1 | read
        cmd(CMD_STA | CMD_WR, ok);                   // REPEATED start
        cmd(CMD_RD | CMD_NACK | CMD_STO, ok);        // one byte, NACK it, stop
        bfm.read(R_RXDATA, d, e);
        check(d[7:0] == 8'h3C, $sformatf("[R-1] read back 0x3C (got 0x%02h)", d[7:0]));
        check(u_slv.n_start == 2 && u_slv.n_stop == 1,
              $sformatf("[R-1] two STARTs, one STOP - a repeated start (%0d/%0d)",
                        u_slv.n_start, u_slv.n_stop));
        bfm.read(R_STATUS, d, e);
        check(!d[ST_RXVALID], "[R-1] [N-6.4] reading RXDATA cleared RXVALID");
        check(!d[ST_TIP] && u_slv.n_tx == 1,
              $sformatf("[N-6.4] reading RXDATA did not start another transfer (slave sent %0d byte)", u_slv.n_tx));
        check(u_slv.mack, "[N-6.2a] CMD.NACK put a NACK on the wire after the byte read");

        // ---- an 8-byte burst read ------------------------------------------------------
        for (i = 0; i < 8; i++) u_slv.bd_write(8'h30 + i, 8'hE0 + i[7:0]);
        u_slv.clear();
        nbad = 0;
        n_lost = 0;
        bfm.wr(R_TXDATA, 32'h90);
        cmd(CMD_STA | CMD_WR, ok);
        wr_byte(8'h30, 0, ok);
        bfm.wr(R_TXDATA, 32'h91);
        cmd(CMD_STA | CMD_WR, ok);
        for (i = 0; i < 8; i++) begin
            if (i == 7) cmd(CMD_RD | CMD_NACK | CMD_STO, ok);   // NACK the last
            else        cmd(CMD_RD, ok);                        // ACK the rest
            // the acknowledge level the slave actually saw on the wire
            if (u_slv.mack != (i == 7)) n_lost++;
            bfm.read(R_RXDATA, d, e);
            if (!ok || d[7:0] != 8'hE0 + i[7:0]) nbad++;
        end
        check(nbad == 0, $sformatf("[R-1] 8-byte burst read, all correct (%0d wrong)", nbad));
        check(n_lost == 0 && u_slv.n_tx == 8,
              $sformatf("[N-6.2a] ACK after bytes 0..6, NACK after the last; the slave sent exactly 8 (%0d, %0d wrong levels)",
                        u_slv.n_tx, n_lost));
        check(u_slv.viol() == 0, "[R-1] the slave saw no SDA-while-SCL-high violation");

        // ---- NACK from an absent device --------------------------------------------------
        bfm.wr(R_IRQSTAT, 32'hF);
        bfm.wr(R_TXDATA, 32'h20);                    // address 0x10 - nobody there
        cmd(CMD_STA | CMD_WR, ok);
        bfm.read(R_STATUS, d, e);
        check(ok && d[ST_NACK], "[R-7] an unanswered address sets STATUS.RXNACK");
        bfm.read(R_IRQSTAT, d, e);
        check(d[3], "[R-7] and IRQSTAT[3]");
        cmd(CMD_STO, ok);
        check(ok, "[R-7] and the block is still usable afterwards");

        // ---- clock stretching WITHIN the timeout ------------------------------------------
        bfm.wr(R_IRQSTAT, 32'hF);
        bfm.wr(R_TIMEOUT, 32'd60000);                // 480 us
        u_slv.stretch_ns = 20000.0;                  // 20 us: slow, but legal
        bfm.wr(R_TXDATA, 32'h90);
        cmd(CMD_STA | CMD_WR, ok);                   // address; the stretch starts here
        wr_byte(8'h40, 0, ok);                       // this command waits it out
        bfm.read(R_STATUS, d, e);
        check(ok && !d[ST_TO], "[R-8] a slave stretching 20 us inside a 480 us budget completes");
        wr_byte(8'h41, CMD_STO, ok);
        u_slv.stretch_ns = 0.0;

        // ---- clock stretching PAST the timeout ---------------------------------------------
        bfm.wr(R_IRQSTAT, 32'hF);
        bfm.wr(R_TIMEOUT, 32'd2000);                 // 16 us
        u_slv.stretch_ns = 200000.0;                 // 200 us: wedged
        stop0 = u_slv.n_stop;
        bfm.wr(R_TXDATA, 32'h90);
        cmd(CMD_STA | CMD_WR, ok);                   // address; the stretch starts here
        bfm.wr(R_TXDATA, 32'h50);
        cmd(CMD_WR, ok);                             // this command meets a dead bus
        check(ok, "[R-8] TIP cleared - the transfer was abandoned, not hung");
        bfm.read(R_STATUS, d, e);
        check(d[ST_TO], "[R-8] [N-7.5] STATUS.TIMEOUT is set");
        bfm.read(R_IRQSTAT, d, e);
        check(d[2], "[R-8] IRQSTAT[2] captured the timeout");
        check(!scl_oe && !sda_oe, "[R-8] [N-7.5] and the block released both pins so the bus can recover");
        bfm.wr(R_IRQSTAT, 32'h4);
        bfm.read(R_STATUS, d, e);
        check(!d[ST_TO], "[R-8] clearing IRQSTAT[2] clears STATUS.TIMEOUT");

        // let the wedged slave finish, then prove the block still works
        #250000;
        check(u_slv.n_stop == stop0, "[N-7.5a] the timeout released the pins without sending a STOP");
        u_slv.stretch_ns = 0.0;
        bfm.wr(R_CTRL, 32'h0);                       // disable
        repeat (10) @(posedge pclk);
        bfm.wr(R_CTRL, 32'h1);                       // re-enable
        bfm.wr(R_TIMEOUT, 32'd0);
        u_slv.clear();
        bfm.wr(R_TXDATA, 32'h90);
        cmd(CMD_STA | CMD_WR, ok);
        wr_byte(8'h50, 0, ok);
        wr_byte(8'h77, CMD_STO, ok);
        check(u_slv.bd_read(8'h50) == 8'h77, "[R-8] the block recovers and transfers again");

        // ---- CMD while busy faults rather than queueing -------------------------------------
        bfm.wr(R_TXDATA, 32'h90);
        bfm.wr(R_CMD, CMD_STA | CMD_WR);             // start one, do not wait
        repeat (4) @(posedge pclk);
        bfm.read(R_STATUS, d, e);
        if (d[ST_TIP]) begin
            bfm.write(R_CMD, CMD_WR, e);
            check(e, "[N-6.2b] a second CMD while TIP raises PSLVERR");
        end else begin
            check(1'b0, "[N-6.2b] could not observe TIP - test inconclusive");
        end
        do begin bfm.read(R_STATUS, d, e); end while (d[ST_TIP]);
        cmd(CMD_STO, ok);

        // ---- interrupt ------------------------------------------------------------------------
        bfm.wr(R_IRQSTAT, 32'hF);
        bfm.wr(R_IRQEN, 32'h1);                      // transfer complete
        check(!irq, "[R-5] no interrupt before a transfer");
        bfm.wr(R_TXDATA, 32'h90);
        cmd(CMD_STA | CMD_WR, ok);
        check(irq, "[R-5] transfer-complete interrupt asserted");
        repeat (60) @(posedge pclk);
        check(irq, "[R-5] still asserted 60 pclk later");
        bfm.wr(R_IRQSTAT, 32'h1);
        repeat (2) @(posedge pclk);
        check(!irq, "[R-5] W1C clears it");
        bfm.wr(R_IRQEN, 32'h0);
        cmd(CMD_STO, ok);

        // ---- DMA -------------------------------------------------------------------------------
        u_slv.bd_write(8'h60, 8'hD1);
        bfm.wr(R_DMACTL, 32'h1);                     // request on RX byte
        check(!dma_req, "[R-6] no request with nothing received");
        bfm.wr(R_TXDATA, 32'h90);
        cmd(CMD_STA | CMD_WR, ok);
        wr_byte(8'h60, 0, ok);
        bfm.wr(R_TXDATA, 32'h91);
        cmd(CMD_STA | CMD_WR, ok);
        cmd(CMD_RD | CMD_NACK | CMD_STO, ok);
        repeat (4) @(posedge pclk);
        check(dma_req, "[R-6] dma_req asserts once a byte is in RXDATA");
        bfm.read(R_RXDATA, d, e);
        check(d[7:0] == 8'hD1, "[R-6] the DMA's read returns the byte");
        check(d[31:8] == 24'd0, "[R-6] [N-7.7] word-sized beat, byte in [7:0]");
        #1 check(!dma_req, "[N-6.4] the RXDATA read itself drops the DMA request, before the ack");
        @(posedge pclk); #0.1 dma_ack = 1;
        @(posedge pclk); #0.1 dma_ack = 0;
        repeat (4) @(posedge pclk);
        check(!dma_req, "[R-6] dma_req drops after the ack");
        check(u_dchk.violations() == 0, "[R-6] dma_req_checker clean");
        bfm.wr(R_DMACTL, 32'h0);

        // ---- NACK on a DATA byte, not only on the address ([R-7]) -----------------------------------
        bfm.wr(R_IRQSTAT, 32'hF);
        u_slv.clear();
        u_slv.nack_data = 1'b1;
        bfm.wr(R_TXDATA, 32'h90);
        cmd(CMD_STA | CMD_WR, ok);
        bfm.read(R_STATUS, d, e);
        check(ok && !d[ST_NACK], "[R-7] the address is acknowledged");
        bfm.read(R_IRQSTAT, d, e);
        check(d[0] && !d[3], "[N-7.3] an acknowledged byte raises IRQSTAT[0] and not IRQSTAT[3]");
        wr_byte(8'h66, 0, ok);
        bfm.read(R_STATUS, d, e);
        check(ok && d[ST_NACK], "[R-7] [N-6.3] a refused DATA byte sets STATUS.RXNACK");
        bfm.read(R_IRQSTAT, d, e);
        check(d[3], "[R-7] [N-7.3] and IRQSTAT[3]");
        cmd(CMD_STO, ok);
        check(ok && u_slv.n_stop == 1, "[R-7] and the STOP still goes out");
        u_slv.nack_data = 1'b0;
        bfm.wr(R_TXDATA, 32'h90);
        cmd(CMD_STA | CMD_WR, ok);
        bfm.read(R_STATUS, d, e);
        check(!d[ST_NACK], "[N-6.3] RXNACK describes the LAST byte written: the next acknowledged byte clears it");
        cmd(CMD_STO, ok);

        // ---- arbitration loss ([N-7.4]) ---------------------------------------------------------------
        // The DUT sends 0xFF, so it releases SDA for every bit. Another master
        // (the testbench) holds SDA low: the DUT reads back a 0 where it sent
        // a 1, with SCL high, which is exactly how I2C arbitration is lost.
        bfm.wr(R_IRQSTAT, 32'hF);
        bfm.wr(R_IRQEN, 32'h2);                      // arbitration lost only
        check(!irq, "[N-7.4] no interrupt before the collision");
        bfm.wr(R_TXDATA, 32'hFF);
        fork
            begin
                @(negedge scl);                      // SCL falls after the START
                tb_sda_low = 1'b1;                   // the other master's 0
            end
            cmd(CMD_STA | CMD_WR, ok);
        join
        check(ok, "[R-7] [N-7.4] arbitration loss clears TIP: firmware is not left polling");
        bfm.read(R_STATUS, d, e);
        check(d[ST_AL], "[N-7.4] [N-6.3] STATUS.AL is set");
        check(!scl_oe && !sda_oe, "[N-7.4] the loser releases both lines to the winner");
        bfm.read(R_IRQSTAT, d, e);
        check(d[1], "[N-7.4] [N-7.3] IRQSTAT[1] captured it");
        check(!d[0], "[N-7.3] and IRQSTAT[0] did not: the command never completed");
        check(irq, "[R-5] [N-7.3] arbitration-lost interrupt asserted");
        repeat (300) @(posedge pclk);
        bfm.read(R_STATUS, d, e);
        check(d[ST_AL], "[N-6.3] AL is sticky");
        tb_sda_low = 1'b0;                           // the winner's STOP
        repeat (100) @(posedge pclk);
        bfm.wr(R_IRQSTAT, 32'h2);
        bfm.read(R_STATUS, d, e);
        check(!d[ST_AL] && !irq, "[N-6.3] writing IRQSTAT[1] clears STATUS.AL and the interrupt");
        bfm.wr(R_IRQEN, 32'h0);
        u_slv.clear();
        bfm.wr(R_TXDATA, 32'h90);
        cmd(CMD_STA | CMD_WR, ok);
        wr_byte(8'h68, 0, ok);
        wr_byte(8'h5C, CMD_STO, ok);
        check(u_slv.bd_read(8'h68) == 8'h5C, "[N-7.4] retried from the START, the transfer then succeeds");

        // ---- DMACTL[1]: request while a byte can be accepted ([N-7.7]) --------------------------------
        bfm.wr(R_DMACTL, 32'h2);
        repeat (2) @(posedge pclk);
        check(dma_req, "[N-7.7] DMACTL[1] requests while EN and not TIP");
        bfm.wr(R_TXDATA, 32'h90);
        bfm.wr(R_CMD, CMD_STA | CMD_WR);
        repeat (2) @(posedge pclk);
        check(!dma_req, "[N-7.7] and not while a transfer is in progress");
        do begin bfm.read(R_STATUS, d, e); end while (d[ST_TIP]);
        repeat (2) @(posedge pclk);
        check(dma_req, "[N-7.7] the request returns when TIP clears");
        cmd(CMD_STO, ok);
        bfm.wr(R_CTRL, 32'h0);
        repeat (2) @(posedge pclk);
        check(!dma_req, "[N-7.7] and there is none while EN is 0");
        bfm.wr(R_DMACTL, 32'h0);
        bfm.wr(R_CTRL, 32'h1);

        // ---- CTRL.ABORT in every phase of a transfer ([N-7.5]) -----------------------------------------
        // Three kinds of transfer, twelve abort points across each: the address
        // byte from its START, a byte being READ (the slave is driving SDA), and
        // the STOP. After each one the block must have let go at once, stay
        // quiet, and work again once the board has freed the slave.
        bfm.wr(R_TIMEOUT, 32'd0);
        n_held = 0; n_tip = 0; n_noisy = 0; n_lost = 0;
        for (k = 0; k < 36; k++) begin
            case (k % 3)
                0: begin
                    bfm.wr(R_TXDATA, 32'h90);
                    bfm.wr(R_CMD, CMD_STA | CMD_WR);
                    repeat (10 + (k / 3) * 120) @(posedge pclk);
                end
                1: begin
                    bfm.wr(R_TXDATA, 32'h91);
                    cmd(CMD_STA | CMD_WR, ok);
                    bfm.wr(R_CMD, CMD_RD);
                    repeat (10 + (k / 3) * 120) @(posedge pclk);
                end
                default: begin
                    bfm.wr(R_TXDATA, 32'h90);
                    cmd(CMD_STA | CMD_WR, ok);
                    bfm.wr(R_CMD, CMD_STO);
                    repeat (2 + (k / 3) * 13) @(posedge pclk);
                end
            endcase
            bfm.wr(R_CTRL, 32'h3);                   // EN | ABORT
            repeat (2) @(posedge pclk);
            if (scl_oe || sda_oe) begin
                n_held++;
                $display("[ABORT] k=%0d: a line is still driven 2 pclk after the abort", k);
            end
            bfm.read(R_STATUS, d, e);
            if (d[ST_TIP]) n_tip++;
            e0 = oe_edges;
            repeat (400) @(posedge pclk);            // more than two bit times
            if (oe_edges != e0) begin
                n_noisy++;
                $display("[ABORT] k=%0d: the pins moved %0d times after the abort", k, oe_edges - e0);
            end
            bus_recover();
            bfm.wr(R_TXDATA, 32'h90);
            cmd(CMD_STA | CMD_WR, ok);
            wr_byte(8'h70, 0, ok);
            wr_byte(8'h80 + k[7:0], CMD_STO, ok);
            if (u_slv.bd_read(8'h70) != 8'h80 + k[7:0]) begin
                n_lost++;
                $display("[ABORT] k=%0d: the transfer after the abort did not arrive", k);
            end
        end
        check(n_held == 0, $sformatf("[N-7.5] CTRL.ABORT releases both pins at once, in every phase (%0d of 36 did not)", n_held));
        check(n_tip == 0, $sformatf("[N-7.5] and clears TIP (%0d of 36 did not)", n_tip));
        check(n_noisy == 0, $sformatf("[N-7.5] the aborted core is idle, not free-running: the pins never move again (%0d of 36 did)", n_noisy));
        check(n_lost == 0, $sformatf("[N-7.5] and the block transfers correctly afterwards (%0d of 36 did not)", n_lost));
        bfm.read(R_CTRL, d, e);
        check(d == 32'h1, $sformatf("[N-7.5] CTRL.ABORT is self-clearing: CTRL reads back EN only (%08h)", d));

        // ---- CTRL.EN = 0 in the middle of a transfer -------------------------------------------------------
        // With TIMEOUT at its reset value of 0 nothing else will ever clear TIP,
        // so this is the case that hangs firmware if the register layer gets it
        // wrong - and a command left latched would go out on the bus, unasked,
        // the moment the block is enabled again.
        bfm.wr(R_TXDATA, 32'h90);
        bfm.wr(R_CMD, CMD_STA | CMD_WR);
        repeat (500) @(posedge pclk);                // part-way through the address
        bfm.wr(R_CTRL, 32'h0);                       // EN = 0, no ABORT
        repeat (2) @(posedge pclk);
        check(!scl_oe && !sda_oe, "[R-8] disabling mid-transfer releases both pins");
        repeat (20) @(posedge pclk);
        bfm.read(R_STATUS, d, e);
        check(!d[ST_TIP], "[N-6.3] TIP clears when the block is disabled mid-transfer: no CMD is outstanding any more");
        bus_recover();
        u_slv.clear();
        e0 = oe_edges;
        bfm.wr(R_CTRL, 32'h1);                       // enable again
        repeat (2000) @(posedge pclk);
        check(oe_edges == e0 && u_slv.n_start == 0,
              $sformatf("[N-6.2] re-enabling does not replay the abandoned command: one CMD is one transfer (%0d pin changes, %0d START)",
                        oe_edges - e0, u_slv.n_start));
        bfm.read(R_STATUS, d, e);
        check(!d[ST_TIP], "[N-6.3] and TIP is still clear");
        bfm.wr(R_CTRL, 32'h3);                       // leave a known state behind
        repeat (8) @(posedge pclk);
        bus_recover();

        // a CMD written while the block is disabled must not be kept for later
        bfm.wr(R_CTRL, 32'h0);
        bfm.wr(R_TXDATA, 32'h90);
        bfm.wr(R_CMD, CMD_STA | CMD_WR);
        repeat (20) @(posedge pclk);
        bfm.read(R_STATUS, d, e);
        check(!d[ST_TIP], "[N-6.3] a CMD written while EN is 0 does not leave TIP set");
        u_slv.clear();
        e0 = oe_edges;
        bfm.wr(R_CTRL, 32'h1);
        repeat (2000) @(posedge pclk);
        check(oe_edges == e0 && u_slv.n_start == 0, "[N-6.2] nor does it run when the block is next enabled");
        bfm.wr(R_CTRL, 32'h3);
        repeat (8) @(posedge pclk);
        bus_recover();
        u_slv.clear();
        bfm.wr(R_TXDATA, 32'h90);
        cmd(CMD_STA | CMD_WR, ok);
        wr_byte(8'h72, 0, ok);
        wr_byte(8'hC3, CMD_STO, ok);
        check(u_slv.bd_read(8'h72) == 8'hC3, "[R-8] and the block transfers correctly after a disable");

        // ---- a CMD with nothing to do (not a check: the spec is silent) ------------------------------------
        bfm.wr(R_CMD, CMD_STA);                      // STA with no WR, RD or STO
        repeat (4000) @(posedge pclk);
        bfm.read(R_STATUS, d, e);
        $display("[OBSERVED] CMD = STA alone, TIMEOUT = 0: STATUS.TIP = %0b after 4000 pclk", d[ST_TIP]);
        bfm.wr(R_CTRL, 32'h3);
        repeat (8) @(posedge pclk);
        bus_recover();

        // ---- the invariants -----------------------------------------------------------------------
        check(drive_high == 0, "[R-9] [N-9.2] the block never drove either line high");
        check(pready_viol == 0, "[R-4] PREADY high in every cycle of every access");

        u_apbchk.report_result;
        check(apbviol == 0, "APB protocol checker clean on the config port");
        check(u_apbchk.n_access > 0, "APB protocol checker observed traffic");

        $display("tb_i2c: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end

    initial begin #40_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
