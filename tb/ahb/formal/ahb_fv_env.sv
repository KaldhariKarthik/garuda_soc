// =============================================================================
// ahb_fv_env.sv -- formal environment of ahb_interconnect (Track A bus plan B1,
// phase A2). Bound into ahb_interconnect; the properties are
// rtl/ahb/ahb_ic_props_a.sv (bound through rtl/ahb/filelist.f). Every
// master and slave input of the interconnect is a free input of the proof,
// constrained only by the protocol rules below. Register: ASSUMPTIONS.md.
//
//   FA-1 reset: hreset_n low for the first RST_CYCLES cycles, then high.
//   FA-2 AHB-Lite masters (each of the four):
//        - HTRANS is IDLE, NONSEQ or SEQ (no GARUDA master emits BUSY); IDLE in reset;
//        - a presented, not yet accepted address phase is held unchanged (address,
//          HTRANS, HWRITE, HSIZE, HBURST) until the master sees HREADY high, except
//          that after the first cycle of an ERROR the master may drop it to IDLE;
//        - HSIZE byte / half / word with an aligned address;
//        - HWDATA is held while the master's own write data phase is waited;
//        - M1 D-port, M2 SBA, M3 DMA: SINGLE, NONSEQ only;
//        - M0 I-port: reads, word, SINGLE or INCR; a SEQ continues the master's own
//          last accepted transfer at address + 4 (its INCR burst).
//   FA-4 (only with `define AHB_FV_CANCEL_ON_ERROR, the proof tasks): a master that
//        saw ERROR with HREADY low in its own data phase last cycle presents IDLE
//        now. This is the condition under which AHB-7 cannot occur; the bug-finder
//        task runs without it and must find AHB-7.
//   FA-3 AHB-Lite slaves (each of the four regions): HREADYOUT high and HRESP OKAY
//        when the slave has no data phase; in a data phase any number of wait
//        states, OKAY, or the two-cycle ERROR; HRDATA free.
// =============================================================================
`timescale 1ns/1ps
module ahb_fv_env #(
    parameter integer RST_CYCLES = 2
)(
    input wire        clk,
    input wire        hreset_n_i,
    input wire [3:0][31:0] m_addr,
    input wire [3:0][1:0]  m_trans,
    input wire [3:0]       m_wr,
    input wire [3:0][2:0]  m_size,
    input wire [3:0][2:0]  m_burst,
    input wire [3:0][31:0] m_wdata,
    input wire [3:0]       m_rdy,
    input wire [3:0]       m_err,
    input wire [3:0]       s_sel,          // hsel_isram/rom/dsram/bridge
    input wire             hready_o,
    input wire [1:0]       htrans_o,
    input wire [3:0]       s_rdy,
    input wire [3:0]       s_resp
);
    localparam [1:0] T_IDLE = 2'b00, T_BUSY = 2'b01, T_NONSEQ = 2'b10, T_SEQ = 2'b11;

    reg [2:0]       cyc = 3'd0;
    reg [3:0][31:0] addr_q;
    reg [3:0][1:0]  trans_q;
    reg [3:0]       wr_q, rdy_q, err_q;
    reg [3:0][2:0]  size_q, burst_q;
    reg [3:0][31:0] wdata_q;
    reg [3:0]       out = 4'd0;            // master m has a data phase outstanding
    reg [3:0]       outw = 4'd0;           // ... and it is a write
    reg             m0_open = 1'b0;        // M0's last accepted transfer can be continued by a SEQ
    reg [31:0]      m0_last = 32'd0;
    reg [3:0]       sdp = 4'd0;            // slave s has a data phase
    reg [3:0]       serr1 = 4'd0;          // slave s gave the first ERROR cycle last cycle

    always @(posedge clk) begin
        if (cyc != 3'd7) cyc <= cyc + 3'd1;
        addr_q <= m_addr; trans_q <= m_trans; wr_q <= m_wr; size_q <= m_size;
        burst_q <= m_burst; wdata_q <= m_wdata; rdy_q <= m_rdy; err_q <= m_err;
        if (!hreset_n_i) begin
            out <= 4'd0; outw <= 4'd0; m0_open <= 1'b0; sdp <= 4'd0; serr1 <= 4'd0;
        end else begin
            for (int m = 0; m < 4; m++) begin
                if (m_trans[m][1] && m_rdy[m]) begin out[m] <= 1'b1; outw[m] <= m_wr[m]; end
                else if (m_rdy[m])                 out[m] <= 1'b0;
            end
            if (m_trans[0][1] && m_rdy[0]) begin
                m0_open <= (m_burst[0] == 3'b001); m0_last <= m_addr[0];
            end else if (m_rdy[0] && m_trans[0] == T_IDLE) m0_open <= 1'b0;
            if (hready_o) sdp <= s_sel & {4{htrans_o[1]}};
            serr1 <= s_resp & ~s_rdy;
        end
    end

    function automatic bit aligned(input [31:0] a, input [2:0] sz);
        aligned = (sz == 3'd0) || (sz == 3'd1 && !a[0]) || (sz == 3'd2 && a[1:0] == 2'b00);
    endfunction

    always @(*) begin
        // ---- FA-1 reset
        if (cyc < RST_CYCLES) assume (!hreset_n_i);
        else                  assume (hreset_n_i);
        for (int m = 0; m < 4; m++) begin
            // ---- FA-2 masters
            assume (m_trans[m] != T_BUSY);
            if (!hreset_n_i) assume (m_trans[m] == T_IDLE);
            assume (m_size[m] <= 3'd2 && aligned(m_addr[m], m_size[m]));
            if (cyc >= RST_CYCLES && trans_q[m][1] && !rdy_q[m]) begin
                if (err_q[m] && out[m])                       // after an ERROR first cycle: hold or cancel
                    assume (m_trans[m] == T_IDLE ||
                            (m_trans[m] == trans_q[m] && m_addr[m] == addr_q[m] && m_wr[m] == wr_q[m] &&
                             m_size[m] == size_q[m] && m_burst[m] == burst_q[m]));
                else
                    assume (m_trans[m] == trans_q[m] && m_addr[m] == addr_q[m] && m_wr[m] == wr_q[m] &&
                            m_size[m] == size_q[m] && m_burst[m] == burst_q[m]);
            end
            if (cyc >= RST_CYCLES && out[m] && outw[m] && !rdy_q[m]) assume (m_wdata[m] == wdata_q[m]);
            if (m != 0) assume (m_trans[m] != T_SEQ && m_burst[m] == 3'b000);
        end
        assume (!m_wr[0] && m_size[0] == 3'd2 && (m_burst[0] == 3'b000 || m_burst[0] == 3'b001));
`ifdef AHB_FV_CANCEL_ON_ERROR
        for (int m = 0; m < 4; m++)
            if (cyc >= RST_CYCLES && out[m] && !rdy_q[m] && err_q[m]) assume (m_trans[m] == T_IDLE);
`endif
        if (m_trans[0] == T_SEQ)
            assume (m0_open && m_burst[0] == 3'b001 && m_addr[0] == m0_last + 32'd4);
        // ---- FA-3 slaves
        for (int s = 0; s < 4; s++) begin
            if (!hreset_n_i || !sdp[s]) assume (s_rdy[s] && !s_resp[s]);
            else begin
                if (s_resp[s] && s_rdy[s]) assume (serr1[s]);
                if (serr1[s])              assume (s_resp[s] && s_rdy[s]);
            end
        end
    end
endmodule

bind ahb_interconnect ahb_fv_env u_fv_env (
    .clk(hclk_i), .hreset_n_i(hreset_n_i),
    .m_addr ({m_haddr_i,  s_haddr_i,  d_haddr_i,  i_haddr_i}),
    .m_trans({m_htrans_i, s_htrans_i, d_htrans_i, i_htrans_i}),
    .m_wr   ({m_hwrite_i, s_hwrite_i, d_hwrite_i, i_hwrite_i}),
    .m_size ({m_hsize_i,  s_hsize_i,  d_hsize_i,  i_hsize_i}),
    .m_burst({m_hburst_i, s_hburst_i, d_hburst_i, i_hburst_i}),
    .m_wdata({m_hwdata_i, s_hwdata_i, d_hwdata_i, i_hwdata_i}),
    .m_rdy  ({m_hready_o, s_hready_o, d_hready_o, i_hready_o}),
    .m_err  ({m_hresp_o,  s_hresp_o,  d_hresp_o,  i_hresp_o}),
    .s_sel  ({hsel_bridge_o, hsel_dsram_o, hsel_rom_o, hsel_isram_o}),
    .hready_o(hready_o), .htrans_o(htrans_o),
    .s_rdy  ({hreadyout_bridge_i, hreadyout_dsram_i, hreadyout_rom_i, hreadyout_isram_i}),
    .s_resp ({hresp_bridge_i, hresp_dsram_i, hresp_rom_i, hresp_isram_i}));
