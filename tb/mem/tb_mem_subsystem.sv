`timescale 1ns/1ps
// =============================================================================
// tb_mem_subsystem.sv -- Blocks 3/4/5 (ISRAM, Boot ROM, DSRAM), Rev 4.0 smoke
//
// Spec: GARUDA-MEM-SPEC-001 §11. A pipelined AHB master BFM drives the three
// memories through a minimal decoder, so back-to-back write->read traffic hits
// the synchronous-read macro exactly as the core and DMA will.
//
//   zero wait states on every legal access         [N-7.6]
//   byte/half/word lanes                            [N-7.3]
//   read-after-write through the write buffer       (ahb_mem_slave_if)
//   misaligned -> ERROR, ROM write -> ERROR          [N-7.4], §5.3
//   ILOCK refuses writes, SBA bypasses, reads ok     [N-7.8]..[N-7.10]
//   aliasing inside the 256 MiB granule              [N-7.2]
//   DSRAM bank decode on haddr[15:14]                [N-7.11]
//   random soak against a shadow model
// =============================================================================
module tb_mem_subsystem;

    reg hclk = 0, hreset_n = 0;
    always #2 hclk = ~hclk;

    // ---- master -----------------------------------------------------------------
    wire [31:0] haddr, hwdata, hrdata;
    wire [1:0]  htrans;
    wire        hwrite, hready, hresp;
    wire [2:0]  hsize, hburst;
    wire [3:0]  hprot;
    ahb_lite_master_bfm #(.HPROT(4'b0011), .QDEPTH(1024)) u_m (
        .hclk_i(hclk), .hreset_n_i(hreset_n),
        .haddr_o(haddr), .htrans_o(htrans), .hwrite_o(hwrite),
        .hsize_o(hsize), .hburst_o(hburst), .hprot_o(hprot), .hwdata_o(hwdata),
        .hrdata_i(hrdata), .hready_i(hready), .hresp_i(hresp));

    // ---- decode + return mux ----------------------------------------------------
    wire sel_i = haddr[31:28] == 4'h0, sel_r = haddr[31:28] == 4'h1, sel_d = haddr[31:28] == 4'h2;
    reg [1:0] dsel;                          // data-phase slave: 0=I 1=R 2=D
    always @(posedge hclk or negedge hreset_n)
        if (!hreset_n) dsel <= 0;
        else if (hready && htrans[1]) dsel <= sel_r ? 1 : sel_d ? 2 : 0;

    wire [31:0] rd_i, rd_r, rd_d;
    wire        ro_i, ro_r, ro_d, re_i, re_r, re_d;
    assign hrdata = dsel == 1 ? rd_r : dsel == 2 ? rd_d : rd_i;
    assign hready = dsel == 1 ? ro_r : dsel == 2 ? ro_d : ro_i;
    assign hresp  = dsel == 1 ? re_r : dsel == 2 ? re_d : re_i;

    reg ilock = 0, is_sba = 0;

    isram_top u_isram (
        .hclk_i(hclk), .hreset_n_i(hreset_n), .hsel_i(sel_i), .haddr_i(haddr),
        .htrans_i(htrans), .hwrite_i(hwrite), .hsize_i(hsize), .hburst_i(hburst),
        .hprot_i(hprot), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(rd_i), .hreadyout_o(ro_i), .hresp_o(re_i),
        .ilock_i(ilock), .hmaster_is_sba_i(is_sba));
    bootrom_top #(.INIT_FILE("")) u_rom (
        .hclk_i(hclk), .hreset_n_i(hreset_n), .hsel_i(sel_r), .haddr_i(haddr),
        .htrans_i(htrans), .hwrite_i(hwrite), .hsize_i(hsize), .hburst_i(hburst),
        .hprot_i(hprot), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(rd_r), .hreadyout_o(ro_r), .hresp_o(re_r));
    dsram_top u_dsram (
        .hclk_i(hclk), .hreset_n_i(hreset_n), .hsel_i(sel_d), .haddr_i(haddr),
        .htrans_i(htrans), .hwrite_i(hwrite), .hsize_i(hsize), .hburst_i(hburst),
        .hprot_i(hprot), .hwdata_i(hwdata), .hready_i(hready),
        .hrdata_o(rd_d), .hreadyout_o(ro_d), .hresp_o(re_d));

    // ---- checker ----------------------------------------------------------------
    wire [31:0] v_chk;
    ahb_lite_checker u_chk (.clk_i(hclk), .rst_n_i(hreset_n),
        .haddr_i(haddr), .htrans_i(htrans), .hsize_i(hsize), .hburst_i(hburst),
        .hwrite_i(hwrite), .hwdata_i(hwdata), .hready_i(hready), .hresp_i(hresp),
        .viol_count_o(v_chk));

    integer checks = 0, fails = 0;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; $display("[FAIL] %s (t=%0t)", what, $time); end
        else          $display("[PASS] %s", what);
    endtask

    localparam [2:0] B = 3'b000, H = 3'b001, W = 3'b010;
    task automatic go(input [31:0] a, input bit wr, input [31:0] d, input [2:0] sz);
        u_m.push_xfer(a, wr, d, sz, 3'b000, 2'b10, 8'd0);
    endtask
    task automatic drain;
        int g = 0;
        while (((u_m.q_head !== u_m.q_tail) || u_m.addr_outstanding || u_m.data_outstanding)
               && g < 200000) begin @(posedge hclk); g++; end
        if (g >= 200000) begin fails++; $display("[FAIL] bus hung"); end
        repeat (3) @(posedge hclk);
    endtask
    task automatic clr; u_m.r_head = 0; u_m.r_tail = 0; endtask

    // wait-state monitor: any cycle with a legal (non-error) data phase and hready low
    integer wait_viol = 0;
    always @(posedge hclk) if (hreset_n && !hready && !hresp) wait_viol++;
    integer buf_ovf = 0;

    // ---- shadow model -------------------------------------------------------------
    reg [7:0] shadow [bit [31:0]];
    function automatic [31:0] sh_rd(input [31:0] a);
        for (int k = 0; k < 4; k++)
            sh_rd[8*k +: 8] = shadow.exists((a & ~3) + k) ? shadow[(a & ~3) + k] : 8'hxx;
    endfunction
    task automatic sh_wr(input [31:0] a, input [31:0] d, input [2:0] sz);
        int n = (sz == B) ? 1 : (sz == H) ? 2 : 4;
        for (int k = 0; k < n; k++) shadow[a + k] = d[8*((a + k) % 4) +: 8];
    endtask

    int i, n, e;
    reg [31:0] exp_q [0:1023];
    reg [31:0] msk_q [0:1023];
    int soak_batches = 0;
    reg [31:0] a, d;
    reg [2:0]  sz;
    reg [31:0] rng = 32'h1234_5678;
    function automatic [31:0] rnd();
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng;
    endfunction

    initial begin
        $display("=== tb_mem_subsystem: Blocks 3/4/5 Rev 4.0 ===");
        for (i = 0; i < 1024; i++) u_rom.bd_write(32'h1000_0000 + 4*i, 32'hB000_0000 + i);
        repeat (3) @(posedge hclk); hreset_n = 1; repeat (2) @(posedge hclk);

        // ---- back-to-back write then read, same word, every memory -----------------
        clr();
        go(32'h0000_0100, 1, 32'h1111_2222, W);  go(32'h0000_0100, 0, 0, W);
        go(32'h2000_0100, 1, 32'h3333_4444, W);  go(32'h2000_0100, 0, 0, W);
        go(32'h2000_4200, 1, 32'h5555_6666, W);  go(32'h2000_8300, 1, 32'h7777_8888, W);
        go(32'h2000_C400, 1, 32'h9999_AAAA, W);
        go(32'h2000_4200, 0, 0, W); go(32'h2000_8300, 0, 0, W); go(32'h2000_C400, 0, 0, W);
        go(32'h1000_0010, 0, 0, W);
        drain();
        check(u_m.r_data[1] == 32'h1111_2222, "ISRAM write -> immediate read (buffer bypass)");
        check(u_m.r_data[3] == 32'h3333_4444, "DSRAM write -> immediate read (buffer bypass)");
        check(u_m.r_data[7] == 32'h5555_6666 && u_m.r_data[8] == 32'h7777_8888 &&
              u_m.r_data[9] == 32'h9999_AAAA, "DSRAM banks 1/2/3 by haddr[15:14]");
        check(u_dsram.g_bank[1].u_array.bd_read(12'h080) == 32'h5555_6666 &&
              u_dsram.g_bank[3].u_array.bd_read(12'h100) == 32'h9999_AAAA,
              "each word landed in the bank its address selects");
        check(u_m.r_data[10] == 32'hB000_0004, "Boot ROM word read");

        // ---- lanes ------------------------------------------------------------------
        clr();
        go(32'h2000_0200, 1, 32'hFFFF_FFFF, W);
        go(32'h2000_0201, 1, 32'h0000_AB00, B);
        go(32'h2000_0202, 1, 32'hCDEF_0000, H);
        go(32'h2000_0200, 0, 0, W);
        go(32'h2000_0203, 0, 0, B);
        go(32'h1000_0012, 0, 0, H);
        drain();
        check(u_m.r_data[3] == 32'hCDEF_ABFF, "byte + half lanes merge (through the write buffer)");
        check(u_m.r_data[5][31:16] == 16'hB000, "Boot ROM halfword read is legal [N-7.5]");

        // ---- errors ------------------------------------------------------------------
        clr();
        go(32'h2000_0301, 0, 0, W);            // misaligned word
        go(32'h2000_0301, 1, 32'h1, H);        // misaligned half
        go(32'h1000_0000, 1, 32'hBAD, W);      // ROM write
        go(32'h2000_0300, 0, 0, W);            // then a legal access
        drain();
        check(u_m.r_resp[0] && u_m.r_resp[1], "[N-7.4] misaligned word/half -> ERROR");
        check(u_m.r_resp[2], "Boot ROM write -> ERROR");
        check(u_rom.bd_read(32'h1000_0000) == 32'hB000_0000, "Boot ROM contents unchanged");
        check(!u_m.r_resp[3], "legal access after errors is OKAY");

        // ---- ILOCK ---------------------------------------------------------------------
        clr();
        go(32'h0000_0400, 1, 32'hA5A5_0001, W);
        drain();
        ilock = 1;
        go(32'h0000_0400, 1, 32'hDEAD_BEEF, W);
        go(32'h0000_0400, 0, 0, W);
        drain();
        check(u_m.r_resp[1], "[N-7.8] ISRAM write refused with ILOCK set");
        check(u_m.r_data[2] == 32'hA5A5_0001 && !u_m.r_resp[2], "[N-7.10] ISRAM read unaffected, data intact");
        is_sba = 1;
        go(32'h0000_0400, 1, 32'h5BA0_5BA0, W);
        drain();
        is_sba = 0;
        go(32'h0000_0400, 0, 0, W);
        drain();
        check(!u_m.r_resp[3] && u_m.r_data[4] == 32'h5BA0_5BA0, "[N-7.9] SBA write bypasses ILOCK");
        ilock = 0;

        // ---- aliasing ----------------------------------------------------------------------
        clr();
        go(32'h0001_0400, 0, 0, W);            // ISRAM + 64 KiB -> aliases word 0x400
        go(32'h1000_1010, 0, 0, W);            // ROM   + 4 KiB
        drain();
        check(u_m.r_data[0] == 32'h5BA0_5BA0 && u_m.r_data[1] == 32'hB000_0004,
              "[N-7.2] addresses alias inside the region");

        // ---- random soak vs shadow model ----------------------------------------------------
        for (i = 0; i < 16384; i++) shadow[32'h2000_0000 + i] = 8'h00;
        for (i = 0; i < 4096; i++) u_dsram.bd_write(32'h2000_0000 + 4*i, 32'h0);
        clr();
        n = 0;
        for (i = 0; i < 900; i++) begin
            a  = 32'h2000_0000 + (rnd() % 16384);
            case (rnd() % 3) 0: sz = B; 1: begin sz = H; a[0] = 0; end default: begin sz = W; a[1:0] = 0; end endcase
            d = rnd();
            if (rnd() % 2) begin go(a, 1, d << (8*a[1:0]), sz); sh_wr(a, d << (8*a[1:0]), sz); exp_q[n] = 32'hx; end
            else           begin go(a, 0, 0, sz); exp_q[n] = sh_rd(a); end
            msk_q[n] = lanes(a, sz);
            n++;
            if (n % 200 == 0) begin
                drain();
                e = 0;
                for (int k = 0; k < 200; k++)
                    if (exp_q[k] !== 32'hx && ((u_m.r_data[k] ^ exp_q[k]) & msk_q[k]) != 0) e++;
                if (e) begin fails++; $display("[FAIL] soak batch: %0d mismatches", e); end
                soak_batches++;
                clr(); n = 0;
            end
        end
        drain();
        check(soak_batches == 4, "random soak: 4 x 200 mixed-size accesses vs shadow model");

        check(wait_viol == 0, "[N-7.6] zero wait states on every legal access");
        check(v_chk == 2, "AHB-Lite checker: only the 2 deliberate misaligned transfers flagged");

        $display("tb_mem_subsystem: checks=%0d  FAIL=%0d", checks, fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end

    function automatic [31:0] lanes(input [31:0] a, input [2:0] sz);
        case (sz)
            B:       lanes = 32'hFF << (8*a[1:0]);
            H:       lanes = a[1] ? 32'hFFFF_0000 : 32'h0000_FFFF;
            default: lanes = 32'hFFFF_FFFF;
        endcase
    endfunction

    initial begin #5_000_000; $display("TIMEOUT"); $display("RESULT: FAILED"); $finish; end
endmodule
