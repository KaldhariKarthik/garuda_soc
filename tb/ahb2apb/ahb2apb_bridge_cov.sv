`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 8 : functional coverage of the AHB-to-APB bridge
// ahb2apb_bridge_cov.sv
//
// Written from the spec's features (GARUDA-AHB2APB-SPEC-001 sections 7 and 9;
// plan rows in tb/ahb2apb/GARUDA_AHB2APB_vplan.csv), not from the code: each
// coverpoint is a question the spec asks, each cross is a combination the spec
// says must work. Bound to ahb2apb_bridge, so it samples in the block bench and
// in every chip run. One sample per finished access, at its response.
//
// Not for synthesis, not under Icarus or Verilator (covergroups).
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
`ifndef VERILATOR
module ahb2apb_bridge_cov #(
    parameter [15:0] WINDOW_MASK = 16'h0FFE,
    parameter [23:0] APB_DIV     = 24'h0,
    parameter integer TIMEOUT    = 16
)(
    input wire        hclk_i, hreset_n_i, pclk_i, preset_n_i,
    input wire        hwrite_i,
    input wire [2:0]  hsize_i,
    input wire [31:0] haddr_i,
    input wire        hreadyout_o, hresp_o,
    input wire [2:0]  hstate,
    input wire        prst_ok_q, win_ok, word_ok, xfer, apb_err,
    input wire [3:0]  win_cap,
    input wire        write_cap,
    input wire [1:0]  pstate,
    input wire [2:0]  div_cnt,
    input wire [4:0]  to_cnt,
    input wire [11:0] pready_i, psel_o
);
    localparam [2:0] H_IDLE = 3'd0, H_CAPT = 3'd1, H_WAIT = 3'd2, H_OK = 3'd3, H_ERR1 = 3'd4, H_ERR2 = 3'd5;
    localparam [1:0] P_ACCESS = 2'd2;

    // what the access that is finishing was
    typedef enum {OK, ERR_ABSENT, ERR_SIZE, ERR_SLAVE, ERR_TIMEOUT} outcome_e;
    typedef enum {FROM_IDLE, FROM_OK, FROM_ERR} prev_e;

    // ---- at the address phase: what was asked, from which state it was accepted
    reg [3:0] a_win; reg a_wr; reg [2:0] a_size; prev_e a_prev; reg a_inreset;
    reg [2:0] hstate_d;
    wire accept = xfer && (hstate == H_IDLE || hstate == H_OK || hstate == H_ERR2) &&
                  !(hstate == H_ERR2 && !prst_ok_q);
    always @(posedge hclk_i) if (hreset_n_i) begin
        if (accept) begin
            a_win <= haddr_i[15:12]; a_wr <= hwrite_i; a_size <= hsize_i; a_inreset <= !prst_ok_q;
            a_prev <= (hstate == H_IDLE) ? FROM_IDLE : (hstate == H_OK) ? FROM_OK : FROM_ERR;
        end
        hstate_d <= hstate;
    end

    // ---- on the APB side: wait states of the slave, and whether the access timed out
    integer waits = 0; reg timed_out = 0; reg [1:0] a_div;
    always @(posedge pclk_i) if (preset_n_i) begin
        if (pstate == P_ACCESS && div_cnt == 0) begin
            if (!(|(pready_i & psel_o))) begin
                if (waits < 31) waits = waits + 1;
                if (to_cnt == TIMEOUT - 1) timed_out = 1;
            end
        end
    end

    outcome_e outcome; reg sample_now;
    always @(posedge hclk_i) begin
        sample_now = 1'b0;
        if (hreset_n_i && hstate != hstate_d) begin
            if (hstate == H_OK)  begin outcome = OK; sample_now = 1; end
            if (hstate == H_ERR1) begin
                sample_now = 1;
                if (hstate_d == H_WAIT) outcome = timed_out ? ERR_TIMEOUT : ERR_SLAVE;
                else outcome = !WINDOW_MASK[a_win] ? ERR_ABSENT : ERR_SIZE;
            end
        end
        if (sample_now) begin
            a_div = (a_win < 12) ? APB_DIV[2*a_win +: 2] : 2'b00;
            cg_i.sample();
            waits = 0; timed_out = 0;
        end
    end

    covergroup cg_access;
        option.per_instance = 1;
        option.name = "bridge_access";
        cp_window: coverpoint a_win {
            bins w[]    = {[1:11]};
            bins w0     = {0};          // the SPI slave window: absent unless the mask has it
            bins beyond = {[12:15]};
        }
        cp_dir: coverpoint a_wr { bins read = {0}; bins write = {1}; }
        cp_size: coverpoint a_size { bins byte_ = {0}; bins half = {1}; bins word = {2}; bins wider = {[3:7]}; }
        cp_outcome: coverpoint outcome {
            bins ok = {OK}; bins absent = {ERR_ABSENT}; bins subword = {ERR_SIZE};
            bins slave_error = {ERR_SLAVE}; bins timeout = {ERR_TIMEOUT};
        }
        cp_divider: coverpoint a_div { bins none = {0}; bins div2 = {1}; bins div4 = {2}; bins div8 = {3}; }
        cp_slave_waits: coverpoint waits {
            bins none = {0}; bins one = {1}; bins few = {[2:4]}; bins many = {[5:14]}; bins limit = {[15:31]};
        }
        cp_arrival: coverpoint a_prev {
            bins after_idle = {FROM_IDLE}; bins back_to_back = {FROM_OK}; bins after_error = {FROM_ERR};
        }
        cp_in_reset: coverpoint a_inreset { bins normal = {0}; bins during_apb_reset = {1}; }

        // every window works for both directions, with the answer OKAY
        x_win_dir_ok: cross cp_window, cp_dir, cp_outcome {
            ignore_bins not_ok = !binsof(cp_outcome.ok);
            ignore_bins unmapped = binsof(cp_window.w0) || binsof(cp_window.beyond);
        }
        // every kind of error, for read and write
        x_err_dir: cross cp_outcome, cp_dir {
            ignore_bins ok = binsof(cp_outcome.ok);
        }
        // the divider and the slave's waits together: the timeout budget starts after the divider
        x_div_waits: cross cp_divider, cp_slave_waits {
            ignore_bins none_w_big = binsof(cp_divider) && binsof(cp_slave_waits.limit);
        }
        // back-to-back and after-error arrivals with each outcome
        x_arrival_outcome: cross cp_arrival, cp_outcome;
        // sub-word accesses on a window that exists, on one that does not
        x_size_window: cross cp_size, cp_window {
            ignore_bins word_ = binsof(cp_size.word);
        }
    endgroup

    cg_access cg_i;
    initial begin
        a_win = 0; a_wr = 0; a_size = 0; a_prev = FROM_IDLE; a_inreset = 0; a_div = 0; outcome = OK;
        cg_i = new();
    end
endmodule

bind ahb2apb_bridge ahb2apb_bridge_cov #(
    .WINDOW_MASK(WINDOW_MASK), .APB_DIV(APB_DIV), .TIMEOUT(TIMEOUT)
) u_bridge_cov (
    .hclk_i(hclk_i), .hreset_n_i(hreset_n_i), .pclk_i(pclk_i), .preset_n_i(preset_n_i),
    .hwrite_i(hwrite_i), .hsize_i(hsize_i), .haddr_i(haddr_i),
    .hreadyout_o(hreadyout_o), .hresp_o(hresp_o),
    .hstate(hstate), .prst_ok_q(prst_ok_q), .win_ok(win_ok), .word_ok(word_ok), .xfer(xfer),
    .apb_err(apb_err), .win_cap(win_cap), .write_cap(write_cap),
    .pstate(u_fsm.state), .div_cnt(u_fsm.div_cnt), .to_cnt(u_fsm.to_cnt),
    .pready_i(pready_i), .psel_o(psel_o));
`endif
`endif
`endif
