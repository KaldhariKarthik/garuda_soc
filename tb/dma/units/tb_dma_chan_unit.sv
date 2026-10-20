`timescale 1ns/1ps
// =============================================================================
// tb_dma_chan_unit.sv -- one dma_chan on its own (Track A wrap-up 2026-10-12).
// Reference: a cycle model written from the channel rules of GARUDA-DMA-SPEC-001
// and the rulings, all on one hclk edge (R-6):
//   CR write: MODE / SIZE value 3 refused (kept), the other fields land ([N-6.1], F02/F03)
//   EN: the hardware clear (last beat done, or a beat error) beats a software write
//       (D-2, [N-7.3], [N-7.13]); EN 0 -> 1 arms: REMAINING = CNT; an armed channel
//       with REMAINING 0 drops EN the next cycle and is COMPLETE at once
//   beat done: REMAINING - 1, COMPLETE on the last; SAR / DAR step by the SIZE when
//       SINC / DINC; beat error: ERROR + ERRPHASE, nothing steps ([N-7.15])
//   ICLR: write 1 clears COMPLETE / ERROR (+ERRPHASE), but a set in the same cycle
//       wins ([N-7.19]); CNT, SAR, DAR writes land as written (F12)
//   D-21: a successful beat consumes the request until it drops ([N-7.10], DMA-8);
//       eligible = EN && REMAINING != 0 && (M2M || (req && not consumed))
//   interrupts: COMPLETE && IE_COMP, ERROR && IE_ERR ([N-7.18])
// The bench plays the engine (a beat is taken only when eligible, one at a time, done
// or failed 1..5 cycles later; a beat in flight still lands if software stops or
// re-arms meanwhile: DMA-11 is a property of the engine + channel pair, see the
// probe) and software (random register writes, any cycle). Every output is compared
// after every edge; also checked: COMPLETE implies REMAINING = 0.
// =============================================================================
module tb_dma_chan_unit;
    logic clk = 0, rst_n = 0;
    always #2 clk = ~clk;
    logic wcr = 0, wsar = 0, wdar = 0, wcnt = 0, wiclr = 0, req = 0, bd = 0, be = 0;
    logic [31:0] wd = 0; logic [2:0] ep = 0;
    wire [31:0] cr, sar, dar, cnt, stat; wire elig, ic, ie; wire [1:0] size;
    dma_chan dut (.hclk_i(clk), .hreset_n_i(rst_n), .wr_cr_i(wcr), .wr_sar_i(wsar), .wr_dar_i(wdar),
                  .wr_cnt_i(wcnt), .wr_iclr_i(wiclr), .wdata_i(wd), .cr_o(cr), .sar_o(sar), .dar_o(dar),
                  .cnt_o(cnt), .stat_o(stat), .req_i(req), .eligible_o(elig), .size_o(size),
                  .beat_done_i(bd), .beat_err_i(be), .err_phase_i(ep), .complete_irq_o(ic), .error_irq_o(ie));
    // ---- reference state ----
    bit en, sinc, dinc, iec, iee, comp, err, taken;
    logic [1:0] mode, sz; logic [31:0] rsar, rdar; logic [15:0] rcnt, rem; logic [2:0] errph;
    task automatic ref_reset();
        en = 0; mode = 0; sinc = 0; dinc = 0; sz = 2; iec = 0; iee = 0; rsar = 0; rdar = 0;
        rcnt = 0; rem = 0; comp = 0; err = 0; errph = 0; taken = 0;
    endtask
    function automatic bit r_active(); return en && rem != 0; endfunction
    task automatic ref_edge();
        bit last = rem == 16'd1, hw = (bd && last) || be;
        bit n_en = en; logic [15:0] n_rem = rem; bit n_comp = comp, n_err = err; logic [2:0] n_eph = errph;
        logic [31:0] step = sz == 0 ? 1 : sz == 1 ? 2 : 4;
        bit o_sinc = sinc, o_dinc = dinc;                                  // the values before the edge
        if (wcr) begin
            if (wd[2:1] != 2'b11) mode = wd[2:1];
            sinc = wd[3]; dinc = wd[4];
            iec = wd[7]; iee = wd[8];
        end
        if (hw || (en && rem == 0 && !wcr)) n_en = 0;
        else if (wcr) begin n_en = wd[0]; if (wd[0] && !en) n_rem = rcnt; end
        if (wsar) rsar = wd; else if (bd && o_sinc) rsar = rsar + step;   // step, SINC, DINC of before the edge
        if (wdar) rdar = wd; else if (bd && o_dinc) rdar = rdar + step;
        if (bd) begin n_rem = rem - 1; if (last) n_comp = 1; end
        else if (wcr && wd[0] && !en && !hw) n_comp = (rcnt == 0);
        if (be) begin n_err = 1; n_eph = ep; end
        if (wiclr) begin
            if (wd[0] && !(bd && last)) n_comp = 0;
            if (wd[1] && !be) begin n_err = 0; n_eph = 0; end
        end
        if (!req) taken = 0; else if (bd) taken = 1;
        if (wcnt) rcnt = wd[15:0];
        if (wcr && wd[6:5] != 2'b11) sz = wd[6:5];
        en = n_en; rem = n_rem; comp = n_comp; err = n_err; errph = n_eph;
    endtask
    int checks = 0, fails = 0, n_done = 0, n_err = 0, n_comp = 0;
    task automatic compare(input string when);
        logic [31:0] want_cr = {23'd0, iee, iec, sz, dinc, sinc, mode, en};
        logic [31:0] want_st = {10'd0, errph, err, comp, r_active(), rem};
        bit want_el = r_active() && (mode == 2'd2 || (req && !taken));
        checks++;
        if (cr !== want_cr || sar !== rsar || dar !== rdar || cnt !== {16'd0, rcnt} || stat !== want_st ||
            elig !== want_el || size !== sz || ic !== (comp && iec) || ie !== (err && iee) || (stat[17] && stat[15:0] != 0)) begin
            fails++;
            if (fails <= 10) $display("[FAIL] %s: cr %08h/%08h sar %08h/%08h dar %08h/%08h cnt %08h/%04h stat %08h/%08h elig %0d/%0d irq %0d%0d/%0d%0d",
                                      when, cr, want_cr, sar, rsar, dar, rdar, cnt, rcnt, stat, want_st, elig, want_el, ic, ie, comp && iec, err && iee);
        end
    endtask
    // the bench as engine and software
    int beat_left = -1; bit beat_fail;
    initial begin
        ref_reset();
        repeat (3) @(posedge clk); #1 rst_n = 1; #1 compare("after reset");
        for (int cyc = 0; cyc < 200000; cyc++) begin
            // software: at most one register strobe per cycle
            {wcr, wsar, wdar, wcnt, wiclr} = 0; wd = $urandom();
            if ($urandom_range(99, 0) < 12) begin
                case ($urandom_range(9, 0))
                    0, 1, 2: begin wcr = 1; wd[0] = $urandom_range(3, 0) != 0; end
                    3: wsar = 1;
                    4: wdar = 1;
                    5, 6: begin wcnt = 1; wd[15:0] = $urandom_range(3, 0) == 0 ? 16'($urandom()) : 16'($urandom_range(6, 0)); end
                    default: begin wiclr = 1; wd[31:2] = 0; end
                endcase
            end
            // peripheral request (D-21-like: rises, holds, drops after a beat or at random)
            if ($urandom_range(99, 0) < 15) req = !req;
            // engine: report the beat in flight, or take a new one when eligible
            bd = 0; be = 0; ep = 0;
            if (beat_left == 0) begin
                if (beat_fail) begin be = 1; ep = $urandom_range(1, 0) ? 3'd1 : 3'd2; n_err++; end
                else begin bd = 1; n_done++; end
                beat_left = -1;
            end else if (beat_left > 0) beat_left--;
            else if (elig && $urandom_range(3, 0) != 0) begin beat_left = $urandom_range(4, 0); beat_fail = $urandom_range(99, 0) < 8; end
            @(posedge clk);
            ref_edge();
            n_comp += comp;
            #1 compare($sformatf("cycle %0d", cyc));
        end
        $display("tb_dma_chan_unit: checks=%0d FAIL=%0d (beats done %0d, failed %0d, cycles COMPLETE %0d)", checks, fails, n_done, n_err, n_comp);
        $display("RESULT: %s", (fails == 0 && n_done > 1000 && n_err > 50) ? "PASSED" : "FAILED");
        $finish;
    end
endmodule
