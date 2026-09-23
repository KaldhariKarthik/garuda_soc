`timescale 1ns/1ps
// =============================================================================
// tb_gpio.sv -- Block 19 GPIO (vendored PULP apb_gpio + GARUDA wrapper)
//
// Spec: GARUDA-GPIO-SPEC-001 §11. The two pins are modelled as a real
// bidirectional net with a pull-down, so an output can be read back and an
// external driver can be seen - which is what R-2 actually asks for.
// =============================================================================
module tb_gpio;

    logic pclk = 0, preset_n = 0;
    always #4 pclk = ~pclk;                        // 125 MHz

    garuda_apb_bfm bfm (.pclk(pclk), .preset_n(preset_n));

    wire       irq;
    wire [1:0] gpio_o, gpio_oe;
    wire [1:0] pin;

    // external driver, for the input tests
    logic [1:0] drv_en = 2'b00, drv_val = 2'b00;

    assign pin[0] = gpio_oe[0] ? gpio_o[0] : (drv_en[0] ? drv_val[0] : 1'bz);
    assign pin[1] = gpio_oe[1] ? gpio_o[1] : (drv_en[1] ? drv_val[1] : 1'bz);
    pulldown (weak0) pd0 (pin[0]);
    pulldown (weak0) pd1 (pin[1]);

    garuda_gpio_top #(.BLOCK_NUM(8'd19), .PAD_NUM(2)) dut (
        .pclk_i(pclk), .preset_n_i(preset_n),
        .psel_i(bfm.psel), .penable_i(bfm.penable), .pwrite_i(bfm.pwrite),
        .paddr_i(bfm.paddr), .pwdata_i(bfm.pwdata), .prdata_o(bfm.prdata),
        .pready_o(bfm.pready), .pslverr_o(bfm.pslverr),
        .irq_o(irq),
        .gpio_i(pin), .gpio_o(gpio_o), .gpio_oe(gpio_oe));

    int pready_viol = 0;
    always @(posedge pclk)
        if (preset_n && bfm.psel && !bfm.pready) pready_viol++;

    localparam [11:0] R_PADDIR = 12'h000, R_GPIOEN = 12'h004, R_PADIN  = 12'h008,
                      R_PADOUT = 12'h00C, R_SET    = 12'h010, R_CLR    = 12'h014,
                      R_INTEN  = 12'h018, R_INTTYPE= 12'h01C, R_INTSTAT= 12'h024,
                      R_IRQSTAT= 12'hFE0, R_IRQEN  = 12'hFE4, R_ID     = 12'hFEC;
    // INTTYPE, 2 bits per pin: 00 falling, 01 rising, 10 either
    localparam [1:0] IT_FALL = 2'b00, IT_RISE = 2'b01, IT_BOTH = 2'b10;

    int checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask

    // the synchronisers are 2 (shim) + 2 (IP) deep
    task automatic settle(); repeat (10) @(posedge pclk); endtask

    logic [31:0] d;
    bit e;

    initial begin
        $display("=== tb_gpio: Block 19 GPIO ===");

        repeat (4) @(posedge pclk);
        check(gpio_oe == 2'b00, "[R-8] both pins are inputs while in reset");
        preset_n = 1;
        settle();
        check(gpio_oe == 2'b00, "[R-8] both pins are inputs out of reset");

        bfm.read(R_ID, d, e);
        check(d == {16'h6A5D, 8'd19, 8'd1} && !e, "ID register reads block 19");
        bfm.read(12'h800, d, e);
        check(e, "[R-4] PSLVERR on an unmapped offset");

        // ---- registers -------------------------------------------------------------
        bfm.wr(R_PADOUT, 32'hFFFF_FFFF);
        bfm.read(R_PADOUT, d, e);
        check(d[1:0] == 2'b11, "[R-4] PADOUT holds the two pins we have");
        check(d[31:2] == 30'd0, "[N-6.2] and bits [31:2] read 0 - no pins behind them");
        bfm.wr(R_PADOUT, 32'h0);

        // ---- drive ------------------------------------------------------------------
        bfm.wr(R_PADDIR, 32'b01);                   // pin 0 output, pin 1 input
        settle();
        check(gpio_oe == 2'b01, "[R-3] PADDIR made pin 0 an output and left pin 1 an input");
        bfm.wr(R_SET, 32'b01);
        settle();
        check(pin[0] === 1'b1, "[R-1] PADOUTSET drives pin 0 high");
        bfm.wr(R_CLR, 32'b01);
        settle();
        check(pin[0] === 1'b0, "[R-1] PADOUTCLR drives pin 0 low");

        // ---- read back an output ------------------------------------------------------
        bfm.wr(R_GPIOEN, 32'b11);                   // input paths on for both
        bfm.wr(R_SET, 32'b01);
        settle();
        bfm.read(R_PADIN, d, e);
        check(d[0] == 1'b1, "[R-2] an output pin reads back the level it drives");
        bfm.wr(R_CLR, 32'b01);
        settle();
        bfm.read(R_PADIN, d, e);
        check(d[0] == 1'b0, "[R-2] and follows it low");

        // ---- read an externally driven pin ---------------------------------------------
        drv_en = 2'b10; drv_val = 2'b10;            // drive pin 1 high
        settle();
        bfm.read(R_PADIN, d, e);
        check(d[1] == 1'b1, "[R-2] PADIN follows an external driver on pin 1");
        drv_val = 2'b00;
        settle();
        bfm.read(R_PADIN, d, e);
        check(d[1] == 1'b0, "[R-7] and follows it low, through the synchronisers");

        // ---- interrupt: rising edge, and the two-step clear of [N-7.3] --------------------
        bfm.wr(R_IRQSTAT, 32'h1);
        bfm.wr(R_INTTYPE, {28'd0, IT_RISE, IT_RISE});
        bfm.wr(R_INTEN, 32'b10);                    // pin 1 only
        bfm.wr(R_IRQEN, 32'h1);
        settle();
        bfm.wr(R_IRQSTAT, 32'h1);
        repeat (4) @(posedge pclk);
        check(!irq, "[R-6] no interrupt before an edge");

        drv_val = 2'b10;                            // rising edge on pin 1
        settle();
        check(irq, "[R-6] rising edge on pin 1 raised the interrupt");
        repeat (60) @(posedge pclk);
        check(irq, "[R-6] still asserted 60 pclk later - held, not a pulse");

        // The IP's `interrupt` is a ONE-CYCLE edge pulse, so the held line the
        // CLIC sees is entirely the shim's sticky tail - and a W1C alone drops
        // it. INTSTATUS is a separate, per-pin sticky record.
        bfm.wr(R_IRQSTAT, 32'h1);
        repeat (4) @(posedge pclk);
        check(!irq, "[N-7.3] W1C on IRQSTAT clears the CLIC line - the IP's pulse is long gone");

        bfm.read(R_INTSTAT, d, e);
        check(d[1] == 1'b1, "[N-7.3] INTSTATUS still names pin 1 as the cause");
        bfm.read(R_INTSTAT, d, e);
        check(d[1] == 1'b0, "[N-7.3] and reading it clears it, so the next event is unambiguous");

        // ---- no interrupt from a pin that is not enabled ------------------------------------
        bfm.wr(R_IRQSTAT, 32'h1);
        drv_en = 2'b11; drv_val = 2'b10;
        settle();
        bfm.read(R_INTSTAT, d, e);
        bfm.wr(R_IRQSTAT, 32'h1);
        repeat (4) @(posedge pclk);
        bfm.wr(R_PADDIR, 32'b00);                   // both inputs now
        drv_val = 2'b11;                            // rising edge on pin 0 (INTEN off)
        settle();
        check(!irq, "[R-6] a rising edge on a pin with INTEN clear raises nothing");

        // ---- falling edge -------------------------------------------------------------------
        bfm.wr(R_INTTYPE, {28'd0, IT_FALL, IT_FALL});
        bfm.wr(R_INTEN, 32'b01);                    // pin 0
        bfm.read(R_INTSTAT, d, e);
        bfm.wr(R_IRQSTAT, 32'h1);
        settle();
        drv_val = 2'b10;                            // falling edge on pin 0
        settle();
        check(irq, "[R-6] falling-edge interrupt on pin 0");
        bfm.read(R_INTSTAT, d, e);
        check(d[0] == 1'b1, "[R-6] INTSTATUS names pin 0");
        bfm.wr(R_IRQSTAT, 32'h1);
        settle();

        // ---- either edge ---------------------------------------------------------------------
        bfm.wr(R_INTTYPE, {28'd0, IT_BOTH, IT_BOTH});
        bfm.wr(R_INTEN, 32'b01);
        bfm.read(R_INTSTAT, d, e);
        bfm.wr(R_IRQSTAT, 32'h1);
        settle();
        drv_val = 2'b11;                            // rising on pin 0
        settle();
        check(irq, "[R-6] either-edge interrupt fires on a rise");
        bfm.read(R_INTSTAT, d, e);
        bfm.wr(R_IRQSTAT, 32'h1);
        settle();
        drv_val = 2'b10;                            // falling on pin 0
        settle();
        check(irq, "[R-6] and on a fall");
        bfm.read(R_INTSTAT, d, e);
        bfm.wr(R_IRQSTAT, 32'h1);

        check(pready_viol == 0, "[R-5] PREADY high in every cycle of every access");

        $display("tb_gpio: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end

    initial begin #2_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
