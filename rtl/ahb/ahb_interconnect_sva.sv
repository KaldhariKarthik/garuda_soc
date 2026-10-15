`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 6 : properties for the AHB-Lite interconnect
// ahb_interconnect_sva.sv
//
// Spec: GARUDA-AHB-SPEC-001 sections 7.2 to 7.7 (the [N-x] numbers below).
// Bound to ahb_interconnect: the properties run in the block bench and in every
// chip simulation, where the real masters and slaves drive it. They are also
// the property set of the formal run flow/formal/ahb/ahb_fpv.tcl.
//
// Masters are named as in the spec: i = I-port (M0), d = D-port (M1),
// s = debug SBA (M2), m = DMA (M3). Priority is M3 > M2 > M1 > M0 [N-7.3].
//
// What the surroundings must do (assume_*): a master holds its address phase
// until it is accepted, and a slave's ERROR is two cycles. In simulation these
// are checked, so a master or slave model that breaks AHB is reported.
// Not compiled for synthesis or lint, and not under Icarus (TOOL-B2).
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
module ahb_interconnect_sva (
    input wire        hclk_i, hreset_n_i,
    // masters
    input wire [31:0] i_haddr_i, d_haddr_i, s_haddr_i, m_haddr_i,
    input wire [1:0]  i_htrans_i, d_htrans_i, s_htrans_i, m_htrans_i,
    input wire        i_hwrite_i, d_hwrite_i, s_hwrite_i, m_hwrite_i,
    input wire [2:0]  i_hsize_i, d_hsize_i, s_hsize_i, m_hsize_i,
    input wire [2:0]  i_hburst_i, d_hburst_i, s_hburst_i, m_hburst_i,
    input wire [31:0] i_hwdata_i, d_hwdata_i, s_hwdata_i, m_hwdata_i,
    input wire        i_hready_o, d_hready_o, s_hready_o, m_hready_o,
    input wire        i_hresp_o, d_hresp_o, s_hresp_o, m_hresp_o,
    input wire [31:0] i_hrdata_o, d_hrdata_o, s_hrdata_o, m_hrdata_o,
    // the shared layer
    input wire [31:0] haddr_o, hwdata_o,
    input wire [1:0]  htrans_o,
    input wire [2:0]  hsize_o,
    input wire        hwrite_o, hready_o, hmaster_is_sba_o,
    // slaves
    input wire        hreadyout_isram_i, hresp_isram_i, hreadyout_rom_i, hresp_rom_i,
    input wire        hreadyout_dsram_i, hresp_dsram_i, hreadyout_bridge_i, hresp_bridge_i,
    // internals
    input wire [1:0]  grant,
    input wire        seq_break, dph_valid, hresp_shared,
    input wire [1:0]  dph_master,
    input wire [4:0]  hsel,
    input wire [1:0]  htrans_sel,
    input wire        hold_i, hold_d, hold_s, hold_m
);
    localparam [1:0] M_I = 2'd0, M_D = 2'd1, M_S = 2'd2, M_M = 2'd3;
    localparam [1:0] SEQ = 2'b11;

    // ======================= the surroundings (assumed in formal) =============
    `define AHB_ASSUME_MASTER(P, T, A, W, S, B, RDY) \
    assume_``P``_holds: assume property (@(posedge hclk_i) disable iff (!hreset_n_i) \
        (T[1] && !RDY) |=> $stable({T, A, W, S, B}) );
    `AHB_ASSUME_MASTER(i, i_htrans_i, i_haddr_i, i_hwrite_i, i_hsize_i, i_hburst_i, i_hready_o)
    `AHB_ASSUME_MASTER(d, d_htrans_i, d_haddr_i, d_hwrite_i, d_hsize_i, d_hburst_i, d_hready_o)
    `AHB_ASSUME_MASTER(s, s_htrans_i, s_haddr_i, s_hwrite_i, s_hsize_i, s_hburst_i, s_hready_o)
    `AHB_ASSUME_MASTER(m, m_htrans_i, m_haddr_i, m_hwrite_i, m_hsize_i, m_hburst_i, m_hready_o)
    `define AHB_ASSUME_SLAVE(N, RDY, RESP) \
    assume_``N``_error2: assume property (@(posedge hclk_i) disable iff (!hreset_n_i) \
        (RESP && !RDY) |=> (RESP && RDY) );
    `AHB_ASSUME_SLAVE(isram,  hreadyout_isram_i,  hresp_isram_i)
    `AHB_ASSUME_SLAVE(rom,    hreadyout_rom_i,    hresp_rom_i)
    `AHB_ASSUME_SLAVE(dsram,  hreadyout_dsram_i,  hresp_dsram_i)
    `AHB_ASSUME_SLAVE(bridge, hreadyout_bridge_i, hresp_bridge_i)

    // ======================= arbitration ======================================
    // [N-7.3] fixed priority, evaluated on every beat boundary [N-7.4]
    a_prio_dma: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        ($past(hready_o) && m_htrans_i[1]) |-> grant == M_M )
        else $error("[SVA-FAIL] a_prio_dma: the DMA requested at a beat boundary and was not granted");
    a_prio_sba: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        ($past(hready_o) && s_htrans_i[1] && !m_htrans_i[1]) |-> grant == M_S )
        else $error("[SVA-FAIL] a_prio_sba: the SBA outranked by a lower master");
    a_prio_dport: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        ($past(hready_o) && d_htrans_i[1] && !m_htrans_i[1] && !s_htrans_i[1]) |-> grant == M_D )
        else $error("[SVA-FAIL] a_prio_dport: the D-port outranked by the I-port");
    a_prio_iport: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        ($past(hready_o) && i_htrans_i[1] && !m_htrans_i[1] && !s_htrans_i[1] && !d_htrans_i[1]) |-> grant == M_I )
        else $error("[SVA-FAIL] a_prio_iport: the only requester was not granted");
    // [N-7.5] the grant does not change while the address phase is not accepted
    a_grant_held: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        !hready_o |=> grant == $past(grant) )
        else $error("[SVA-FAIL] a_grant_held: the grant moved while HREADY was low");
    // AHB: the address phase on the shared layer is stable until accepted
    a_addr_phase_stable: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (htrans_o[1] && !hready_o) |=> $stable({haddr_o, htrans_o, hwrite_o, hsize_o}) )
        else $error("[SVA-FAIL] a_addr_phase_stable: the address phase changed before it was accepted");
    // [N-7.6] AHB-3: a SEQ beat is never presented to a slave whose master did not own the previous beat
    // Independent of the RTL's own seq_break: a shadow record of who owned the last accepted beat.
    reg [1:0] last_owner = 2'd0; reg last_v = 1'b0;
    always @(posedge hclk_i or negedge hreset_n_i)
        if (!hreset_n_i) last_v <= 1'b0;
        else if (hready_o && htrans_o[1]) begin last_owner <= grant; last_v <= 1'b1; end
    a_no_orphan_seq: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        htrans_o == SEQ |-> (last_v && last_owner == grant) )
        else $error("[SVA-FAIL] a_no_orphan_seq: a SEQ beat after a change of master");
    // AHB-1: the write data on the bus is the data of the master that owns the data phase
    a_hwdata_owner: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        dph_valid |-> hwdata_o == (dph_master == M_M ? m_hwdata_i : dph_master == M_S ? s_hwdata_i :
                                   dph_master == M_D ? d_hwdata_i : i_hwdata_i) )
        else $error("[SVA-FAIL] a_hwdata_owner: HWDATA is not the data phase owner's");
    // [N-7.14] the SBA indication follows the grant
    a_sba_indication: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        hmaster_is_sba_o == (grant == M_S) )
        else $error("[SVA-FAIL] a_sba_indication: hmaster_is_sba_o does not follow the grant");

    // ======================= decode ===========================================
    // [N-7.12] HSEL is one-hot, and every unused encoding goes to the default slave
    a_hsel_onehot: assert property (@(posedge hclk_i) disable iff (!hreset_n_i) $onehot(hsel) )
        else $error("[SVA-FAIL] a_hsel_onehot: HSEL is not one-hot");
    // [N-7.11] the four granules, everything else is the default slave
    a_hsel_map: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        hsel == (haddr_o[31:28] == 4'h0 ? 5'b00001 : haddr_o[31:28] == 4'h1 ? 5'b00010 :
                 haddr_o[31:28] == 4'h2 ? 5'b00100 : haddr_o[31:28] == 4'h4 ? 5'b01000 : 5'b10000) )
        else $error("[SVA-FAIL] a_hsel_map: a granule selects the wrong slave");

    // ======================= response =========================================
    // [N-7.16] the default slave answers a selected transfer with the two-cycle ERROR
    a_default_error: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (hsel[4] && htrans_o[1] && hready_o) |=> ((hresp_shared && !hready_o) ##1 (hresp_shared && hready_o)) )
        else $error("[SVA-FAIL] a_default_error: an undecoded address did not get the two-cycle ERROR");
    // [N-7.20] a master that presents a transfer and is not granted sees HREADY low
    a_ungranted_waits_i: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (i_htrans_i[1] && grant != M_I) |-> !i_hready_o )
        else $error("[SVA-FAIL] a_ungranted_waits: the I-port saw HREADY while not granted");
    a_ungranted_waits_d: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (d_htrans_i[1] && grant != M_D) |-> !d_hready_o )
        else $error("[SVA-FAIL] a_ungranted_waits: the D-port saw HREADY while not granted");
    a_ungranted_waits_s: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (s_htrans_i[1] && grant != M_S) |-> !s_hready_o )
        else $error("[SVA-FAIL] a_ungranted_waits: the SBA saw HREADY while not granted");
    a_ungranted_waits_m: assert property (@(posedge hclk_i) disable iff (!hreset_n_i)
        (m_htrans_i[1] && grant != M_M) |-> !m_hready_o )
        else $error("[SVA-FAIL] a_ungranted_waits: the DMA saw HREADY while not granted");
    // a master that owns nothing in flight and holds nothing sees OKAY and zero data
    `define AHB_QUIET(P, DPH, HOLD, RESP, DATA) \
    a_quiet_``P``: assert property (@(posedge hclk_i) disable iff (!hreset_n_i) \
        (!(dph_valid && dph_master == DPH) && !HOLD) |-> (!RESP && DATA == 32'd0) ) \
        else $error("[SVA-FAIL] a_quiet: a master that owns no data phase saw a response");
    `AHB_QUIET(i, M_I, hold_i, i_hresp_o, i_hrdata_o)
    `AHB_QUIET(d, M_D, hold_d, d_hresp_o, d_hrdata_o)
    `AHB_QUIET(s, M_S, hold_s, s_hresp_o, s_hrdata_o)
    `AHB_QUIET(m, M_M, hold_m, m_hresp_o, m_hrdata_o)
    // [N-7.18] the bus never hangs: HREADY is back within a bounded time, given slaves that answer
    // (a slave that never answers is the slave's defect and is outside this property)

    // ======================= reachability =====================================
    c_all_request:     cover property (@(posedge hclk_i) $past(hready_o) && i_htrans_i[1] && d_htrans_i[1] && s_htrans_i[1] && m_htrans_i[1]);
    c_dma_preempts:    cover property (@(posedge hclk_i) $past(hready_o) && m_htrans_i[1] && grant == M_M && $past(grant) == M_I);
    c_held_against_hp: cover property (@(posedge hclk_i) !hready_o && m_htrans_i[1] && grant != M_M && htrans_o[1]);
    c_burst_split:     cover property (@(posedge hclk_i) htrans_sel == SEQ && seq_break && htrans_o == 2'b10);
    c_default_error:   cover property (@(posedge hclk_i) hsel[4] && htrans_o[1] && hready_o);
    c_slave_error:     cover property (@(posedge hclk_i) hresp_shared && !hready_o && !hsel[4]);
    c_data_held:       cover property (@(posedge hclk_i) hold_i || hold_d || hold_s || hold_m);
    c_slave_wait:      cover property (@(posedge hclk_i) dph_valid && !hready_o && !hresp_shared);
    c_sba_granted:     cover property (@(posedge hclk_i) grant == M_S && htrans_o[1] && hmaster_is_sba_o);
endmodule

bind ahb_interconnect ahb_interconnect_sva u_ahb_sva (
    .hclk_i(hclk_i), .hreset_n_i(hreset_n_i),
    .i_haddr_i(i_haddr_i), .d_haddr_i(d_haddr_i), .s_haddr_i(s_haddr_i), .m_haddr_i(m_haddr_i),
    .i_htrans_i(i_htrans_i), .d_htrans_i(d_htrans_i), .s_htrans_i(s_htrans_i), .m_htrans_i(m_htrans_i),
    .i_hwrite_i(i_hwrite_i), .d_hwrite_i(d_hwrite_i), .s_hwrite_i(s_hwrite_i), .m_hwrite_i(m_hwrite_i),
    .i_hsize_i(i_hsize_i), .d_hsize_i(d_hsize_i), .s_hsize_i(s_hsize_i), .m_hsize_i(m_hsize_i),
    .i_hburst_i(i_hburst_i), .d_hburst_i(d_hburst_i), .s_hburst_i(s_hburst_i), .m_hburst_i(m_hburst_i),
    .i_hwdata_i(i_hwdata_i), .d_hwdata_i(d_hwdata_i), .s_hwdata_i(s_hwdata_i), .m_hwdata_i(m_hwdata_i),
    .i_hready_o(i_hready_o), .d_hready_o(d_hready_o), .s_hready_o(s_hready_o), .m_hready_o(m_hready_o),
    .i_hresp_o(i_hresp_o), .d_hresp_o(d_hresp_o), .s_hresp_o(s_hresp_o), .m_hresp_o(m_hresp_o),
    .i_hrdata_o(i_hrdata_o), .d_hrdata_o(d_hrdata_o), .s_hrdata_o(s_hrdata_o), .m_hrdata_o(m_hrdata_o),
    .haddr_o(haddr_o), .hwdata_o(hwdata_o), .htrans_o(htrans_o), .hsize_o(hsize_o),
    .hwrite_o(hwrite_o), .hready_o(hready_o), .hmaster_is_sba_o(hmaster_is_sba_o),
    .hreadyout_isram_i(hreadyout_isram_i), .hresp_isram_i(hresp_isram_i),
    .hreadyout_rom_i(hreadyout_rom_i), .hresp_rom_i(hresp_rom_i),
    .hreadyout_dsram_i(hreadyout_dsram_i), .hresp_dsram_i(hresp_dsram_i),
    .hreadyout_bridge_i(hreadyout_bridge_i), .hresp_bridge_i(hresp_bridge_i),
    .grant(grant), .seq_break(seq_break), .dph_valid(dph_valid), .hresp_shared(hresp_shared),
    .dph_master(dph_master), .hsel(hsel), .htrans_sel(u_mmux.htrans_sel),
    .hold_i(u_mp_i.hold_valid), .hold_d(u_mp_d.hold_valid), .hold_s(u_mp_s.hold_valid), .hold_m(u_mp_m.hold_valid));
`endif
`endif
