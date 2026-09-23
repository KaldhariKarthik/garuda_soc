`timescale 1ns/1ps
// =============================================================================
// tb_uart.sv -- Blocks 16/17/18 UART (vendored PULP 16550 + GARUDA wrapper)
//
// Spec: GARUDA-UART-SPEC-001 §11. Drives a real uart_model on the pins.
//
// Most tests run at divisor 124 (1 us per bit) to keep the simulation short;
// t_uart_baud uses the real 115200 divisor once, because the point of that
// test is the arithmetic in [N-7.1], not the data path.
// =============================================================================
module tb_uart;

    logic pclk = 0, preset_n = 0;
    always #4 pclk = ~pclk;                        // 125 MHz

    garuda_apb_bfm bfm (.pclk(pclk), .preset_n(preset_n));

    logic dma_ack = 0;
    wire  irq, dma_req, tx, rx;

    garuda_uart_top #(.BLOCK_NUM(8'd16)) dut (
        .pclk_i(pclk), .preset_n_i(preset_n),
        .psel_i(bfm.psel), .penable_i(bfm.penable), .pwrite_i(bfm.pwrite),
        .paddr_i(bfm.paddr), .pwdata_i(bfm.pwdata), .prdata_o(bfm.prdata),
        .pready_o(bfm.pready), .pslverr_o(bfm.pslverr),
        .irq_o(irq), .dma_req_o(dma_req), .dma_ack_i(dma_ack),
        .uart_tx_o(tx), .uart_rx_i(rx));

    uart_model #(.BIT_NS(1000.0)) u_term (.dut_rx_o(rx), .dut_tx_i(tx));

    dma_req_checker #(.NAME("uart")) u_dchk (
        .clk_i(pclk), .rst_n_i(preset_n), .req_i(dma_req), .ack_i(dma_ack));

    int pready_viol = 0;
    always @(posedge pclk)
        if (preset_n && bfm.psel && !bfm.pready) pready_viol++;

    // register word offsets (UART-SPEC §6)
    localparam [11:0] R_RBR = 12'h000, R_THR = 12'h000, R_DLL = 12'h000,
                      R_IER = 12'h004, R_DLM = 12'h004, R_IIR = 12'h008,
                      R_FCR = 12'h008, R_LCR = 12'h00C, R_MCR = 12'h010,
                      R_LSR = 12'h014, R_MSR = 12'h018, R_SCR = 12'h01C,
                      R_IRQSTAT = 12'hFE0, R_IRQEN = 12'hFE4,
                      R_DMACTL  = 12'hFE8, R_ID    = 12'hFEC;
    localparam LSR_DR = 0, LSR_PE = 2, LSR_FE = 3, LSR_THRE = 5;

    // 125 MHz / (div+1); div 124 = 1 us per bit, div 1084 = 115207 baud
    localparam int DIV_FAST = 124, DIV_115K = 1084;

    int checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask

    task automatic set_baud(input int div, input bit par);
        bit e;
        bfm.wr(R_LCR, 32'h83);                       // DLAB=1, 8 bits, 1 stop
        bfm.wr(R_DLL, div & 32'hFF);
        bfm.wr(R_DLM, (div >> 8) & 32'hFF);
        bfm.wr(R_LCR, par ? 32'h0B : 32'h03);        // DLAB=0, parity per arg
        u_term.parity_en = par;
    endtask

    // wait for the DUT to have a received byte
    task automatic wait_dr(output bit ok);
        logic [31:0] d;
        bit e;
        int g = 0;
        do begin bfm.read(R_LSR, d, e); g++; end while (!d[LSR_DR] && g < 20000);
        ok = d[LSR_DR];
    endtask

    task automatic drain_rx();
        logic [31:0] dd;
        bit ee;
        int g = 0;
        bfm.read(R_LSR, dd, ee);
        while (dd[LSR_DR] && g < 40) begin
            bfm.read(R_RBR, dd, ee);
            bfm.read(R_LSR, dd, ee);
            g++;
        end
        repeat (20) @(posedge pclk);          // let the line settle idle
    endtask

    task automatic put(input byte unsigned b);
        logic [31:0] d;
        bit e;
        int g = 0;
        do begin bfm.read(R_LSR, d, e); g++; end while (!d[LSR_THRE] && g < 20000);
        bfm.wr(R_THR, {24'd0, b});
    endtask

    logic [31:0] d;
    bit e, ok;
    byte unsigned b;
    int i, t, nbad;
    real lo_ok, hi_ok;

    initial begin
        $display("=== tb_uart: Blocks 16/17/18 UART ===");

        repeat (4) @(posedge pclk);
        check(tx === 1'b1, "[R-8] tx is high (line idle) while in reset");
        preset_n = 1;
        repeat (4) @(posedge pclk);
        check(tx === 1'b1, "[R-8] tx is high out of reset");

        bfm.read(R_ID, d, e);
        check(d == {16'h6A5D, 8'd16, 8'd1} && !e, "ID register reads block 16");
        bfm.read(12'h800, d, e);
        check(e, "PSLVERR on an unmapped offset");

        // ---- word offsets reach the intended 16550 registers ---------------------
        // SCR/MCR/MSR have no write case and no read case upstream: they decode
        // cleanly (no PSLVERR) and read 0. [N-13.1]/[N-13.2] say so; this test
        // holds upstream to it, and will fail loudly if a re-vendor adds them.
        bfm.wr(R_SCR, 32'h0000_00A5);
        bfm.read(R_SCR, d, e);
        check(d == 32'd0 && !e, $sformatf("[N-13.2] SCR is not implemented: decodes, reads 0 (%08h)", d));
        bfm.read(R_MSR, d, e);
        check(d == 32'd0 && !e, "[N-13.1] MSR is not implemented: decodes, reads 0");
        bfm.read(R_LSR, d, e);
        check(d[31:8] == 24'd0, "[R-3] PRDATA[31:8] reads 0, not X");
        bfm.wr(R_LCR, 32'h0000_0003);
        bfm.read(R_LCR, d, e);
        check(d == 32'h3, "[R-3] LCR at word offset 0x0C");

        // ---- DLAB banking ---------------------------------------------------------
        bfm.wr(R_LCR, 32'h83);                       // DLAB=1
        bfm.wr(R_DLL, 32'h3C); bfm.wr(R_DLM, 32'h04);
        bfm.read(R_DLL, d, e); check(d == 32'h3C, "[R-3] DLAB=1: offset 0x00 is DLL");
        bfm.read(R_DLM, d, e); check(d == 32'h04, "[R-3] DLAB=1: offset 0x04 is DLM");
        bfm.wr(R_LCR, 32'h03);                       // DLAB=0
        bfm.read(R_IER, d, e); check(d == 32'h0, "[R-3] DLAB=0: offset 0x04 is IER");

        // ---- transmit ---------------------------------------------------------------
        set_baud(DIV_FAST, 0);
        u_term.clear();
        put(8'h41);                                   // 'A'
        t = 0;
        while (u_term.n_rx() == 0 && t < 40000) begin @(posedge pclk); t++; end
        check(u_term.n_rx() == 1, "[R-1] the terminal received one frame");
        if (u_term.n_rx()) begin
            b = u_term.get();
            check(b == 8'h41, $sformatf("[R-1] and it was 0x41 (got 0x%02h)", b));
        end
        check(u_term.viol() == 0, "[R-1] frame was well formed (stop bit high)");

        // ---- receive ----------------------------------------------------------------
        u_term.send(8'h5A);
        wait_dr(ok);
        check(ok, "[R-1] LSR[0] set after the terminal sent a byte");
        bfm.read(R_RBR, d, e);
        check(d[7:0] == 8'h5A, $sformatf("[R-1] RBR returned 0x5A (got 0x%02h)", d[7:0]));
        bfm.read(R_LSR, d, e);
        check(!d[LSR_DR], "[R-1] reading RBR popped the FIFO");

        // ---- loopback, both directions ------------------------------------------------
        u_term.clear();
        nbad = 0;
        for (i = 0; i < 32; i++) put(8'h20 + i[7:0]);
        t = 0;
        while (u_term.n_rx() < 32 && t < 500000) begin @(posedge pclk); t++; end
        check(u_term.n_rx() == 32, $sformatf("[R-1] 32 bytes out (%0d arrived)", u_term.n_rx()));
        for (i = 0; i < 32 && u_term.n_rx() > 0; i++) begin
            b = u_term.get();
            if (b != 8'h20 + i[7:0]) nbad++;
        end
        check(nbad == 0, $sformatf("[R-1] all 32 correct and in order (%0d wrong)", nbad));

        nbad = 0;
        for (i = 0; i < 32; i++) begin
            u_term.send(8'hC0 + i[7:0]);
            wait_dr(ok);
            bfm.read(R_RBR, d, e);
            if (!ok || d[7:0] != 8'hC0 + i[7:0]) nbad++;
        end
        check(nbad == 0, $sformatf("[R-1] 32 bytes in, all correct (%0d wrong)", nbad));
        check(u_term.viol() == 0, "[R-1] no framing violation in either direction");

        // ---- baud arithmetic at the real rate --------------------------------------
        set_baud(DIV_115K, 0);
        u_term.bit_ns = 8680.0;
        u_term.clear();
        u_term.reset_meas();
        put(8'h55);                                   // alternating: edge gap = 1 bit
        t = 0;
        while (u_term.n_rx() == 0 && t < 200000) begin @(posedge pclk); t++; end
        check(u_term.n_rx() == 1 && u_term.get() == 8'h55, "[R-2] 0x55 at divisor 1084");
        check(u_term.min_edge_ns > 8590.0 && u_term.min_edge_ns < 8770.0,
              $sformatf("[R-2] bit period %0.0f ns (8680 +/-1%% = 8593..8767)", u_term.min_edge_ns));

        // ---- receiver baud tolerance ([N-8.1], OPEN-U1) --------------------------------
        // Sweep the terminal's bit period against a fixed DUT divisor and find
        // where reception actually breaks. Upstream samples at the bit boundary,
        // so this is a measurement, not a quotation from a datasheet.
        set_baud(DIV_FAST, 0);
        u_term.bit_ns = 1000.0;
        lo_ok = 0.0; hi_ok = 0.0;
        for (i = -60; i <= 60; i = i + 5) begin
            u_term.bit_ns = 1000.0 * (1.0 + i / 1000.0);   // -6% .. +6% in 0.5% steps
            u_term.clear();
            // A point that fails can leave the receiver mid-frame and a stray
            // byte in the FIFO; without draining, one bad point poisons every
            // point after it and the measurement is meaningless.
            drain_rx();
            u_term.send(8'hA5);
            wait_dr(ok);
            bfm.read(R_RBR, d, e);
            if (ok && d[7:0] == 8'hA5) begin
                if (i < 0 && (lo_ok == 0.0 || i / 10.0 < lo_ok)) lo_ok = i / 10.0;
                if (i > 0 && i / 10.0 > hi_ok)                   hi_ok = i / 10.0;
            end
        end
        $display("[MEASURED] receiver baud tolerance: %0.1f%% .. +%0.1f%%", lo_ok, hi_ok);
        check(lo_ok <= -1.0 && hi_ok >= 1.0,
              $sformatf("[N-8.1] receiver tolerates at least +/-1%% (measured %0.1f%%..+%0.1f%%)",
                        lo_ok, hi_ok));
        u_term.bit_ns = 1000.0;

        // ---- parity and framing are REPORTED (patch 0001, was ERR-U2) -------------
        // Upstream could not do this: err_clr_i was tied high so the error flop
        // could never set, and the byte was pushed to the FIFO one state before
        // the parity bit was even checked. Both are fixed in
        // rtl/third_party/pulp/apb_uart_sv/patches/0001-*.patch.
        set_baud(DIV_FAST, 1);                        // 8E1
        drain_rx();
        bfm.wr(R_IRQSTAT, 32'h7);
        u_term.clear();
        u_term.send(8'h3C, 1'b0);                     // correct parity
        wait_dr(ok);
        bfm.read(R_LSR, d, e);
        check(ok && !d[LSR_PE], "[R-7] a clean 8E1 frame sets no parity error");
        bfm.read(R_RBR, d, e);
        check(d[7:0] == 8'h3C, "[R-1] and carries its data");

        drain_rx();
        bfm.wr(R_IRQSTAT, 32'h7);
        u_term.send(8'h3C, 1'b1);                     // deliberately WRONG parity
        wait_dr(ok);
        bfm.read(R_LSR, d, e);
        check(d[LSR_PE], "[R-7] LSR[2] flags the parity error");
        bfm.read(R_RBR, d, e);
        check(d[7:0] == 8'h3C, "[R-7] and the byte is still delivered, not dropped");
        bfm.read(R_IRQSTAT, d, e);
        check(d[2], "[R-7] IRQSTAT[2] captured the line error");

        // the flag belongs to ITS OWN byte and must not leak into the next one
        drain_rx();
        u_term.send(8'h5A, 1'b0);                     // clean, right after a bad one
        wait_dr(ok);
        bfm.read(R_LSR, d, e);
        check(!d[LSR_PE], "[R-7] the error does not leak into the following byte");
        bfm.read(R_RBR, d, e);
        check(d[7:0] == 8'h5A, "[R-7] which is itself correct");

        // framing: hold the stop bit low
        set_baud(DIV_FAST, 0);
        drain_rx();
        bfm.wr(R_IRQSTAT, 32'h7);
        u_term.send_framing_error(8'h96);
        wait_dr(ok);
        bfm.read(R_LSR, d, e);
        check(d[LSR_FE], "[R-7] LSR[3] flags a low stop bit (framing error)");
        bfm.read(R_RBR, d, e);
        check(d[7:0] == 8'h96, "[R-7] and that byte is still delivered");
        bfm.read(R_IRQSTAT, d, e);
        check(d[2], "[R-7] framing raises the same line-error event");

        drain_rx();
        u_term.send(8'h69);
        wait_dr(ok);
        bfm.read(R_LSR, d, e);
        check(!d[LSR_FE], "[R-7] framing error does not leak into the next byte");
        bfm.read(R_RBR, d, e);
        check(d[7:0] == 8'h69, "[R-7] which is itself correct");

        // ---- back-to-back frames, no inter-frame gap ------------------------------
        // Patch 0001 moved the FIFO push to after STOP_BIT, so the receiver now
        // returns to IDLE at the stop/next-start boundary instead of one state
        // earlier. This is the test for that: 16 frames with zero idle time
        // between them, which is the worst case for missing the next start bit.
        drain_rx();
        u_term.clear();
        nbad = 0;
        // Each branch needs its OWN index: a shared module-level loop variable
        // is incremented by both threads and the test then checks nonsense.
        fork
            begin : b2b_send
                int si;
                for (si = 0; si < 16; si++) u_term.send(8'h80 + si[7:0]);
            end
            begin : b2b_recv
                int ri;
                logic [31:0] rd;
                bit re, rok;
                for (ri = 0; ri < 16; ri++) begin
                    wait_dr(rok);
                    bfm.read(R_RBR, rd, re);
                    if (!rok || rd[7:0] != 8'h80 + ri[7:0]) begin
                        nbad++;
                        $display("[B2B] index %0d: expected %02h got %02h ok=%b at %0t",
                                 ri, 8'h80 + ri[7:0], rd[7:0], rok, $time);
                    end
                end
            end
        join
        check(nbad == 0, $sformatf("[N-8.2] 16 back-to-back frames, no gap (%0d wrong)", nbad));
        bfm.read(R_LSR, d, e);
        check(!d[LSR_FE] && !d[LSR_PE], "[N-8.2] and none of them framed badly");
        drain_rx();

        // ---- interrupt --------------------------------------------------------------------
        bfm.wr(R_IRQSTAT, 32'h7);
        bfm.wr(R_IRQEN, 32'h1);                       // RX data available only
        check(!irq, "[R-5] no interrupt with an empty RX FIFO");
        u_term.send(8'h77);
        t = 0;
        while (!irq && t < 40000) begin @(posedge pclk); t++; end
        check(irq, "[R-5] RX interrupt asserted");
        repeat (60) @(posedge pclk);
        check(irq, "[R-5] still asserted 60 pclk later (level, not a pulse)");
        bfm.wr(R_IRQSTAT, 32'h1);
        repeat (2) @(posedge pclk);
        check(irq, "[R-5] W1C alone does not clear it - the byte is still waiting");
        bfm.read(R_RBR, d, e);                        // drain the source
        repeat (4) @(posedge pclk);                   // lsr_q is refreshed in idle cycles
        bfm.wr(R_IRQSTAT, 32'h1);
        repeat (4) @(posedge pclk);
        check(!irq, "[R-5] cleared once the source is drained and W1C written");
        bfm.wr(R_IRQEN, 32'h0);

        // ---- DMA -----------------------------------------------------------------------------
        bfm.wr(R_DMACTL, 32'h1);                      // request on RX data
        check(!dma_req, "[R-6] no request with an empty RX FIFO");
        u_term.send(8'hE7);
        t = 0;
        while (!dma_req && t < 40000) begin @(posedge pclk); t++; end
        check(dma_req, "[R-6] dma_req asserts when a byte arrives");
        bfm.read(R_RBR, d, e);
        check(d[7:0] == 8'hE7, "[R-6] the DMA's read returns the byte");
        check(d[31:8] == 24'd0, "[R-6a] word-sized beat, byte in [7:0], rest 0");
        @(posedge pclk); #0.1 dma_ack = 1;
        @(posedge pclk); #0.1 dma_ack = 0;
        repeat (4) @(posedge pclk);
        check(!dma_req, "[R-6] dma_req drops after the ack");
        check(u_dchk.violations() == 0, "[R-6] dma_req_checker clean");

        // ---- and never while DLAB is set ---------------------------------------------------
        u_term.send(8'h11);
        t = 0;
        while (!dma_req && t < 40000) begin @(posedge pclk); t++; end
        check(dma_req, "a byte is waiting, so a request is pending");
        bfm.wr(R_LCR, 32'h83);                        // DLAB=1
        repeat (4) @(posedge pclk);
        check(!dma_req, "[N-7.6b] the request is withdrawn while DLAB is set");
        bfm.wr(R_LCR, 32'h03);                        // DLAB=0
        repeat (4) @(posedge pclk);
        check(dma_req, "[N-7.6b] and comes back when DLAB is cleared");
        bfm.wr(R_DMACTL, 32'h0);
        bfm.read(R_RBR, d, e);

        check(pready_viol == 0, "[R-4] PREADY high in every cycle of every access");

        $display("tb_uart: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end

    initial begin #20_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
