`timescale 1ns/1ps
// =============================================================================
// spis_env_pkg.sv - UVM environment for block 14, the SPI slave.
//
// Plan: tb/spi_slave/GARUDA_SPIS_vplan.csv. Names of checks and covergroups are
// the names in the plan.
//
//   spis_spi_agent  the external SPI master: drives SCLK, MOSI and chip select at
//                   any phase to pclk, at any rate, with packets of any length,
//                   part bytes, glitches on chip select and clocks while not
//                   selected; samples MISO on its own rising edge of SCLK
//   spis_monitor    one item per pclk cycle: reset, the APB pins, the SPI pins as
//                   the first synchroniser flop takes them, MISO, the interrupt
//                   and the DMA request
//   spis_ref_model  written from GARUDA-SPIS-SPEC-001 sections 6 and 7 and
//                   DECISIONS.md D-21; stepped once per pclk; never looks at
//                   the RTL
//   spis_scoreboard every cycle MISO and its enable, the interrupt and the DMA
//                   request (sb_miso, sb_irq, sb_dma); every read (sb_rx,
//                   sb_status, sb_fifo, sb_reg); every access (sb_pslverr,
//                   sb_pready); and, per packet, what the agent sent against what
//                   the block received and what the agent received against
//                   TXDATA (sb_rx, sb_tx), which does not go through the model's
//                   own bit assembly
//   spis_coverage   the plan's covergroups
//
// Time on the SPI side is counted in tenths of a pclk period (0.8 ns).
// =============================================================================
package spis_env_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import garuda_apb_pkg::*;
    import spis_reg_pkg::*;

    localparam bit [31:0] SPIS_ID   = 32'h6A5D_0E01;
    localparam int        SPIS_FIFO = 16;
    localparam real       TENTH_NS  = 0.8;                  // a tenth of the 8 ns pclk period
    localparam real       PCLK_NS   = 8.0;
    localparam real       EDGE0_NS  = 4.0;                  // the first rising edge of pclk

    // ------------------------------------------------------------------ the SPI master agent
    typedef enum { SPIS_PACKET, SPIS_IDLE_CLOCKS, SPIS_CS_GLITCH } spis_kind_e;

    class spis_pkt extends uvm_sequence_item;
        rand spis_kind_e  kind;
        rand bit [7:0]    data[];        // the whole bytes of the packet
        rand int unsigned extra;         // further bits after the last whole byte (0 to 7)
        rand bit [6:0]    extra_data;
        rand int unsigned lo_t, hi_t;    // SCLK low and high time
        rand int unsigned lead_t;        // chip select low to the first rising edge
        rand int unsigned trail_t;       // last falling edge to chip select high
        rand int unsigned gap_t;         // idle time before this item
        rand int unsigned glitch_at;     // PACKET: chip select pulses high after this many bits (0 = no glitch)
        rand int unsigned glitch_t;      // width of a glitch
        rand int unsigned n_idle;        // IDLE_CLOCKS: clock pulses with chip select high
        // observed by the driver
        bit [7:0]    miso[$];            // one byte per whole byte sent, sampled at the rising edges
        realtime     t_fall, t_rise;     // chip select low and high
        int unsigned gap_seen;           // chip select high time before the packet
        bit          after_packet;       // the item before this one was a packet
        bit          glitch_seen;        // a clock edge of pclk fell inside the glitch
        bit [9:0]    phase_seen;         // tenth of the pclk period of each rising edge of SCLK

        constraint c_kind  { kind dist { SPIS_PACKET := 90, SPIS_IDLE_CLOCKS := 4, SPIS_CS_GLITCH := 6 }; }
        constraint c_len   { data.size() dist { 0 := 4, 1 := 12, 2 := 10, [3:15] :/ 44, 16 := 8, 17 := 8, [18:40] :/ 8, 64 := 6 }; }
        constraint c_extra { extra dist { 0 := 80, [1:7] :/ 20 }; }
        constraint c_rate  { lo_t dist { [30:39] :/ 35, [40:59] :/ 30, [60:140] :/ 28, [600:640] :/ 3, [20:29] :/ 4 };
                             hi_t dist { [30:39] :/ 35, [40:59] :/ 30, [60:140] :/ 28, [600:640] :/ 3, [20:29] :/ 4 };
                             (lo_t >= 600 || hi_t >= 600) -> data.size() <= 2; }
        constraint c_edges { lead_t dist { [1:9] :/ 3, [10:39] :/ 7, [40:120] :/ 90 }; trail_t inside {[1:120]};
                             gap_t dist { [11:15] :/ 15, [16:60] :/ 45, [61:600] :/ 40 }; }
        constraint c_glitch { glitch_t inside {[1:9]};
                              (kind == SPIS_PACKET) -> glitch_at dist { 0 := 95, [1:40] :/ 5 };
                              glitch_at <= 8 * data.size() + extra; solve data before glitch_at; }
        constraint c_idle  { n_idle inside {[1:20]}; }

        `uvm_object_utils(spis_pkt)
        function new(string name = "spis_pkt"); super.new(name); endfunction

        // a packet whose bytes both sides must agree on: the rates and the lead time of the
        // specification (SPIS [N-7.1a]), no glitch, and a gap the block can see
        function bit in_spec();
            return kind == SPIS_PACKET && lo_t >= 30 && hi_t >= 30 && lead_t >= 40 && glitch_at == 0 && gap_seen >= 11;
        endfunction
        function string convert2string();
            return $sformatf("%s %0d bytes +%0d bits lo %0d hi %0d lead %0d gap %0d glitch_at %0d", kind.name(), data.size(), extra,
                             lo_t, hi_t, lead_t, gap_seen, glitch_at);
        endfunction
    endclass

    // where the master is, for the coverage of EN changes
    class spis_line_state;
        bit          in_packet;
        int unsigned bits_done;
    endclass

    class spis_spi_driver extends uvm_driver #(spis_pkt);
        `uvm_component_utils(spis_spi_driver)
        virtual spis_if vif;
        uvm_analysis_port #(spis_pkt) ap;
        spis_line_state line;
        longint unsigned tick;                 // tenths of pclk since time 0.4 ns
        realtime t_last_rise = 0; bit last_was_packet;

        function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); line = new(); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual spis_if)::get(this, "", "svif", vif)) `uvm_fatal("NOVIF", "spis_spi_driver: no virtual interface")
        endfunction

        task wait_t(int unsigned n); #(n * TENTH_NS); tick += n; endtask

        // Every edge the agent makes is on a grid of 0.8 ns that starts at 0.4 ns, so that
        // none coincides with an edge of pclk (4 ns + 8 k): the block's synchroniser then
        // takes the same value in every simulator.
        task align();
            longint p = longint'($realtime * 1000.0), r;
            r = (p - 400) % 800; if (r < 0) r += 800;
            if (r != 0) #((800 - r) * 1ps);
            tick = (longint'($realtime * 1000.0) - 400) / 800;
        endtask

        // is there a rising edge of pclk strictly inside (a, b)?
        function bit edge_inside(realtime a, realtime b);
            return $floor((b - EDGE0_NS) / PCLK_NS) > $floor((a - EDGE0_NS) / PCLK_NS);
        endfunction

        task run_phase(uvm_phase phase);
            vif.sclk = 1'b0; vif.mosi = 1'b0; vif.cs_n = 1'b1;
            forever begin
                seq_item_port.get_next_item(req);
                align();
                drive(req);
                ap.write(req);
                seq_item_port.item_done();
            end
        endtask

        task drive(spis_pkt p);
            int unsigned nbits = 8 * p.data.size() + p.extra;
            bit b; bit [7:0] rx; realtime g0;
            wait_t(p.gap_t);
            p.after_packet = last_was_packet;
            p.miso.delete(); p.phase_seen = 0; p.glitch_seen = 0;
            case (p.kind)
                SPIS_IDLE_CLOCKS: begin                           // another device on the bus is being clocked
                    repeat (p.n_idle) begin
                        vif.mosi = $urandom_range(0, 1);
                        vif.sclk = 1'b1; wait_t(p.hi_t); vif.sclk = 1'b0; wait_t(p.lo_t);
                    end
                    last_was_packet = 0;
                end
                SPIS_CS_GLITCH: begin                             // a low pulse shorter than one pclk
                    g0 = $realtime; vif.cs_n = 1'b0; wait_t(p.glitch_t); vif.cs_n = 1'b1;
                    p.glitch_seen = edge_inside(g0, $realtime);
                    last_was_packet = 0;
                end
                default: begin
                    p.t_fall = $realtime;
                    p.gap_seen = (t_last_rise == 0) ? 1000 : int'((p.t_fall - t_last_rise) / TENTH_NS + 0.5);
                    vif.cs_n = 1'b0; line.in_packet = 1; line.bits_done = 0;
                    if (nbits != 0) begin
                        b = (p.data.size() != 0) ? p.data[0][7] : p.extra_data[6];
                        vif.mosi = b;
                    end
                    wait_t(p.lead_t);
                    for (int unsigned i = 0; i < nbits; i++) begin
                        rx = {rx[6:0], vif.miso};                 // the master samples just before its own rising edge
                        p.phase_seen[tick % 10] = 1'b1;
                        vif.sclk = 1'b1; line.bits_done = i + 1;
                        if (i % 8 == 7 && i / 8 < p.data.size()) p.miso.push_back(rx);
                        wait_t(p.hi_t);
                        vif.sclk = 1'b0;
                        if (i + 1 < nbits) begin
                            int unsigned k = i + 1;
                            b = (k / 8 < p.data.size()) ? p.data[k / 8][7 - (k % 8)] : p.extra_data[6 - (k % 8)];
                            vif.mosi = b;
                            if (p.glitch_at == i + 1) begin       // a high pulse on chip select in mid-packet
                                wait_t(p.lo_t / 2);
                                g0 = $realtime; vif.cs_n = 1'b1; wait_t(p.glitch_t); vif.cs_n = 1'b0;
                                p.glitch_seen = edge_inside(g0, $realtime);
                                wait_t(p.lo_t);
                            end else wait_t(p.lo_t);
                        end
                    end
                    wait_t(p.trail_t);
                    vif.cs_n = 1'b1; line.in_packet = 0;
                    p.t_rise = $realtime; t_last_rise = p.t_rise; last_was_packet = 1;
                end
            endcase
        endtask
    endclass

    class spis_spi_agent extends uvm_agent;
        `uvm_component_utils(spis_spi_agent)
        spis_spi_driver drv;
        uvm_sequencer #(spis_pkt) sqr;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            drv = spis_spi_driver::type_id::create("drv", this);
            sqr = uvm_sequencer #(spis_pkt)::type_id::create("sqr", this);
        endfunction
        function void connect_phase(uvm_phase phase); drv.seq_item_port.connect(sqr.seq_item_export); endfunction
    endclass

    // ------------------------------------------------------------------ monitor
    class spis_cycle_item extends uvm_sequence_item;
        bit preset_n;
        bit psel, penable, pwrite; bit [11:0] paddr; bit [31:0] pwdata;
        bit sclk, mosi, cs_n, dma_ack;
        logic miso, miso_oe, irq, dma_req;
        logic [31:0] prdata; logic pready, pslverr;
        `uvm_object_utils(spis_cycle_item)
        function new(string name = "spis_cycle_item"); super.new(name); endfunction
    endclass

    class spis_monitor extends uvm_monitor;
        `uvm_component_utils(spis_monitor)
        virtual spis_if vif;
        uvm_analysis_port #(spis_cycle_item) ap;
        function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual spis_if)::get(this, "", "svif", vif)) `uvm_fatal("NOVIF", "spis_monitor: no virtual interface")
        endfunction
        task run_phase(uvm_phase phase);
            spis_cycle_item it;
            forever begin
                @(vif.cb);
                it = spis_cycle_item::type_id::create("it");
                it.preset_n = (vif.cb.preset_n === 1'b1);
                it.psel = vif.cb.psel; it.penable = vif.cb.penable; it.pwrite = vif.cb.pwrite;
                it.paddr = vif.cb.paddr; it.pwdata = vif.cb.pwdata;
                it.sclk = vif.cb.sclk; it.mosi = vif.cb.mosi; it.cs_n = vif.cb.cs_n; it.dma_ack = vif.cb.dma_ack;
                it.miso = vif.cb.miso; it.miso_oe = vif.cb.miso_oe; it.irq = vif.cb.irq; it.dma_req = vif.cb.dma_req;
                it.prdata = vif.cb.prdata; it.pready = vif.cb.pready; it.pslverr = vif.cb.pslverr;
                ap.write(it);
            end
        endtask
    endclass

    // ------------------------------------------------------------------ reference model
    // What the model saw of one packet, for the comparison with the agent's own record.
    class spis_pkt_rec;
        bit [7:0] rx[$];         // bytes assembled, whether or not the FIFO had room
        bit [7:0] tx[$];         // TXDATA as loaded for each byte
        realtime  t_open;
    endclass

    class spis_ref_model extends uvm_object;
        `uvm_object_utils(spis_ref_model)
        // registers (SPIS section 6) and the shim registers (D-21)
        bit        en; bit [7:0] txdata;
        bit        ovr, done;
        bit [2:0]  irqstat, irqen; bit [1:0] dmactl; bit holdoff;
        // the three inputs through two flops, and one more for the edges (SPIS 7.1)
        bit [2:0]  s0, s1;                       // {cs_n, mosi, sclk}
        bit        sclk_q, cs_n_q;
        // packet framing and the two shifters (SPIS 7.2, 7.3)
        bit        open;
        bit        cs_fall_q, cs_rise_q, rx_push;
        bit [7:0]  rx_sh, rx_byte, tx_sh; bit [2:0] bitcnt;
        // the receive FIFO (SPIS 7.5)
        bit [7:0]  fifo[$];
        // what the last step did, for the scoreboard and the coverage
        bit        ev_wr; bit [11:0] ev_addr; bit [31:0] ev_wdata;
        bit        ev_push, ev_push_full, ev_rise, ev_flush, ev_fall_now, ev_load, ev_abort;
        bit [2:0]  ev_evt, ev_clr; int ev_level;
        bit        ev_tx_wr_mid, ev_tx_wr_edge;  // TXDATA written since the last load: inside a byte, at a byte boundary
        bit        tx_wr_mid, tx_wr_edge;
        // the packet in progress and the packets that ended
        spis_pkt_rec cur; spis_pkt_rec ended[$];

        function new(string name = "spis_ref_model"); super.new(name); reset(); endfunction

        function void reset();
            en = 0; txdata = 0; ovr = 0; done = 0; irqstat = 0; irqen = 0; dmactl = 0; holdoff = 0;
            s0 = 3'b100; s1 = 3'b100; sclk_q = 0; cs_n_q = 1;
            open = 0; cs_fall_q = 0; cs_rise_q = 0; rx_push = 0; rx_sh = 0; rx_byte = 0; tx_sh = 0; bitcnt = 0;
            fifo.delete(); cur = null; ended.delete();
            ev_wr = 0; ev_push = 0; ev_push_full = 0; ev_rise = 0; ev_flush = 0; ev_fall_now = 0; ev_load = 0; ev_abort = 0;
            ev_evt = 0; ev_clr = 0; tx_wr_mid = 0; tx_wr_edge = 0;
        endfunction

        function void copy_state(spis_ref_model o);
            en = o.en; txdata = o.txdata; ovr = o.ovr; done = o.done; irqstat = o.irqstat; irqen = o.irqen; dmactl = o.dmactl;
            holdoff = o.holdoff; s0 = o.s0; s1 = o.s1; sclk_q = o.sclk_q; cs_n_q = o.cs_n_q; open = o.open;
            cs_fall_q = o.cs_fall_q; cs_rise_q = o.cs_rise_q; rx_push = o.rx_push; rx_sh = o.rx_sh; rx_byte = o.rx_byte;
            tx_sh = o.tx_sh; bitcnt = o.bitcnt; fifo = o.fifo;
        endfunction

        // the register map: four word registers at 0x00 to 0x0C and the four shim registers
        function bit in_ip(bit [11:0] a);  return (a[1:0] == 2'b00) && (a < 12'h010); endfunction
        function bit mapped(bit [11:0] a); return in_ip(a) || (a[1:0] == 2'b00 && a >= 12'hFE0 && a <= 12'hFEC); endfunction

        function bit sclk_s(); return s1[0]; endfunction
        function bit mosi_s(); return s1[1]; endfunction
        function bit cs_n_s(); return s1[2]; endfunction
        function bit fall_now(); return cs_n_q && !cs_n_s() && en; endfunction
        // selected: enabled, chip select low, and the packet was opened by a falling edge seen while enabled (SPIS-5)
        function bit cs_active(); return !cs_n_s() && en && (open || fall_now()); endfunction
        function bit miso();    return tx_sh[7]; endfunction
        function bit miso_oe(); return cs_active(); endfunction
        function bit irq();     return |(irqstat & irqen); endfunction
        function bit dma_req(bit ack); return dmactl[0] && (fifo.size() != 0) && !holdoff && !ack; endfunction

        function bit [31:0] rd(bit [11:0] a);
            if (!mapped(a)) return 32'd0;
            case (a)
                12'h000: return {24'd0, (fifo.size() != 0) ? fifo[0] : 8'd0};
                12'h004: return {24'd0, txdata};
                12'h008: return {31'd0, en};
                12'h00C: return {23'd0, 5'(fifo.size()), done, ovr, cs_active(), 1'(fifo.size() != 0)};
                12'hFE0: return {29'd0, irqstat};
                12'hFE4: return {29'd0, irqen};
                12'hFE8: return {30'd0, dmactl};
                default: return SPIS_ID;
            endcase
        endfunction

        // one pclk edge, from the values sampled just before it
        function void step(spis_cycle_item it);
            bit wr, wr_ip, rd_ip, flush, pop, full, rise, fall, active, fnow, load_first, load_next; bit [2:0] bc;
            if (!it.preset_n) begin reset(); return; end
            wr    = it.psel && it.penable && it.pwrite;
            wr_ip = wr && in_ip(it.paddr);
            rd_ip = it.psel && it.penable && !it.pwrite && in_ip(it.paddr);
            flush = wr_ip && it.paddr == 12'h008 && it.pwdata[1];
            full  = (fifo.size() == SPIS_FIFO);
            pop   = rd_ip && it.paddr == 12'h000 && fifo.size() != 0;
            rise  = !sclk_q && sclk_s();
            fall  = sclk_q && !sclk_s();
            fnow  = fall_now();
            active = cs_active(); bc = bitcnt;
            load_first = cs_fall_q;
            load_next  = !cs_fall_q && active && fall && bitcnt == 3'd0;

            // ---- what this cycle is, for the scoreboard and the coverage
            ev_wr = wr && mapped(it.paddr); ev_addr = it.paddr; ev_wdata = it.pwdata;
            ev_push = rx_push; ev_push_full = rx_push && full; ev_rise = cs_rise_q; ev_flush = flush; ev_fall_now = fnow;
            ev_level = fifo.size(); ev_load = load_first || load_next; ev_abort = open && !en;
            ev_evt = {rx_push && full, cs_rise_q, rx_push};
            ev_clr = (wr && it.paddr == 12'hFE0) ? it.pwdata[2:0] : 3'd0;
            ev_tx_wr_mid = tx_wr_mid; ev_tx_wr_edge = tx_wr_edge;

            // ---- the packet records, for the comparison with the agent
            if (cs_rise_q && cur != null) begin ended.push_back(cur); cur = null; end
            if (ev_abort) cur = null;                                // EN cleared in mid-packet: nothing to compare
            if (fnow) begin cur = new(); cur.t_open = $realtime; end
            if (rx_push && cur != null) cur.rx.push_back(rx_byte);
            if (ev_load && cur != null) cur.tx.push_back(txdata);

            // ---- interrupt flags and the two sticky STATUS bits: an event beats its own clear (SPIS-6)
            irqstat = (irqstat & ~ev_clr) | ev_evt;
            if (ev_clr[2]) ovr = 0;
            if (ev_clr[1]) done = 0;
            if (rx_push && full) ovr = 1;
            if (cs_rise_q) done = 1;

            // ---- the FIFO: a flush empties it at once; a full FIFO drops the new byte ([N-7.5])
            if (flush) fifo.delete();
            else begin
                if (rx_push && !full) fifo.push_back(rx_byte);
                if (pop) void'(fifo.pop_front());
            end

            // ---- the transmit shifter: loaded at a packet start and before each further byte ([N-6.2])
            if (load_first)          tx_sh = txdata;
            else if (active && fall) tx_sh = (bitcnt == 3'd0) ? txdata : {tx_sh[6:0], 1'b0};
            if (ev_load) begin tx_wr_mid = 0; tx_wr_edge = 0; end

            // ---- the receive shifter: most significant bit first, on the rising edge ([N-7.2])
            rx_push = 0;
            if (!active) begin bitcnt = 0; rx_sh = 0; end
            else if (rise) begin
                if (bitcnt == 3'd7) begin rx_byte = {rx_sh[6:0], mosi_s()}; rx_push = 1; end
                rx_sh = {rx_sh[6:0], mosi_s()};
                bitcnt = bitcnt + 3'd1;
            end

            // ---- framing ([N-7.3])
            cs_fall_q = fnow;
            cs_rise_q = !cs_n_q && cs_n_s() && en && open;
            if (cs_n_s() || !en) open = 0;
            else if (fnow)       open = 1;

            // ---- register writes
            if (wr_ip) case (it.paddr)
                12'h004: begin
                    txdata = it.pwdata[7:0];
                    if (active && bc != 3'd0) tx_wr_mid = 1; else tx_wr_edge = 1;
                end
                12'h008: en = it.pwdata[0];
                default: ;                                           // RXDATA and STATUS are read-only
            endcase
            if (wr && it.paddr == 12'hFE4) irqen  = it.pwdata[2:0];
            if (wr && it.paddr == 12'hFE8) dmactl = it.pwdata[1:0];
            holdoff = it.dma_ack;

            // ---- the synchroniser
            sclk_q = sclk_s(); cs_n_q = cs_n_s();
            s1 = s0; s0 = {it.cs_n, it.mosi, it.sclk};
        endfunction
    endclass

    // ------------------------------------------------------------------ coverage
    class spis_coverage extends uvm_component;
        `uvm_component_utils(spis_coverage)
        spis_line_state line;

        covergroup cg_spis_apb with function sample(int kind, bit wr);
            option.per_instance = 1;
            cp_reg: coverpoint kind { bins RXDATA = {0}; bins TXDATA = {1}; bins CTRL = {2}; bins STATUS = {3};
                                      bins IRQSTAT = {8}; bins IRQEN = {9}; bins DMACTL = {10}; bins ID = {11}; }
            cp_rw: coverpoint wr { bins read = {0}; bins write = {1}; }
            x_reg_rw: cross cp_reg, cp_rw;
            cp_unmapped: coverpoint kind { bins between_ip_and_tail = {20}; bins unaligned_in_ip = {27}; bins first_past_ip = {21};
                                           bins last_before_tail = {22}; bins above_tail = {23}; bins unaligned_tail = {24};
                                           bins alias_of_ip_register = {25}; bins alias_of_shim_register = {26}; }
            x_unmapped_rw: cross cp_unmapped, cp_rw;
        endgroup

        covergroup cg_spis_tx with function sample(int how);
            option.per_instance = 1;
            cp_update: coverpoint how { bins not_rewritten = {0}; bins rewritten_between_bytes = {1}; bins rewritten_in_mid_byte = {2}; }
        endgroup

        covergroup cg_spis_data with function sample(bit [7:0] b);
            option.per_instance = 1;
            cp_byte: coverpoint b { bins zero = {8'h00}; bins ones = {8'hFF};
                                    bins walking_one[] = {8'h01, 8'h02, 8'h04, 8'h08, 8'h10, 8'h20, 8'h40, 8'h80};
                                    bins walking_zero[] = {8'hFE, 8'hFD, 8'hFB, 8'hF7, 8'hEF, 8'hDF, 8'hBF, 8'h7F};
                                    bins other = default; }
        endgroup

        covergroup cg_spis_rate with function sample(int lo, int hi, int phase);
            option.per_instance = 1;
            cp_halfperiod: coverpoint ((lo < hi) ? lo : hi) iff (phase < 0) {
                bins out_of_spec_2 = {[20:29]}; bins three = {[30:39]}; bins four = {[40:59]}; bins six = {[60:599]}; bins sixty = {[600:$]}; }
            cp_unequal: coverpoint (hi > lo + 9) ? 1 : (lo > hi + 9) ? 2 : 0 iff (phase < 0) { bins high_longer = {1}; bins low_longer = {2}; }
            cp_phase: coverpoint phase iff (phase >= 0) { bins tenth[] = {[0:9]}; }
        endgroup

        covergroup cg_spis_pkt with function sample(int kind, int v);
            option.per_instance = 1;
            cp_len: coverpoint v iff (kind == 0) { bins none = {0}; bins one = {1}; bins two = {2}; bins sixteen = {16}; bins seventeen = {17};
                                                   bins sixty_four = {64}; }
            cp_gap: coverpoint v iff (kind == 1) { bins shortest_legal = {[11:15]}; }
            cp_extra_bits: coverpoint v iff (kind == 2) { bins bits[] = {[1:7]}; }
            cp_en_phase: coverpoint v iff (kind == 3) { bins set_before_packet = {0}; bins set_in_bit[] = {[1:8]}; bins set_between_bytes = {9};
                                                        bins cleared_in_mid_packet = {10}; }
            cp_cs_glitch: coverpoint v iff (kind == 4) { bins low_idle_not_sampled = {0}; bins low_idle_sampled = {1};
                                                         bins high_in_packet_not_sampled = {2}; bins high_in_packet_sampled = {3}; }
            cp_idle_clocks: coverpoint v iff (kind == 5) { bins clocked_while_not_selected = {1}; }
        endgroup

        covergroup cg_spis_fifo with function sample(int kind, int v);
            option.per_instance = 1;
            cp_level: coverpoint v iff (kind == 0) { bins empty = {0}; bins one = {1}; bins one_below_full = {SPIS_FIFO - 1}; bins full = {SPIS_FIFO}; }
            cp_flush_when: coverpoint v iff (kind == 1) { bins empty = {0}; bins full = {1}; bins byte_completes = {2}; bins part_full = {3}; }
            cp_overrun_len: coverpoint v iff (kind == 2) { bins one_byte = {1}; bins several = {[2:$]}; }
        endgroup

        covergroup cg_spis_irq with function sample(int src, bit en, bit clr_same_cycle);
            option.per_instance = 1;
            cp_src: coverpoint src { bins byte_received = {0}; bins packet_complete = {1}; bins overrun = {2}; }
            cp_en: coverpoint en;
            x_src_en_clear: cross cp_src, cp_en;
            cp_clear_in_event_cycle: coverpoint src iff (clr_same_cycle) { bins byte_received = {0}; bins packet_complete = {1}; bins overrun = {2}; }
        endgroup

        covergroup cg_spis_dma with function sample(int kind);
            option.per_instance = 1;
            cp_dma: coverpoint kind { bins request_with_one_byte = {0}; bins request_with_several = {1}; bins acknowledged = {2};
                                      bins disabled_with_data = {3}; }
        endgroup

        int unsigned n_over = 0;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_spis_apb = new(); cg_spis_tx = new(); cg_spis_data = new(); cg_spis_rate = new();
            cg_spis_pkt = new(); cg_spis_fifo = new(); cg_spis_irq = new(); cg_spis_dma = new();
        endfunction

        // pre: the state the cycle started from; m: after the step (its ev_* describe the cycle)
        function void sample_cycle(spis_cycle_item it, spis_ref_model pre, spis_ref_model m);
            if (!it.preset_n) begin n_over = 0; return; end
            for (int s = 0; s < 3; s++) if (m.ev_evt[s]) cg_spis_irq.sample(s, pre.irqen[s], m.ev_clr[s]);
            if (m.ev_push) begin
                cg_spis_data.sample(pre.rx_byte);
                cg_spis_fifo.sample(0, m.ev_level);
                if (m.ev_push_full) n_over++;
                else begin if (n_over != 0) cg_spis_fifo.sample(2, n_over); n_over = 0; end
            end
            if (m.ev_flush) cg_spis_fifo.sample(1, m.ev_push ? 2 : (m.ev_level == 0) ? 0 : (m.ev_level == SPIS_FIFO) ? 1 : 3);
            // a byte other than the first of a packet is loaded: was TXDATA rewritten since the byte before?
            if (m.ev_load && !pre.cs_fall_q) cg_spis_tx.sample(m.ev_tx_wr_mid ? 2 : m.ev_tx_wr_edge ? 1 : 0);
            if (m.ev_wr && m.ev_addr == 12'h008) begin
                if (!pre.en && m.ev_wdata[0]) begin
                    if (!line.in_packet)                                      cg_spis_pkt.sample(3, 0);
                    else if (line.bits_done != 0 && line.bits_done % 8 == 0) cg_spis_pkt.sample(3, 9);
                    else                                                      cg_spis_pkt.sample(3, 1 + line.bits_done % 8);
                end
                if (pre.en && !m.ev_wdata[0] && pre.open) cg_spis_pkt.sample(3, 10);
            end
            if (pre.dma_req(it.dma_ack)) cg_spis_dma.sample((m.ev_level > 1) ? 1 : 0);
            if (it.dma_ack) cg_spis_dma.sample(2);
            if (!pre.dmactl[0] && m.ev_level != 0) cg_spis_dma.sample(3);
        endfunction

        function void sample_pkt(spis_pkt p);
            case (p.kind)
                SPIS_IDLE_CLOCKS: cg_spis_pkt.sample(5, 1);
                SPIS_CS_GLITCH:   cg_spis_pkt.sample(4, p.glitch_seen);
                default: begin
                    if (p.extra == 0 && p.glitch_at == 0) cg_spis_pkt.sample(0, p.data.size());
                    if (p.after_packet) cg_spis_pkt.sample(1, p.gap_seen);
                    if (p.extra != 0) cg_spis_pkt.sample(2, p.extra);
                    if (p.glitch_at != 0) cg_spis_pkt.sample(4, 2 + p.glitch_seen);
                    if (p.data.size() != 0 || p.extra != 0) begin
                        cg_spis_rate.sample(p.lo_t, p.hi_t, -1);
                        for (int i = 0; i < 10; i++) if (p.phase_seen[i]) cg_spis_rate.sample(0, 0, i);
                    end
                end
            endcase
        endfunction

        function void apb_access(apb_item it, bit mapped);
            int kind;
            if (mapped) kind = (it.addr < 12'h010) ? it.addr[3:2] : 8 + it.addr[3:2];
            else if (it.addr[1:0] != 2'b00) kind = (it.addr >= 12'hFE0) ? 24 : ((it.addr < 12'h010) ? 27 : -1);
            else if (it.addr == 12'h010) kind = 21;
            else if (it.addr[11:4] != 0 && $countones(it.addr[11:4]) == 1) kind = 25;          // 0x00-0x0C with one upper bit set
            else if ($countones(~it.addr[11:5]) == 1 && it.addr[4] == 1'b0) kind = 26;         // 0xFE0-0xFEC with one upper bit clear
            else if (it.addr == 12'hFDC) kind = 22;
            else if (it.addr >= 12'hFF0) kind = 23;
            else kind = 20;
            cg_spis_apb.sample(kind, it.write);
        endfunction
    endclass

    // ------------------------------------------------------------------ scoreboard
    `uvm_analysis_imp_decl(_apb)
    `uvm_analysis_imp_decl(_cyc)
    `uvm_analysis_imp_decl(_spi)

    class spis_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(spis_scoreboard)
        uvm_analysis_imp_apb #(apb_item, spis_scoreboard)        apb_imp;
        uvm_analysis_imp_cyc #(spis_cycle_item, spis_scoreboard) cyc_imp;
        uvm_analysis_imp_spi #(spis_pkt, spis_scoreboard)        spi_imp;
        spis_ref_model model, pre;
        spis_coverage  cov;
        spis_pkt       sent[$];                                      // packets the agent finished, not yet matched
        int unsigned n_cyc, n_rd, n_wr, n_err, n_pkt, n_pkt_cmp, n_rx_cmp, n_tx_cmp;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            apb_imp = new("apb_imp", this); cyc_imp = new("cyc_imp", this); spi_imp = new("spi_imp", this);
            pre = spis_ref_model::type_id::create("pre");
        endfunction

        function void err(string id, string msg);
            n_err++;
            if (n_err <= 20) `uvm_error(id, msg)
        endfunction

        // every pclk cycle: the pins and (in the last cycle of an access) the bus response
        // against the model's state in that cycle; then step the model
        function void write_cyc(spis_cycle_item it);
            bit m; bit [31:0] exp;
            n_cyc++;
            if (it.preset_n) begin
                if (it.miso_oe !== model.miso_oe()) err("sb_miso", $sformatf("MISO enable %0b, model %0b (EN %0b, chip select %0b)", it.miso_oe, model.miso_oe(), model.en, model.cs_n_s()));
                if (it.miso    !== model.miso())    err("sb_miso", $sformatf("MISO %0b, model %0b (shifter %02h, bit %0d)", it.miso, model.miso(), model.tx_sh, model.bitcnt));
                if (it.irq     !== model.irq())     err("sb_irq",  $sformatf("irq %0b, model %0b (IRQSTAT=%03b IRQEN=%03b)", it.irq, model.irq(), model.irqstat, model.irqen));
                if (it.dma_req !== model.dma_req(it.dma_ack))
                    err("sb_dma", $sformatf("dma_req %0b, model %0b (DMACTL %02b, %0d bytes held, ack %0b)", it.dma_req, model.dma_req(it.dma_ack), model.dmactl, model.fifo.size(), it.dma_ack));
                if (it.pready !== 1'b1) err("sb_pready", "PREADY low");
            end else begin
                if (it.miso_oe !== 1'b0) err("sb_miso", "MISO driven in reset");
                if (it.irq !== 1'b0)     err("sb_irq", "irq high in reset");
                if (it.dma_req !== 1'b0) err("sb_dma", "dma_req high in reset");
            end
            if (it.preset_n && it.psel && it.penable) begin
                m = model.mapped(it.paddr);
                if (it.pwrite) n_wr++;
                else begin
                    n_rd++;
                    exp = model.rd(it.paddr);
                    if (it.prdata !== exp) begin
                        string id = (it.paddr == 12'h000) ? "sb_rx" : (it.paddr != 12'h00C) ? "sb_reg" :
                                    (it.prdata[8:4] !== exp[8:4] || it.prdata[0] !== exp[0]) ? "sb_fifo" : "sb_status";
                        err(id, $sformatf("read 0x%03h: DUT %08h, model %08h", it.paddr, it.prdata, exp));
                    end
                end
                if (it.pslverr !== !m)
                    err("sb_pslverr", $sformatf("%s 0x%03h: PSLVERR %0b, model %0b", it.pwrite ? "write" : "read", it.paddr, it.pslverr, !m));
            end
            pre.copy_state(model);
            model.step(it);
            cov.sample_cycle(it, pre, model);
            while (model.ended.size() != 0) packet_ended(model.ended.pop_front());
        endfunction

        // A packet ended in the model. If it is one the agent sent within the rates of the
        // specification, the two records must agree byte for byte.
        function void packet_ended(spis_pkt_rec r);
            spis_pkt p = null; realtime now = $realtime;
            n_pkt++;
            // the agent moved chip select at most six pclk before the model saw it: two flops, the
            // edge detector, this report
            while (sent.size() != 0 && sent[0].t_rise < now - 6 * PCLK_NS) void'(sent.pop_front());
            foreach (sent[i])
                if (sent[i].t_rise < now && sent[i].t_fall < r.t_open && sent[i].t_fall > r.t_open - 6 * PCLK_NS) begin
                    p = sent[i]; sent.delete(i); break;
                end
            if (p == null || !p.in_spec()) return;
            n_pkt_cmp++;
            if (r.rx.size() != p.data.size())
                err("sb_rx", $sformatf("the agent sent %0d whole bytes in a packet, the block received %0d (%s)", p.data.size(), r.rx.size(), p.convert2string()));
            else foreach (r.rx[i]) begin
                n_rx_cmp++;
                if (r.rx[i] !== p.data[i]) err("sb_rx", $sformatf("byte %0d of a packet: sent %02h, received %02h (%s)", i, p.data[i], r.rx[i], p.convert2string()));
            end
            foreach (p.miso[i]) if (i < r.tx.size()) begin
                n_tx_cmp++;
                if (p.miso[i] !== r.tx[i]) err("sb_tx", $sformatf("byte %0d of a packet: the agent received %02h, TXDATA was %02h (%s)", i, p.miso[i], r.tx[i], p.convert2string()));
            end else err("sb_tx", $sformatf("byte %0d of a packet was never loaded from TXDATA (%s)", i, p.convert2string()));
        endfunction

        function void write_spi(spis_pkt p);
            cov.sample_pkt(p);
            if (p.kind == SPIS_PACKET) sent.push_back(p);            // the sequences make a new item for every packet
        endfunction

        function void write_apb(apb_item it);
            cov.apb_access(it, model.mapped(it.addr));
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SB", $sformatf("spis_scoreboard: %0d cycles, %0d reads, %0d writes compared; %0d packets seen, %0d compared with the agent (%0d bytes in, %0d bytes out); %0d mismatches",
                                      n_cyc, n_rd, n_wr, n_pkt, n_pkt_cmp, n_rx_cmp, n_tx_cmp, n_err), UVM_NONE)
            if (n_cyc == 0 || (n_rd + n_wr) == 0) `uvm_error("SB", "the scoreboard compared nothing")
        endfunction
    endclass

    // ------------------------------------------------------------------ environment
    class spis_env extends uvm_env;
        `uvm_component_utils(spis_env)
        apb_agent       apb;
        spis_spi_agent  spi;
        spis_monitor    mon;
        spis_scoreboard sb;
        spis_coverage   cov;
        spis            regmodel;
        apb_reg_adapter adapter;
        uvm_reg_predictor #(apb_item) predictor;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            apb = apb_agent::type_id::create("apb", this);
            spi = spis_spi_agent::type_id::create("spi", this);
            mon = spis_monitor::type_id::create("mon", this);
            sb  = spis_scoreboard::type_id::create("sb", this);
            cov = spis_coverage::type_id::create("cov", this);
            sb.model = spis_ref_model::type_id::create("model");
            sb.cov = cov;
            regmodel = new("regmodel");
            regmodel.build();
            regmodel.lock_model();
            regmodel.reset();
            adapter   = apb_reg_adapter::type_id::create("adapter");
            predictor = uvm_reg_predictor #(apb_item)::type_id::create("predictor", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            mon.ap.connect(sb.cyc_imp);
            apb.mon.ap.connect(sb.apb_imp);
            spi.drv.ap.connect(sb.spi_imp);
            cov.line = spi.drv.line;
            regmodel.default_map.set_sequencer(apb.sqr, adapter);
            regmodel.default_map.set_auto_predict(0);
            predictor.map = regmodel.default_map; predictor.adapter = adapter;
            apb.mon.ap.connect(predictor.bus_in);
        endfunction
    endclass

    `include "spis_seq_lib.svh"
    `include "spis_test_lib.svh"
endpackage
