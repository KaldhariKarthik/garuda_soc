`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 15 : properties for the I2C master
// garuda_i2c_sva.sv
//
// Spec: GARUDA-I2C-SPEC-001. Plan: tb/i2c/GARUDA_I2C_vplan.csv; each property
// names its feature. Bound to garuda_i2c_top, so the properties run in the block
// bench, in the UVM environment and in every chip simulation. The
// register-port properties are those of the shared shim
// (rtl/common/garuda_apb_shim_sva.sv). Not compiled for synthesis or lint.
// =============================================================================
`ifndef SYNTHESIS
`ifndef __ICARUS__
// Icarus Verilog does not parse concurrent assertions; under it this file is
// empty and the block is simulated without its properties (TOOL-B2).
module garuda_i2c_sva (
    input wire        pclk_i,
    input wire        preset_n_i,
    input wire        pready_o,
    input wire        pslverr_o,
    input wire        irq_o,
    input wire        dma_req_o,
    input wire        dma_ack_i,
    input wire        i2c_scl_o, i2c_sda_o, i2c_scl_oe, i2c_sda_oe,
    input wire        scl_sync,
    input wire        en_q, tip_q, al_q, to_q, rxvalid_q,
    input wire        cmd_write, cmd_ok, rd_rx,
    input wire [4:0]  cmd_bits,        // the value being written to CMD
    input wire        core_held, core_al, core_ack,
    input wire        abort_req, to_pulse,
    input wire [15:0] timeout_q,
    input wire [15:0] prescale_q,
    input wire [3:0]  bit_cmd,         // what the bit controller is doing: 0100 a written bit
    input wire [3:0]  irqstat, irqen, evt
);
    // ---- F11: an access never waits
    a_pready: assert property (@(posedge pclk_i) pready_o)
        else $error("[SVA-FAIL] a_pready: pready_o low");

    // ---- F27: the block can pull a line low or release it, never drive it high
    a_never_high: assert property (@(posedge pclk_i) !i2c_scl_o && !i2c_sda_o)
        else $error("[SVA-FAIL] a_never_high: scl_o %0b sda_o %0b", i2c_scl_o, i2c_sda_o);

    // ---- F28: both lines released in reset and until firmware starts a transfer
    reg seen_cmd;
    always @(posedge pclk_i or negedge preset_n_i)
        if (!preset_n_i) seen_cmd <= 1'b0;
        else if (cmd_ok) seen_cmd <= 1'b1;
    // (in reset from the second clock edge on: a two-state simulator applies a reset that is
    // already asserted at time 0 only at the first edge, TB-B1)
    a_released_in_reset: assert property (@(posedge pclk_i)
        ((!preset_n_i && $past(!preset_n_i)) || (preset_n_i && !seen_cmd)) |-> (!i2c_scl_oe && !i2c_sda_oe))
        else $error("[SVA-FAIL] a_released_in_reset: a line pulled low before the first CMD");

    // ---- F06: a CMD written during a transfer is refused with PSLVERR
    a_cmd_while_tip: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        (cmd_write && tip_q) |-> (pslverr_o && !cmd_ok))
        else $error("[SVA-FAIL] a_cmd_while_tip: a CMD during a transfer was not refused");

    // ---- F05 (I2C-7): a CMD with none of RD, WR and STO has nothing to do and is refused too
    a_cmd_nothing_to_do: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        (cmd_write && cmd_bits[3:1] == 3'b000) |-> (pslverr_o && !cmd_ok))
        else $error("[SVA-FAIL] a_cmd_nothing_to_do: CMD %02h was not refused", cmd_bits);

    // ---- F04: a read of RXDATA clears RXVALID and never starts a transfer
    a_rxdata_read_no_cmd: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        rd_rx |=> (!rxvalid_q && !$rose(tip_q)))
        else $error("[SVA-FAIL] a_rxdata_read_no_cmd: RXVALID %0b, TIP rose %0b after a read of RXDATA", rxvalid_q, $rose(tip_q));

    // ---- F07, F25 (I2C-6): a transfer starts only from a CMD accepted while enabled;
    // with EN clear nothing is in progress and both lines are released
    a_no_replay: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        ($rose(tip_q) |-> $past(cmd_ok && en_q)) and (!en_q |=> !tip_q) and (core_held |-> (!i2c_scl_oe && !i2c_sda_oe)))
        else $error("[SVA-FAIL] a_no_replay: TIP %0b EN %0b held %0b scl_oe %0b sda_oe %0b", tip_q, en_q, core_held, i2c_scl_oe, i2c_sda_oe);

    // ---- F24: ABORT (and the timeout, which does the same) releases both lines in the next pclk
    a_abort_releases: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        abort_req |=> (!i2c_scl_oe && !i2c_sda_oe) ##1 !tip_q)
        else $error("[SVA-FAIL] a_abort_releases: scl_oe %0b sda_oe %0b TIP %0b after ABORT or a timeout", i2c_scl_oe, i2c_sda_oe, tip_q);

    // ---- F22: after arbitration is lost both lines stay released until the next CMD
    a_al_releases: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        core_al |=> ((!i2c_scl_oe && !i2c_sda_oe) until cmd_ok))
        else $error("[SVA-FAIL] a_al_releases: a line pulled low after arbitration was lost and before a CMD");

    // ---- F23: with TIMEOUT non-zero a transfer is never in progress for longer than TIMEOUT
    reg [16:0] tip_cnt; reg [15:0] tmo_l;
    always @(posedge pclk_i or negedge preset_n_i)
        if (!preset_n_i) begin tip_cnt <= 17'd0; tmo_l <= 16'd0; end
        else begin
            tip_cnt <= tip_q ? tip_cnt + 17'd1 : 17'd0;
            if (!tip_q) tmo_l <= timeout_q;
        end
    a_tip_bounded: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        (tip_q && tmo_l != 16'd0) |-> (tip_cnt <= {1'b0, tmo_l}))
        else $error("[SVA-FAIL] a_tip_bounded: TIP set for %0d pclk with TIMEOUT %0d", tip_cnt, tmo_l);

    // ---- F16: while the block sends a data bit, SDA does not move while SCL is high.
    // Below the smallest usable PRESCALE the block does not make a legal bus at all (I2C-8, [N-6.1a]).
    a_sda_stable_scl_high: assert property (@(posedge pclk_i) disable iff (!preset_n_i || core_held || prescale_q < 16'd3)
        (scl_sync && $past(scl_sync) && bit_cmd == 4'b0100 && $past(bit_cmd == 4'b0100)) |-> $stable(i2c_sda_oe))
        else $error("[SVA-FAIL] a_sda_stable_scl_high: SDA moved with SCL high inside a written bit");

    // ---- F29: the interrupt is the OR of the enabled flags; an event beats its own clear
    a_irq_held: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        irq_o == |(irqstat & irqen))
        else $error("[SVA-FAIL] a_irq_held: irq_o %0b, IRQSTAT %04b, IRQEN %04b", irq_o, irqstat, irqen);
    genvar e;
    generate for (e = 0; e < 4; e = e + 1) begin : g_evt
        a_set_beats_clear: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
            (preset_n_i && evt[e]) |=> irqstat[e])     // preset_n_i as sampled: the flops were out of reset at that edge
            else $error("[SVA-FAIL] a_set_beats_clear: event %0d was lost", e);
    end endgenerate
    a_set_beats_clear_status: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        (core_al |=> al_q) and (to_pulse |=> to_q))
        else $error("[SVA-FAIL] a_set_beats_clear_status: a sticky STATUS bit was lost");
    // the two sticky STATUS bits are the same flags as their interrupt bits
    a_status_irqstat_agree: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        (al_q == irqstat[1]) && (to_q == irqstat[2]))
        else $error("[SVA-FAIL] a_status_irqstat_agree: STATUS AL %0b TIMEOUT %0b, IRQSTAT %04b", al_q, to_q, irqstat);

    // ---- F30: the request is low with the acknowledge and in the pclk after it
    a_dma_drop: assert property (@(posedge pclk_i) disable iff (!preset_n_i)
        dma_ack_i |-> (!dma_req_o ##1 !dma_req_o))
        else $error("[SVA-FAIL] a_dma_drop: dma_req_o high during or right after dma_ack_i");

    c_al:            cover property (@(posedge pclk_i) preset_n_i && core_al);
    c_timeout:       cover property (@(posedge pclk_i) preset_n_i && to_pulse);
    c_abort_in_tip:  cover property (@(posedge pclk_i) preset_n_i && abort_req && tip_q && !to_pulse);
    c_ack_and_abort: cover property (@(posedge pclk_i) preset_n_i && core_ack && abort_req);
endmodule

bind garuda_i2c_top garuda_i2c_sva u_i2c_sva (
    .pclk_i(pclk_i), .preset_n_i(preset_n_i), .pready_o(pready_o), .pslverr_o(pslverr_o), .irq_o(irq_o),
    .dma_req_o(dma_req_o), .dma_ack_i(dma_ack_i),
    .i2c_scl_o(i2c_scl_o), .i2c_sda_o(i2c_sda_o), .i2c_scl_oe(i2c_scl_oe), .i2c_sda_oe(i2c_sda_oe),
    .scl_sync(scl_sync), .en_q(en_q), .tip_q(tip_q), .al_q(al_q), .to_q(to_q), .rxvalid_q(rxvalid_q),
    .cmd_write(cmd_write), .cmd_ok(cmd_ok), .cmd_bits(pwdata_i[4:0]),
    .rd_rx(ip_psel & ip_penable & ~ip_pwrite & (ip_paddr == A_RXDATA)),
    .core_held(core_held), .core_al(core_al), .core_ack(core_ack),
    .abort_req(abort_req), .to_pulse(to_pulse), .timeout_q(timeout_q), .prescale_q(prescale_q),
    .bit_cmd(u_byte.core_cmd),
    .irqstat(u_shim.irqstat_q), .irqen(u_shim.irqen_q), .evt(evt));
`endif
`endif
