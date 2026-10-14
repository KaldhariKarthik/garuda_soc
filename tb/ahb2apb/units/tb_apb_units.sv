`timescale 1ns/1ps
// =============================================================================
// tb_apb_units.sv -- the bridge's sub-modules on their own (Track A bus plan B2), each
// against a reference written from GARUDA-AHB2APB-SPEC-001, each with a negative
// control in tb/ahb2apb/run/units.toml (a planted defect that must fail it).
//   +UNIT=fsm      ahb2apb_apb_fsm: one request toggle -> SETUP (one-hot PSEL of the
//                  window, no PENABLE) -> ACCESS: APB_DIV extension, then PREADY
//                  sampled; ends on the first sampled PREADY or after 16 samples
//                  (timeout); exactly one acknowledge toggle; ERROR = PSLVERR or
//                  timeout; read data = the selected PRDATA (0 on a timeout); one idle
//                  cycle after (P_DONE). Built with APB_DIV /1 /2 /4 /8 across windows.
//   +UNIT=fabric   ahb2apb_fabric: the return is the selected window's; nothing
//                  selected returns 0 / not ready / no error.
// =============================================================================
module tb_apb_units;
    logic clk = 1'b0, rst_n;
    initial #0 rst_n = 1'b0;
    always #2 clk = ~clk;
    int checks = 0, fails = 0, cycles = 3000;
    string unit;
    task automatic check(input bit c, input string what);
        checks++;
        if (!c) begin fails++; if (fails <= 20) $display("[FAIL] %s (t=%0t)", what, $time); end
    endtask

    // ---------------- fsm ----------------
    localparam [23:0] DIV = 24'hE4E4E4;           // windows /1 /2 /4 /8 in turn
    logic req = 0; logic [3:0] win = 0; logic [11:0] addr = 0; logic wr = 0; logic [31:0] wd = 0;
    logic [31:0] prd = 0; logic prdy = 0, perr = 0;
    wire ack, err; wire [31:0] rdata; wire [11:0] psel; wire pen, pwr; wire [11:0] paddr; wire [31:0] pwd;
    ahb2apb_apb_fsm #(.APB_DIV(DIV), .TIMEOUT(16)) u_fsm (.pclk_i(clk), .preset_n_i(rst_n), .req_tgl_i(req),
        .win_i(win), .addr_i(addr), .write_i(wr), .wdata_i(wd), .ack_tgl_o(ack), .err_o(err), .rdata_o(rdata),
        .psel_o(psel), .penable_o(pen), .pwrite_o(pwr), .paddr_o(paddr), .pwdata_o(pwd),
        .prdata_sel_i(prd), .pready_sel_i(prdy), .pslverr_sel_i(perr));

    // ---------------- fabric ----------------
    logic [11:0] f_sel; logic [12*32-1:0] f_rd; logic [11:0] f_rdy, f_err;
    wire [31:0] f_out; wire f_ready, f_slverr;
    ahb2apb_fabric u_fab (.psel_i(f_sel), .prdata_i(f_rd), .pready_i(f_rdy), .pslverr_i(f_err),
                          .prdata_o(f_out), .pready_o(f_ready), .pslverr_o(f_slverr));

    initial begin
        if (!$value$plusargs("UNIT=%s", unit)) unit = "fsm";
        void'($value$plusargs("CYCLES=%d", cycles));
        $display("=== tb_apb_units +UNIT=%s ===", unit);
        f_sel = 0; f_rd = 0; f_rdy = 0; f_err = 0;
        repeat (2) @(posedge clk); @(negedge clk); rst_n = 1'b1;
        case (unit)
        "fsm": begin
            for (int k = 0; k < cycles / 20; k++) begin
                int ext, samp, ready_at, n_ack0;
                bit to, exp_err; logic [31:0] exp_rd;
                win = $urandom_range(11); addr = $urandom; wr = $urandom_range(1); wd = $urandom;
                ext = (1 << DIV[2*win +: 2]) - 1;
                ready_at = ($urandom_range(7) == 0) ? 99 : $urandom_range(17);   // sample at which PREADY rises (99: never)
                n_ack0 = ack;
                @(negedge clk); req = ~req;                                       // one request
                @(negedge clk);
                check(psel == 12'd1 << win && !pen, $sformatf("[N-7.11] SETUP: PSEL %03h for window %0d, PENABLE %0d", psel, win, pen));
                check(paddr == addr && pwr == wr && (!wr || pwd == wd), "[R-1] address / direction / write data from the capture");
                @(negedge clk);                                                   // now in ACCESS cycle 0
                check(pen && psel == 12'd1 << win, "[a_apb_setup] SETUP lasts one cycle, then ACCESS on the same window");
                samp = 0; to = 0;
                for (int c = 0; ; c++) begin                                       // ACCESS cycles
                    automatic bit sampling = (c >= ext);   // automatic: re-evaluated every iteration
                    prdy = sampling ? (samp + 1 >= ready_at) : $urandom_range(1);  // noise during the extension
                    perr = $urandom_range(3) == 0; prd = $urandom;
                    @(negedge clk);
                    // still in ACCESS? (registered outputs updated at the posedge just passed)
                    if (sampling) begin
                        samp++;
                        if (prdy) begin exp_err = perr; exp_rd = prd; break; end
                        if (samp == 16) begin to = 1; exp_err = 1; exp_rd = 0; break; end
                    end
                    check(pen && psel == 12'd1 << win, $sformatf("[R-5] ACCESS held: cycle %0d of extension %0d, sample %0d", c, ext, samp));
                end
                check(!pen && psel == 0, $sformatf("[N-7.15] ACCESS ended (%s after %0d sample(s); window %0d ext %0d ready_at %0d; fsm state %0d div %0d to %0d)",
                      to ? "timeout" : "PREADY", samp, win, ext, ready_at, u_fsm.state, u_fsm.div_cnt, u_fsm.to_cnt));
                check(ack != n_ack0, "[BRG-1] exactly one acknowledge toggle");
                check(err == exp_err && (exp_err && to ? rdata == 0 : wr || rdata == exp_rd),
                      $sformatf("[N-7.20] result: err %0d (want %0d), rdata %08h (want %08h)", err, exp_err, rdata, exp_rd));
                prdy = 0;
                @(negedge clk);
                check(!pen && psel == 0 && ack != n_ack0, "[P_DONE] one idle cycle, no second acknowledge");
            end
        end
        "fabric": begin
            for (int k = 0; k < cycles; k++) begin
                int s;
                f_sel = ($urandom_range(5) == 0) ? 12'd0 : 12'd1 << $urandom_range(11);
                foreach (f_rd[b]) f_rd[b] = $urandom_range(1);
                f_rdy = $urandom; f_err = $urandom;
                #1;
                s = -1; for (int i = 0; i < 12; i++) if (f_sel[i]) s = i;
                if (s < 0) check(f_out == 0 && !f_ready && !f_slverr, "[fabric] nothing selected: 0 / not ready / no error");
                else check(f_out == f_rd[32*s +: 32] && f_ready == f_rdy[s] && f_slverr == f_err[s],
                           $sformatf("[a_resp_from_active_window] window %0d return", s));
            end
        end
        default: begin fails++; $display("[FAIL] unknown +UNIT=%s", unit); end
        endcase
        $display("CHECKS: %0d  FAILS: %0d", checks, fails);
        if (fails == 0 && checks > 0) $display("RESULT: PASSED"); else $display("RESULT: FAILED");
        $finish;
    end
endmodule
