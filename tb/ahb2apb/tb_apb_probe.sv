`timescale 1ns/1ps
// =============================================================================
// tb_apb_probe.sv -- AHB2APB bridge defect reproducers (Track A, bus plan B0)
//
// One case per +CASE. Each case checks the SPECIFIED behaviour, so it fails on
// today's RTL exactly while its defect is open (xfail with the bug ID) and
// passes once fixed. Same structure as tb/dma/tb_dma_probe.sv.
//
//   +CASE=alias    APB-2 / Fresh plan DMA-CON-04: the APB aperture is
//                  0x4000_0000..0x4000_BFFF (garuda_system.yaml, 12 x 4 KiB).
//                  An access above it (0x4001_5000, 0x4FFF_5000) must be an
//                  ERROR with no PSEL. Today the bridge decodes only
//                  HADDR[15:12], so it lands in window 5 (dma_cfg).
//   +CASE=control  the in-aperture twin (0x4000_5000) completes OKAY with
//                  exactly one PSEL[5]; 0x4000_C000 (window 12, unmapped)
//                  is an ERROR with no PSEL. Must pass today: it proves the
//                  probe's counters and response check can see both outcomes.
//
// DUT: real clk_div (production hclk/pclk relation) + real ahb2apb_bridge with
// every map window present (MASK_ALL). Each window has a counting target that
// is always ready, so the only thing measured is which PSEL the bridge raises.
// =============================================================================
module tb_apb_probe;

    // Reset starts X and goes 0 at #0: X->0 is a negedge (TB-22, the reset must
    // arrive as an edge), and clk_div_sva's guard (raw_rst_n === 1) stays quiet
    // while pclk leaves X at time 0 (the SHIM-RSTEDGE artifact, avoided, not waived).
    reg refclk = 0, ext_rst_n;
    initial #0 ext_rst_n = 1'b0;
    always #1 refclk = ~refclk;

    wire aon, hclk, pclk, pclk_phase, div_busy;
    wire [1:0] div_act;
    clk_div u_clk (.refclk_i(refclk), .raw_rst_n_i(ext_rst_n), .div_sel_i(2'b00),
                   .aon_clk_o(aon), .hclk_o(hclk), .pclk_o(pclk), .pclk_phase_o(pclk_phase),
                   .div_act_o(div_act), .div_busy_o(div_busy));

    // resets driven non-blocking, as the reset controller's flops do (a blocking release on
    // a clock edge races the bridge's preset sync flop: see tb/ahb2apb/env/tb_apb_env.sv)
    reg hreset_n = 1, preset_n = 1;
    initial #0 begin hreset_n <= 1'b0; preset_n <= 1'b0; end

    wire [31:0] haddr, hwdata, hrdata;
    wire [1:0]  htrans;
    wire        hwrite, hreadyout, hresp;
    wire [2:0]  hsize, hburst;
    wire [3:0]  hprot;
    ahb_lite_master_bfm #(.HPROT(4'b0011)) u_m (
        .hclk_i(hclk), .hreset_n_i(hreset_n),
        .haddr_o(haddr), .htrans_o(htrans), .hwrite_o(hwrite),
        .hsize_o(hsize), .hburst_o(hburst), .hprot_o(hprot), .hwdata_o(hwdata),
        .hrdata_i(hrdata), .hready_i(hreadyout), .hresp_i(hresp));

    wire [11:0] psel, paddr;
    wire        penable, pwrite;
    wire [31:0] pwdata;
    wire [12*32-1:0] prdata;
    wire [11:0] pready, pslverr;

    // hsel as the real decoder gives it: HADDR[31:28] == 4 (ahb_decoder.v)
    ahb2apb_bridge #(.WINDOW_MASK(16'h0FFF), .APB_DIV(24'h0)) u_dut (
        .hclk_i(hclk), .hreset_n_i(hreset_n), .pclk_i(pclk), .preset_n_i(preset_n),
        .pclk_phase_i(pclk_phase),
        .hsel_i(haddr[31:28] == 4'h4), .haddr_i(haddr), .htrans_i(htrans),
        .hwrite_i(hwrite), .hsize_i(hsize), .hwdata_i(hwdata), .hready_i(hreadyout),
        .hrdata_o(hrdata), .hreadyout_o(hreadyout), .hresp_o(hresp),
        .psel_o(psel), .penable_o(penable), .pwrite_o(pwrite), .paddr_o(paddr),
        .pwdata_o(pwdata), .prdata_i(prdata), .pready_i(pready), .pslverr_i(pslverr));

    // ---- counting targets: one count per APB transfer (PSEL & PENABLE & PREADY)
    integer nsel [0:11];
    genvar g;
    generate for (g = 0; g < 12; g = g + 1) begin : g_win
        assign prdata[32*g +: 32] = 32'hA5A5_0000 | g;
        assign pready[g]  = 1'b1;
        assign pslverr[g] = 1'b0;
        initial nsel[g] = 0;
        always @(posedge pclk) if (preset_n && psel[g] && penable) nsel[g] = nsel[g] + 1;
    end endgenerate

    function automatic int total_sel();
        int t = 0;
        for (int i = 0; i < 12; i++) t += nsel[i];
        return t;
    endfunction

    integer checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask

    // One word transfer, waited to completion; returns its AHB response.
    task automatic xfer(input [31:0] a, input bit w, output bit resp);
        int guard = 0;
        u_m.rsp_clear();
        u_m.push_xfer(a, w, 32'hC0DE_0000 | a[15:0], 3'b010, 3'b000, 2'b10, 8'd0);
        while (u_m.rsp_count() == 0 && guard < 2000) begin @(posedge hclk); guard++; end
        if (guard >= 2000) begin fails++; $display("[FAIL] bus hung on 0x%08h", a); end
        resp = u_m.rsp_resp(0);
        repeat (6) @(posedge pclk);                    // let any APB tail finish
    endtask

    // Expect: ERROR and no APB transfer anywhere.
    task automatic expect_fault(input [31:0] a, input bit w, input string tag);
        bit r; int n0 = total_sel();
        xfer(a, w, r);
        check(r == 1'b1, $sformatf("%s 0x%08h %s -> AHB ERROR", tag, a, w ? "write" : "read"));
        check(total_sel() == n0,
              $sformatf("%s 0x%08h %s -> no PSEL (window 5 count %0d)", tag, a, w ? "write" : "read", nsel[5]));
    endtask

    string tcase;
    initial begin
        if (!$value$plusargs("CASE=%s", tcase)) tcase = "";
        $display("=== tb_apb_probe +CASE=%s ===", tcase);
        #50 ext_rst_n = 1'b1;
        repeat (4) @(posedge hclk);
        hreset_n <= 1'b1;
        repeat (8) @(posedge hclk);
        preset_n <= 1'b1;
        repeat (8) @(posedge hclk);

        case (tcase)
        "alias": begin
            expect_fault(32'h4001_5000, 1'b1, "[APB-2] [R-8] above the aperture");
            expect_fault(32'h4001_5000, 1'b0, "[APB-2] [R-8] above the aperture");
            expect_fault(32'h4FFF_5000, 1'b1, "[APB-2] [R-8] top of region 4");
        end
        "control": begin
            bit r; int b5 = nsel[5];
            xfer(32'h4000_5000, 1'b1, r);
            check(r == 1'b0, "[control] 0x40005000 write -> OKAY");
            check(nsel[5] == b5 + 1 && total_sel() == b5 + 1, "[control] exactly one PSEL[5] transfer");
            expect_fault(32'h4000_C000, 1'b1, "[control] [R-8] window 12 unmapped");
        end
        default: begin
            $display("[FAIL] unknown +CASE=%s (alias control)", tcase);
            fails++;
        end
        endcase

        $display("CHECKS: %0d  FAILS: %0d", checks, fails);
        if (fails == 0 && checks > 0) $display("RESULT: PASSED");
        else                          $display("RESULT: FAILED");
        $finish;
    end

    initial begin #2_000_000; $display("[FAIL] global timeout"); $display("RESULT: FAILED"); $finish; end
endmodule
