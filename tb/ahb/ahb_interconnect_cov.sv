`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 6 : functional coverage of the AHB-Lite interconnect
// ahb_interconnect_cov.sv
//
// From GARUDA-AHB-SPEC-001 sections 7.2 to 7.7, not from the code. Bound to
// ahb_interconnect, so it samples in the block bench and in every chip run.
//   cg_addr  one sample per accepted address phase: who, where, what, against whom
//   cg_resp  one sample per finished data phase: who, from where, how it ended
// Not for synthesis, not under Icarus or Verilator.
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
`ifndef VERILATOR
module ahb_interconnect_cov (
    input wire        hclk_i, hreset_n_i,
    input wire [1:0]  i_htrans_i, d_htrans_i, s_htrans_i, m_htrans_i,
    input wire [31:0] haddr_o,
    input wire [1:0]  htrans_o,
    input wire [2:0]  hsize_o, hburst_o,
    input wire        hwrite_o, hready_o,
    input wire [1:0]  grant, dph_master, htrans_sel,
    input wire        seq_break, dph_valid, hresp_shared,
    input wire [4:0]  hsel,
    input wire        hold_i, hold_d, hold_s, hold_m
);
    // ---- address phase ------------------------------------------------------
    wire [3:0] reqs = {m_htrans_i[1], s_htrans_i[1], d_htrans_i[1], i_htrans_i[1]};
    reg  [1:0] prev_owner; reg prev_v; reg [2:0] slave_of_addr;
    always @(*) case (1'b1)
        hsel[0]: slave_of_addr = 0; hsel[1]: slave_of_addr = 1; hsel[2]: slave_of_addr = 2;
        hsel[3]: slave_of_addr = 3; default: slave_of_addr = 4; endcase

    covergroup cg_addr @(posedge hclk_i iff (hreset_n_i && hready_o && htrans_o[1]));
        option.per_instance = 1;
        cp_master: coverpoint grant { bins iport = {0}; bins dport = {1}; bins sba = {2}; bins dma = {3}; }
        cp_slave: coverpoint slave_of_addr { bins isram = {0}; bins rom = {1}; bins dsram = {2}; bins bridge = {3}; bins undecoded = {4}; }
        cp_dir: coverpoint hwrite_o { bins read = {0}; bins write = {1}; }
        cp_size: coverpoint hsize_o { bins byte_ = {0}; bins half = {1}; bins word = {2}; }
        cp_trans: coverpoint htrans_o { bins nonseq = {2'b10}; bins seq = {2'b11}; }
        cp_contenders: coverpoint $countones(reqs) { bins one = {1}; bins two = {2}; bins three = {3}; bins four = {4}; }
        cp_split: coverpoint (htrans_sel == 2'b11 && seq_break) { bins kept = {0}; bins split_to_nonseq = {1}; }
        cp_handover: coverpoint (prev_v && prev_owner != grant) { bins same_master = {0}; bins new_master = {1}; }
        // [N-7.8] reachability: every master to every slave it is listed for, both directions
        x_master_slave_dir: cross cp_master, cp_slave, cp_dir {
            ignore_bins iport_writes = binsof(cp_master.iport) && binsof(cp_dir.write);   // [N-5.1]
        }
        // [N-7.3] each master wins against company
        x_master_contended: cross cp_master, cp_contenders;
        // [N-7.6] each master's burst split by a higher one
        x_master_split: cross cp_master, cp_split {
            ignore_bins dma_never_split = binsof(cp_master.dma) && binsof(cp_split.split_to_nonseq);
        }
        x_master_size: cross cp_master, cp_size {
            ignore_bins iport_words_only = binsof(cp_master.iport) && !binsof(cp_size.word);
        }
    endgroup

    always @(posedge hclk_i or negedge hreset_n_i)
        if (!hreset_n_i) begin prev_v <= 0; prev_owner <= 0; end
        else if (hready_o && htrans_o[1]) begin prev_v <= 1; prev_owner <= grant; end

    // ---- data phase: how it ended -------------------------------------------
    reg [2:0] dph_slave;
    always @(posedge hclk_i) if (hready_o) dph_slave <= slave_of_addr;
    integer waits = 0;
    always @(posedge hclk_i) if (hreset_n_i) begin
        if (dph_valid && !hready_o && !hresp_shared) waits <= (waits < 15) ? waits + 1 : waits;
        else if (hready_o) waits <= 0;
    end
    covergroup cg_resp @(posedge hclk_i iff (hreset_n_i && dph_valid && hready_o));
        option.per_instance = 1;
        cp_master: coverpoint dph_master { bins iport = {0}; bins dport = {1}; bins sba = {2}; bins dma = {3}; }
        cp_slave: coverpoint dph_slave { bins isram = {0}; bins rom = {1}; bins dsram = {2}; bins bridge = {3}; bins undecoded = {4}; }
        cp_resp: coverpoint hresp_shared { bins okay = {0}; bins error = {1}; }
        cp_waits: coverpoint waits { bins zero = {0}; bins one = {1}; bins some = {[2:4]}; bins many = {[5:15]}; }
        cp_held: coverpoint {hold_m, hold_s, hold_d, hold_i} { bins none = {0}; bins held = {[1:15]}; }
        // [N-7.16], [N-7.17] every master gets an ERROR back, from the default slave and from a real slave
        x_master_resp: cross cp_master, cp_resp;
        x_master_waits: cross cp_master, cp_waits;
        x_slave_resp: cross cp_slave, cp_resp {
            ignore_bins undecoded_ok = binsof(cp_slave.undecoded) && binsof(cp_resp.okay);
        }
    endgroup

    cg_addr ca = new();
    cg_resp cr = new();
endmodule

bind ahb_interconnect ahb_interconnect_cov u_ahb_cov (
    .hclk_i(hclk_i), .hreset_n_i(hreset_n_i),
    .i_htrans_i(i_htrans_i), .d_htrans_i(d_htrans_i), .s_htrans_i(s_htrans_i), .m_htrans_i(m_htrans_i),
    .haddr_o(haddr_o), .htrans_o(htrans_o), .hsize_o(hsize_o), .hburst_o(hburst_o),
    .hwrite_o(hwrite_o), .hready_o(hready_o),
    .grant(grant), .dph_master(dph_master), .htrans_sel(u_mmux.htrans_sel),
    .seq_break(seq_break), .dph_valid(dph_valid), .hresp_shared(hresp_shared), .hsel(hsel),
    .hold_i(u_mp_i.hold_valid), .hold_d(u_mp_d.hold_valid), .hold_s(u_mp_s.hold_valid), .hold_m(u_mp_m.hold_valid));
`endif
`endif
`endif
