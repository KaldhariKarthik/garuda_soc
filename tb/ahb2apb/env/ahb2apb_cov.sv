`timescale 1ns/1ps
// =============================================================================
// ahb2apb_cov.sv -- functional coverage of the AHB-to-APB bridge (Track A bus plan
// B2). Bound into ahb2apb_bridge by tb/ahb2apb/env/filelist_apb_env.f, so it samples
// the real ports. Groups follow tb/ahb2apb/GARUDA_AHB2APB_vplan.csv (R-1..R-8 and the
// Track A additions). Module covergroups with an explicit sample() (TOOL-22/23).
// =============================================================================
module ahb2apb_cov #(
    parameter [15:0] WINDOW_MASK = 16'h0FFE,
    parameter [23:0] APB_DIV     = 24'h0
)(
    input wire        hclk_i, hreset_n_i, pclk_i, preset_n_i, pclk_phase_i,
    input wire        hsel_i,
    input wire [31:0] haddr_i,
    input wire [1:0]  htrans_i,
    input wire        hwrite_i,
    input wire [2:0]  hsize_i,
    input wire        hready_i,
    input wire        hreadyout_o, hresp_o,
    input wire [11:0] psel_o,
    input wire        penable_o,
    input wire [11:0] pready_i, pslverr_i
);
    wire acc   = hsel_i && htrans_i[1] && hready_i;
    wire [3:0] wn = haddr_i[15:12];
    wire win_p = WINDOW_MASK[wn];
    // 0 legal, 1 sub-word, 2 absent window, 3 outside the 48 KiB aperture
    wire [1:0] kind = (haddr_i[27:16] != 0) ? 2'd3 : !win_p ? 2'd2 : (hsize_i != 3'b010) ? 2'd1 : 2'd0;

    covergroup cg_win with function sample(bit [3:0] w, bit wr);
        cp_window: coverpoint w { bins present[] = {[0:11]}; bins absent[] = {[12:15]}; }
        cp_write:  coverpoint wr;
        x_win_rw:  cross cp_window, cp_write;
    endgroup
    covergroup cg_reject with function sample(bit [1:0] k, bit [2:0] sz, bit [1:0] a10);
        cp_kind: coverpoint k { bins legal = {0}; bins subword = {1}; bins absent = {2}; bins aperture = {3}; }
        // the legal size/offset pairs of a sub-word request (explicit bins: the open
        // simulator does not honour ignore_bins inside a cross)
        cp_subword: coverpoint {sz, a10} { bins byte0 = {5'b000_00}; bins byte1 = {5'b000_01}; bins byte2 = {5'b000_10};
                                           bins byte3 = {5'b000_11}; bins half0 = {5'b001_00}; bins half2 = {5'b001_10};
                                           bins word  = {5'b010_00}; }
    endgroup
    covergroup cg_end with function sample(bit [1:0] how, int unsigned samples);   // 0 OKAY 1 PSLVERR 2 timeout
        cp_end:     coverpoint how { bins okay = {0}; bins slverr = {1}; bins timeout = {2}; }
    endgroup
    // PREADY on the 1st, 2nd, 4th, 5th-14th, 15th and 16th (last allowed) sample
    covergroup cg_ready_at with function sample(int unsigned samples);
        cp_samples: coverpoint samples { bins first = {1}; bins second = {2}; bins four = {4}; bins mid = {[5:14]};
                                         bins before_limit = {15}; bins at_limit = {16}; }
    endgroup
    covergroup cg_div with function sample(bit [1:0] d, bit early);
        // each divider, and PREADY already high during the extension (no extension at /1)
        cp_div_early: coverpoint {d, early} { bins div1 = {3'b00_0}; bins div2 = {3'b01_0}; bins div2_early = {3'b01_1};
                                              bins div4 = {3'b10_0}; bins div4_early = {3'b10_1};
                                              bins div8 = {3'b11_0}; bins div8_early = {3'b11_1}; }
    endgroup
    covergroup cg_b2b with function sample(bit pw, bit cw, bit same);
        cp_prev: coverpoint pw; cp_cur: coverpoint cw; cp_same: coverpoint same;
        x_b2b: cross cp_prev, cp_cur, cp_same;
    endgroup
    covergroup cg_phase with function sample(bit ph);
        cp_req_phase: coverpoint ph;          // AHB acceptance on either pclk phase
    endgroup
    covergroup cg_rst with function sample(bit [2:0] where);
        cp_reset_point: coverpoint where { bins idle = {0}; bins setup = {1}; bins access = {2}; bins wait_ahb = {3};
                                           bins preset_only = {4}; bins gap_access = {5}; }
    endgroup

    cg_win u_cg_win = new(); cg_reject u_cg_reject = new(); cg_end u_cg_end = new(); cg_ready_at u_cg_ready_at = new();
    cg_div u_cg_div = new(); cg_b2b u_cg_b2b = new(); cg_phase u_cg_phase = new(); cg_rst u_cg_rst = new();

    // ---- AHB side ---------------------------------------------------------------
    reg last_v = 1'b0, last_w = 1'b0; reg [3:0] last_win = 4'd0; reg dp = 1'b0, dp_legal = 1'b0;
    always @(posedge hclk_i) if (hreset_n_i) begin
        if (dp && hreadyout_o) dp <= 1'b0;
        if (acc) begin
            u_cg_win.sample(wn, hwrite_i);
            u_cg_reject.sample(kind, hsize_i, haddr_i[1:0]);
            u_cg_phase.sample(pclk_phase_i);
            if (dp && hreadyout_o && dp_legal && kind == 0) u_cg_b2b.sample(last_w, hwrite_i, last_win == wn);
            dp <= 1'b1; dp_legal <= (kind == 0);
            if (kind == 0) begin last_v <= 1'b1; last_w <= hwrite_i; last_win <= wn; end
        end
        if (acc && !preset_n_i) u_cg_rst.sample(3'd5);
    end
    // ---- APB side ---------------------------------------------------------------
    int unsigned acc_n = 0; bit early = 0; reg [3:0] w = 0; bit plive = 0;
    function automatic [3:0] widx(input [11:0] p);
        widx = 0; for (int i = 0; i < 12; i++) if (p[i]) widx = i[3:0];
    endfunction
    wire [3:0] wi = widx(psel_o);
    wire [1:0] dsel = (wi < 12) ? APB_DIV[2*wi +: 2] : 2'b00;
    wire [3:0] ext = (4'd1 << dsel) - 4'd1;
    always @(posedge pclk_i) if (preset_n_i) begin
        plive <= 1'b1;
        if (penable_o && |psel_o) begin
            if (acc_n < ext && pready_i[wi]) early = 1;
            if (acc_n >= ext && pready_i[wi]) begin
                u_cg_end.sample(pslverr_i[wi] ? 2'd1 : 2'd0, acc_n - ext + 1);
                u_cg_ready_at.sample(acc_n - ext + 1);
                u_cg_div.sample(dsel, early);
            end else if (acc_n == ext + 15) begin
                u_cg_end.sample(2'd2, 16);
                u_cg_div.sample(dsel, early);
            end
            acc_n++;
        end else begin acc_n = 0; early = 0; end
    end
    // reset points: what the bridge was doing when a reset arrived
    reg seen_setup = 0, seen_access = 0;
    always @(negedge hreset_n_i) if (plive)
        u_cg_rst.sample((|psel_o && !penable_o) ? 3'd1 : (|psel_o && penable_o) ? 3'd2 : (!hreadyout_o) ? 3'd3 : 3'd0);
    always @(negedge preset_n_i) if (plive && hreset_n_i) u_cg_rst.sample(3'd4);
endmodule

bind ahb2apb_bridge ahb2apb_cov #(.WINDOW_MASK(WINDOW_MASK), .APB_DIV(APB_DIV)) u_apb_cov (
    .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .pclk_i(pclk_i), .preset_n_i(preset_n_i), .pclk_phase_i(pclk_phase_i),
    .hsel_i(hsel_i), .haddr_i(haddr_i), .htrans_i(htrans_i), .hwrite_i(hwrite_i), .hsize_i(hsize_i),
    .hready_i(hready_i), .hreadyout_o(hreadyout_o), .hresp_o(hresp_o),
    .psel_o(psel_o), .penable_o(penable_o), .pready_i(pready_i), .pslverr_i(pslverr_i));
