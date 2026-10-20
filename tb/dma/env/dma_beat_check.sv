`timescale 1ns/1ps
// =============================================================================
// dma_beat_check.sv -- the "check made from pins and registers alone" of Karthik's
// recipe R4 (Track A, DMA plan D4). It sees only the APB and AHB pins of dma_top:
// no reference model, no internal signal, no class code. Independent of
// dma_env_pkg::dma_model, so a misreading shared by the model and the RTL would
// still show here.
//
// From the APB writes it learns each channel's SAR, DAR, CNT and CR (SIZE, SINC,
// DINC); a CR write with EN = 1 arms an idle channel. On
// the bus, every beat must be: a read at the next source address of an armed
// channel, then a write at that channel's next destination address with the same
// HSIZE, whose byte lanes carry the read's lanes; no channel moves more than CNT
// beats, and nothing moves after a beat answered ERROR. R-9: the regions 0x0xxx_xxxx
// and 0x1xxx_xxxx are refused: a channel whose next source is there fails without a
// transfer; one whose next destination is there ends without its write (today's RTL
// reads the source first, DMA-10; after that fix no read either); nothing is ever
// written there. Channels are told apart by address (the benches give each channel
// its own windows and register).
// =============================================================================
module dma_beat_check (
    input wire        hclk, rst_n, pclk,
    input wire        psel, penable, pwrite,
    input wire [11:0] paddr,
    input wire [31:0] pwdata,
    input wire [31:0] haddr, hwdata, hrdata,
    input wire [1:0]  htrans,
    input wire        hwrite, hready, hresp,
    input wire [2:0]  hsize
);
    logic [31:0] sar [6], dar [6], nsar [6], ndar [6];
    logic [15:0] cnt [6], cnt_arm [6];   // CNT register, and CNT when the channel was armed
    logic [1:0]  size [6];
    logic        sinc [6], dinc [6], armed [6];
    int          done [6];
    int          beats = 0, violations = 0;

    function automatic void viol(string s);
        violations++;
        if (violations <= 20) $display("[FAIL] [BEATCHK] %s (t=%0t)", s, $time);
    endfunction

    // ---- APB: what software programmed (sampled at the end of each access) -------------
    always @(posedge pclk) if (rst_n && psel && penable && pwrite && paddr < 12'h0C0) begin
        automatic int n = paddr[7:5];
        case (paddr[4:2])
            3'd0: begin
                // an arm only if the channel is idle as far as the pins tell (never armed,
                // finished, failed or stopped): a CR write with EN = 1 to a running channel
                // only rewrites its fields (F34)
                if (pwdata[0] && !armed[n]) begin              // arm: the transfer starts here
                    armed[n] = 1; done[n] = 0; nsar[n] = sar[n]; ndar[n] = dar[n]; cnt_arm[n] = cnt[n];
                    if (cnt[n] == 0) armed[n] = 0;            // zero length: completes at once
                    if (r9(sar[n])) armed[n] = 0;             // R-9: refused before any transfer
                end else if (!pwdata[0]) armed[n] = 0;        // a stop: an in-flight beat may still land
                if (pwdata[6:5] != 2'b11) size[n] = pwdata[6:5];
                sinc[n] = pwdata[3]; dinc[n] = pwdata[4];
            end
            3'd1: sar[n] = pwdata;
            3'd2: dar[n] = pwdata;
            3'd3: cnt[n] = pwdata[15:0];
            default: ;
        endcase
    end

    function automatic bit r9(input logic [31:0] a); return a[31:29] == 3'b000; endfunction

    function automatic int owner(input logic [31:0] a, input bit is_write);
        for (int n = 0; n < 6; n++) if (is_write ? (a == ndar[n]) : (a == nsar[n])) return n;
        return -1;
    endfunction
    function automatic logic [31:0] lane(input logic [31:0] w, input logic [31:0] a, input logic [1:0] s);
        case (s) 2'd0: return {24'd0, w[8*a[1:0] +: 8]}; 2'd1: return {16'd0, w[16*a[1] +: 16]}; default: return w; endcase
    endfunction

    // ---- AHB: every beat ------------------------------------------------------------------
    logic        dph, dph_wr;                // a data phase is pending
    logic [31:0] dph_addr, rd_addr, rd_word;
    int          cur;                        // the channel of the beat in progress (-1 none)
    logic        rd_done;
    always @(posedge hclk or negedge rst_n) begin
        if (!rst_n) begin
            dph <= 0; cur = -1; rd_done = 0;
            for (int n = 0; n < 6; n++) begin armed[n] = 0; done[n] = 0; end
        end else begin
            // the pending data phase ends at this edge
            if (dph && hready) begin
                dph <= 0;
                if (hresp) begin                              // ERROR: this channel's transfer ends
                    if (cur >= 0) armed[cur] = 0;
                    cur = -1; rd_done = 0;
                end else if (!dph_wr) begin
                    rd_word = hrdata; rd_done = 1;
                    if (cur >= 0 && r9(ndar[cur])) begin       // R-9: the write is refused, the transfer ends
                        armed[cur] = 0; cur = -1; rd_done = 0;
                    end
                end else begin
                    if (cur >= 0 && lane(hwdata, dph_addr, size[cur]) != lane(rd_word, rd_addr, size[cur]))
                        viol($sformatf("ch%0d beat %0d: wrote %08h, read %08h", cur, done[cur],
                                       lane(hwdata, dph_addr, size[cur]), lane(rd_word, rd_addr, size[cur])));
                    if (cur >= 0) begin
                        done[cur]++; beats++;
                        if (done[cur] >= cnt_arm[cur]) armed[cur] = 0;   // finished
                        if (sinc[cur]) nsar[cur] = nsar[cur] + (32'd1 << size[cur]);
                        if (dinc[cur]) ndar[cur] = ndar[cur] + (32'd1 << size[cur]);
                    end
                    cur = -1; rd_done = 0;
                end
            end
            // an address phase is accepted at this edge
            if (hready && htrans[1]) begin
                dph <= 1; dph_wr <= hwrite; dph_addr <= haddr;
                if (!hwrite) begin
                    automatic int n = owner(haddr, 0);
                    if (cur >= 0) viol($sformatf("read at %08h while the beat of ch%0d has no write yet", haddr, cur));
                    if (n < 0) viol($sformatf("read at %08h is no armed channel's next source address", haddr));
                    else begin
                        if (done[n] >= cnt_arm[n]) viol($sformatf("ch%0d: a beat beyond CNT = %0d", n, cnt_arm[n]));
                        if (hsize != {1'b0, size[n]}) viol($sformatf("ch%0d: read HSIZE %0d, SIZE %0d", n, hsize, size[n]));
                    end
                    cur = n; rd_addr = haddr; rd_done = 0;
                end else begin
                    if (r9(haddr)) viol($sformatf("write at %08h, inside the R-9 refused regions", haddr));
                    if (cur < 0 || !rd_done) viol($sformatf("write at %08h with no completed read before it", haddr));
                    else begin
                        if (haddr != ndar[cur]) viol($sformatf("ch%0d: write at %08h, next destination %08h", cur, haddr, ndar[cur]));
                        if (hsize != {1'b0, size[cur]}) viol($sformatf("ch%0d: write HSIZE %0d, SIZE %0d", cur, hsize, size[cur]));
                    end
                end
            end
        end
    end
endmodule
