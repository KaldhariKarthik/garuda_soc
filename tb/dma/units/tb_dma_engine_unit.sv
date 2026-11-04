`timescale 1ns/1ps
// =============================================================================
// tb_dma_engine_unit.sv -- dma_engine on its own (Track A wrap-up 2026-10-12).
// The bench is the arbiter (grant), the channels (SAR / DAR / SIZE, held through a
// beat), and an AHB-Lite slave (random data-phase waits, the two-cycle ERROR).
// Expected per beat, from GARUDA-DMA-SPEC-001 and the rulings:
//   - R-9: a source in 0x0xxx_xxxx / 0x1xxx_xxxx is refused: beat error, ERRPHASE 1,
//     no transfer at all
//   - one SINGLE read at SAR (HTRANS NONSEQ, HBURST 000, HSIZE = SIZE, address and
//     control held while HREADY is low); an ERROR answer ends the beat: ERRPHASE 1,
//     no write
//   - a destination in the refused regions, or a SAR / DAR not aligned to SIZE: ERRPHASE 2
//     (DAR) or 1 (SAR), and no read and no write (DMA-10, DMA-12 rulings, 2026-11-01; until
//     then the source was read before a bad DAR was refused)
//   - one SINGLE write at DAR, same HSIZE, whose byte lanes carry the read's lane
//     (byte: the SAR lane replicated x4; halfword: x2); an ERROR answer: ERRPHASE 2
//   - success: beat_done of that channel, and dma_ack of that channel high for
//     ACK_CYCLES = 2 hclk (D-16); an error: no ack
//   - no grant is taken in a cycle that reports a result (ENG-1); HTRANS is only
//     IDLE or NONSEQ; busy while a beat is in progress
// =============================================================================
module tb_dma_engine_unit;
    logic clk = 0, rst_n = 0;
    always #2 clk = ~clk;
    logic gv = 0; logic [2:0] gch = 0;
    logic [191:0] sar = 0, dar = 0; logic [11:0] size = 0; logic [5:0] m2m = 0;
    wire [1:0] bsz; wire [5:0] infl;      // 2026-11-01: DMA-14 beat size, DMA-9 in-flight
    wire [5:0] bdone, berr, ack; wire [2:0] eph;
    wire [31:0] haddr, hwdata; wire [1:0] htrans; wire hwrite; wire [2:0] hsize, hburst; wire busy;
    logic [31:0] hrdata = 0; logic hready = 1, hresp = 0;
    dma_engine #(.ACK_CYCLES(2)) dut (.hclk_i(clk), .hreset_n_i(rst_n), .grant_valid_i(gv), .grant_ch_i(gch),
        .sar_i(sar), .dar_i(dar), .size_i(size), .m2m_i(m2m), .beat_size_o(bsz), .inflight_o(infl), .beat_done_o(bdone), .beat_err_o(berr), .err_phase_o(eph),
        .dma_ack_o(ack), .haddr_o(haddr), .htrans_o(htrans), .hwrite_o(hwrite), .hsize_o(hsize), .hburst_o(hburst),
        .hwdata_o(hwdata), .hrdata_i(hrdata), .hready_i(hready), .hresp_i(hresp), .busy_o(busy));
    int checks = 0, fails = 0, n_ok = 0, n_rerr = 0, n_werr = 0, n_r9s = 0, n_r9d_read = 0, n_r9d_noread = 0, n_mis = 0, n_m2m = 0;
    task automatic check(input bit c, input string s);
        checks++;
        if (!c) begin fails++; if (fails <= 12) $display("[FAIL] %s (t=%0t)", s, $time); end
    endtask
    // ---- AHB slave: decides waits / ERROR per data phase; logs transfers ------------------
    typedef struct { logic [31:0] a; bit w; logic [2:0] sz; logic [31:0] d; bit e; } xfer_t;
    xfer_t log_q [$];
    int  waits_left; bit dph, dph_w, dph_err; logic [31:0] dph_a; logic [2:0] dph_sz;
    bit force_rerr, force_werr;
    logic [31:0] rword;
    int  err_state;                                    // 0 none, 1 first ERROR cycle
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin dph = 0; hready <= 1; hresp <= 0; err_state = 0; end
        else begin
            // address held stable while HREADY is low
            if (htrans[1] && !hready) check(haddr == dph_a || dph, "address phase changed while HREADY low");
            if (dph) begin
                if (err_state == 1) begin hready <= 1; hresp <= 1; err_state = 2; end
                else if (err_state == 2) begin
                    log_q.push_back('{dph_a, dph_w, dph_sz, dph_w ? hwdata : rword, 1}); dph = 0; err_state = 0;
                    hready <= 1; hresp <= 0;
                end else if (waits_left > 0) begin waits_left--; hready <= 0; end
                else if (dph_err) begin hready <= 0; hresp <= 1; err_state = 1; end
                else begin
                    log_q.push_back('{dph_a, dph_w, dph_sz, dph_w ? hwdata : rword, 0}); dph = 0;
                    hready <= 1; hresp <= 0;
                end
            end
            if (htrans[1] && hready && !dph) begin                // address accepted
                check(htrans == 2'b10 && hburst == 3'b000 && hsize[2] == 0, "NONSEQ SINGLE at most a word");
                dph = 1; dph_a = haddr; dph_w = hwrite; dph_sz = hsize;
                dph_err = hwrite ? force_werr : force_rerr;
                waits_left = $urandom_range(3, 0);
                rword = $urandom(); hrdata <= rword;
                hready <= (waits_left == 0 && !dph_err); hresp <= 0;
                if (waits_left == 0 && !dph_err) begin
                    // zero-wait data phase completes at the next edge (logged then)
                end
            end
            check(htrans == 2'b00 || htrans == 2'b10, "HTRANS other than IDLE / NONSEQ");
        end
    end
    // results and acks
    int  res_ch = -1; bit res_err; logic [2:0] res_ph; int ack_len [6];
    always @(posedge clk) if (rst_n) begin
        for (int c = 0; c < 6; c++) begin
            if (bdone[c]) begin res_ch = c; res_err = 0; end
            if (berr[c])  begin res_ch = c; res_err = 1; res_ph = eph; end
            if (ack[c]) ack_len[c]++;
        end
        if ((bdone != 0 || berr != 0) && gv) begin
            // ENG-1: the engine must not take a grant in a result cycle: checked through busy next cycle
        end
    end
    function automatic bit refused(input logic [31:0] a); return a[31:28] == 4'h0 || a[31:28] == 4'h1; endfunction
    function automatic logic [31:0] lane(input logic [31:0] w, input logic [31:0] a, input logic [1:0] s);
        case (s) 2'd0: return {24'd0, w[8*a[1:0] +: 8]}; 2'd1: return {16'd0, w[16*a[1] +: 16]}; default: return w; endcase
    endfunction
    function automatic bit mis(input logic [31:0] a, input logic [1:0] z);   // DMA-10
        return (z == 2'd1 && a[0]) || (z == 2'd2 && a[1:0] != 2'b00);
    endfunction
    task automatic beat(input int c, input logic [31:0] s, input logic [31:0] d, input logic [1:0] z, input bit rerr, input bit werr, input bit m);
        int guard = 0;
        sar[32*c +: 32] = s; dar[32*c +: 32] = d; size[2*c +: 2] = z; m2m[c] = m;
        force_rerr = rerr; force_werr = werr;
        log_q.delete(); res_ch = -1; foreach (ack_len[k]) ack_len[k] = 0;
        // the grant stays offered for the whole beat, as a combinational arbiter on stale
        // eligibility does, and is withdrawn only after the result cycle (ENG-1)
        @(negedge clk); gv = 1; gch = 3'(c);
        @(posedge clk); #0.1;
        while (res_ch < 0 && guard < 200) begin
            if (busy) check(infl == (6'd1 << c), $sformatf("DMA-9: inflight %b while ch%0d's beat runs", infl, c));
            @(posedge clk); #0.1; guard++;
        end
        gv = 0;
        check(!busy, $sformatf("ENG-1: a new beat was taken in the cycle ch%0d's result was reported", c));
        repeat (5) @(posedge clk); #0.1;
        check(res_ch == c, $sformatf("beat ch%0d: result reported for ch%0d", c, res_ch));
        // rulings DMA-10 / DMA-12 (Track A, 2026-11-01): SAR and DAR (region and alignment) are both
        // checked before any transfer: SAR -> ph1, DAR -> ph2, nothing on the bus
        check(bsz == z, $sformatf("DMA-14: beat size reported %0d, beat taken with %0d", bsz, z));
        if (refused(s) || mis(s, z)) begin
            if (refused(s)) n_r9s++; else n_mis++;
            check(res_err && res_ph == 3'd1 && log_q.size() == 0, $sformatf("R-9/DMA-10 source %08h size %0d: error ph1, no transfer (err %0d ph %0d, %0d transfers)", s, z, res_err, res_ph, log_q.size()));
        end else if (refused(d) || mis(d, z)) begin
            if (refused(d)) n_r9d_noread++; else n_mis++;
            check(res_err && res_ph == 3'd2 && log_q.size() == 0, $sformatf("R-9/DMA-10/DMA-12 destination %08h size %0d: error ph2, no read, no write (%0d transfers)", d, z, log_q.size()));
        end else if (rerr) begin
            n_rerr++;
            check(res_err && res_ph == 3'd1 && log_q.size() == 1 && !log_q[0].w && log_q[0].e, "read ERROR: ph1, no write");
        end else begin
            check(log_q.size() == 2 && !log_q[0].w && log_q[1].w, $sformatf("beat ch%0d: %0d transfers, expected read then write", c, log_q.size()));
            if (log_q.size() == 2) begin
                check(log_q[0].a == s && log_q[1].a == d && log_q[0].sz == {1'b0, z} && log_q[1].sz == {1'b0, z},
                      $sformatf("beat ch%0d: read %08h write %08h size %0d/%0d (expected %08h %08h %0d)", c, log_q[0].a, log_q[1].a, log_q[0].sz, log_q[1].sz, s, d, z));
                check(lane(log_q[1].d, d, z) == lane(log_q[0].d, s, z),
                      $sformatf("beat ch%0d: wrote lane %08h, read lane %08h", c, lane(log_q[1].d, d, z), lane(log_q[0].d, s, z)));
                if (werr) begin n_werr++; check(res_err && res_ph == 3'd2 && ack_len[c] == 0, "write ERROR: ph2, no ack"); end
                else begin
                    n_ok++; if (m) n_m2m++;
                    check(!res_err && ack_len[c] == (m ? 0 : 2), $sformatf("beat ch%0d done (M2M %0d): ack high %0d hclk, expected %0d (DMA-15)", c, m, ack_len[c], m ? 0 : 2));
                end
            end
        end
        for (int k = 0; k < 6; k++) if (k != c) check(ack_len[k] == 0, "ack on another channel");
    endtask
    initial begin
        repeat (3) @(posedge clk); #0.1 rst_n = 1;
        for (int i = 0; i < 6000; i++) begin
            automatic int c = $urandom_range(5, 0);
            automatic logic [1:0] z = 2'($urandom_range(2, 0));
            automatic logic [31:0] s = {4'h2, 28'($urandom())}, d = {4'h3, 28'($urandom())};
            if (z == 1) begin s[0] = 0; d[0] = 0; end
            if (z == 2) begin s[1:0] = 0; d[1:0] = 0; end
            if ($urandom_range(49, 0) == 0) s[31:28] = $urandom_range(1, 0);        // R-9 source
            if ($urandom_range(49, 0) == 0) d[31:28] = $urandom_range(1, 0);        // R-9 destination
            if (z != 0 && $urandom_range(39, 0) == 0) begin if ($urandom_range(1, 0)) s[0] = 1; else d[z - 1] = 1; end   // DMA-10
            beat(c, s, d, z, $urandom_range(19, 0) == 0, $urandom_range(19, 0) == 0, $urandom_range(2, 0) == 0);
        end
        $display("tb_dma_engine_unit: checks=%0d FAIL=%0d (ok %0d of which M2M %0d, read errors %0d, write errors %0d, R-9 source %0d, R-9 destination %0d, misaligned %0d)",
                 checks, fails, n_ok, n_m2m, n_rerr, n_werr, n_r9s, n_r9d_noread, n_mis);
        $display("RESULT: %s", (fails == 0 && n_ok > 1000 && n_m2m > 200 && n_rerr > 50 && n_werr > 50 && n_r9s > 20 && n_r9d_noread > 20 && n_mis > 20) ? "PASSED" : "FAILED");
        $finish;
    end
endmodule
