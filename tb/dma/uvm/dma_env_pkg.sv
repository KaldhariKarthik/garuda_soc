`timescale 1ns/1ps
// =============================================================================
// dma_env_pkg.sv - UVM environment for block 9, the DMA controller.
//
// Plan: tb/dma/GARUDA_DMA_vplan.csv. The checks and covergroups below carry
// the names the plan gives them (sb_data, sb_addr, sb_stat, cg_dma_xfer ...).
//
//   dma_ahb_slave    the memory on the DMA's AHB-Lite master port: random wait
//                    states, a two-cycle ERROR for any address in the error
//                    window, and data for every address (unwritten bytes read
//                    as a fixed function of the address)
//   dma_ahb_monitor  every completed AHB transfer, and every address phase
//   dma_side_monitor req, ack, complete and error, once per hclk cycle
//   dma_req_agent    the six peripherals' request lines
//   dma_ref_model    written from GARUDA-DMA-SPEC-001 sections 6 and 7; it
//                    never looks at the RTL. Where the spec is silent or a
//                    ruling is open it follows the RTL and says so: arming a
//                    non-zero transfer clears COMPLETE (DMA-18, the spec calls
//                    it sticky), setting EN again restarts from CNT (DMA-11),
//                    and a request that rises while the channel's own beat is
//                    on the bus is consumed by that beat (DMA-19)
//   dma_scoreboard   sb_data, sb_addr, sb_beats, sb_stat, sb_gstat, sb_reg,
//                    sb_pslverr, sb_req, sb_ack, sb_irq
//   dma_coverage     the plan's covergroups
//
// Planted defects (2026-10-16, Verilator 5.053, one RTL change each, the
// directed test and one random test): 9 of 9 caught by both tests.
//   wrong arbitration priority     a_priority (SVA stops the run first)
//   halfword address step of 4     sb_addr, sb_reg, sb_stat, sb_gstat, sb_irq, sb_ack
//   ICLR keeps ERRPHASE            sb_stat
//   acknowledge one cycle wide     sb_ack, a_ack_width
//   byte read from the wrong lane  sb_data
//   COMPLETE one beat early        a_complete_consistent (SVA stops the run first)
//   taken flag never clears        HANG (channel never finishes), sb_arb
//   ISRAM / ROM check removed      sb_addr, a_no_forbidden
//   GSTAT COMPLETE from ACTIVE     sb_gstat
// Five of the nine are caught by the scoreboard alone.
//
// Timing (dma_if.sv): the DUT moves at the hclk rising edge, the TB 1 ns
// after it, and everything is sampled at the falling edge. The model is
// updated by observed events, so its state runs a few hclk ahead of or behind
// the DUT's registers; every register read and every interrupt level is
// therefore compared with each state the model passed through in a short
// window around the sampling instant (WIN_BEFORE / WIN_AFTER), never with a
// later or an earlier beat than that.
// =============================================================================
package dma_env_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import garuda_apb_pkg::*;
    import dma_reg_pkg::*;

    localparam int NCH = 6;
    // fixed priority, larger is higher (spec 6.3; dma_top PRIO default)
    localparam int PRIO [NCH] = '{5, 3, 1, 2, 4, 0};
    localparam int ACK_CYCLES = 2;
    localparam realtime HCLK = 4.0ns;
    localparam realtime WIN_BEFORE = 12.0ns;
    localparam realtime WIN_AFTER  = 8.0ns;

    typedef enum int {P2M = 0, M2P = 1, M2M = 2} mode_e;

    // the addresses the DMA must refuse without a bus transfer ([N-7.20])
    function automatic bit forbidden(bit [31:0] a); return a[31:28] == 4'h0 || a[31:28] == 4'h1; endfunction
    // the slave answers ERROR here
    function automatic bit err_window(bit [31:0] a); return a[31:20] == 12'h2FF; endfunction
    // data of a byte nobody wrote: a fixed function of its address
    function automatic bit [7:0] init_byte(bit [31:0] a);
        return a[7:0] ^ a[15:8] ^ a[23:16] ^ 8'h5A;
    endfunction
    function automatic int unsigned step_of(bit [1:0] size); return (size == 0) ? 1 : (size == 1) ? 2 : 4; endfunction
    function automatic int cycle_of(realtime t); return int'(t / HCLK); endfunction

    // ======================================================================= AHB slave
    class dma_ahb_slave extends uvm_component;
        `uvm_component_utils(dma_ahb_slave)
        virtual dma_if vif;
        bit [7:0] mem [bit [31:0]];
        int unsigned max_wait = 2;            // +AHB_MAXWAIT=<n>
        int unsigned n_err;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual dma_if)::get(this, "", "dvif", vif))
                `uvm_fatal("NOVIF", "dma_ahb_slave: no virtual interface")
            void'($value$plusargs("AHB_MAXWAIT=%d", max_wait));
        endfunction

        function bit [7:0] rd8(bit [31:0] a); return mem.exists(a) ? mem[a] : init_byte(a); endfunction
        function bit [31:0] rd32(bit [31:0] a);
            bit [31:0] w = {a[31:2], 2'b00};
            return {rd8(w + 3), rd8(w + 2), rd8(w + 1), rd8(w)};
        endfunction

        task run_phase(uvm_phase phase);
            bit dp; bit [31:0] a; bit wr; bit [2:0] sz; int unsigned waits; bit err; int eph;
            bit nrdy, nresp; bit [31:0] nrdata;
            vif.hready = 1'b1; vif.hresp = 1'b0; vif.hrdata = 32'd0;
            dp = 0;
            forever begin
                @(negedge vif.hclk);                       // the values of this cycle
                if (vif.rst_n !== 1'b1) begin
                    dp = 0; nrdy = 1; nresp = 0; nrdata = 32'd0;
                end else begin
                    // a data phase completes in a cycle with HREADY high
                    if (dp && vif.hready === 1'b1) begin
                        if (wr && !err)
                            for (int k = 0; k < (1 << sz); k++)
                                mem[a + k] = vif.hwdata[8 * ((a + k) % 4) +: 8];
                        dp = 0;
                    end
                    // an address phase is accepted in a cycle with HREADY high
                    if (!dp && vif.htrans[1] === 1'b1 && vif.hready === 1'b1) begin
                        dp = 1; a = vif.haddr; wr = vif.hwrite; sz = vif.hsize;
                        waits = $urandom_range(0, max_wait);
                        err = err_window(a); eph = 0;
                        if (err) n_err++;
                    end
                    // the response for the next cycle
                    nrdy = 1; nresp = 0;
                    if (dp) begin
                        if (waits > 0) begin nrdy = 0; waits--; end
                        else if (err) begin nresp = 1; nrdy = (eph == 1); eph++; end
                        else if (!wr) nrdata = rd32(a);
                    end
                end
                @(posedge vif.hclk);
                #1;
                vif.hready = nrdy; vif.hresp = nresp; vif.hrdata = nrdata;
            end
        endtask
    endclass

    // ======================================================================= AHB monitor
    class ahb_xfer extends uvm_sequence_item;
        bit [31:0] addr;
        bit        write;
        bit [2:0]  size;
        bit [31:0] data;          // HRDATA of a read, HWDATA of a write
        bit        err;
        realtime   t_addr, t_done;
        `uvm_object_utils(ahb_xfer)
        function new(string name = "ahb_xfer"); super.new(name); endfunction
        function string convert2string();
            return $sformatf("%s 0x%08h size %0d data %08h%s", write ? "WR" : "RD", addr, size, data, err ? " ERROR" : "");
        endfunction
    endclass

    class dma_ahb_monitor extends uvm_monitor;
        `uvm_component_utils(dma_ahb_monitor)
        virtual dma_if vif;
        uvm_analysis_port #(ahb_xfer) ap_addr;    // an address phase was accepted
        uvm_analysis_port #(ahb_xfer) ap_done;    // the data phase completed
        function new(string name, uvm_component parent);
            super.new(name, parent); ap_addr = new("ap_addr", this); ap_done = new("ap_done", this);
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual dma_if)::get(this, "", "dvif", vif))
                `uvm_fatal("NOVIF", "dma_ahb_monitor: no virtual interface")
        endfunction
        task run_phase(uvm_phase phase);
            ahb_xfer cur;
            forever begin
                @(negedge vif.hclk);
                if (vif.rst_n !== 1'b1) begin cur = null; continue; end
                if (cur != null && vif.hready === 1'b1) begin
                    cur.err = vif.hresp;
                    cur.data = cur.write ? vif.hwdata : vif.hrdata;
                    cur.t_done = $realtime;
                    ap_done.write(cur);
                    cur = null;
                end
                if (cur == null && vif.htrans[1] === 1'b1 && vif.hready === 1'b1) begin
                    cur = ahb_xfer::type_id::create("cur");
                    cur.addr = vif.haddr; cur.write = vif.hwrite; cur.size = vif.hsize;
                    cur.t_addr = $realtime;
                    ap_addr.write(cur);
                end
            end
        endtask
    endclass

    // ======================================================================= sideband monitor
    class side_sample extends uvm_sequence_item;
        bit [5:0] req, ack, complete, error;
        bit       in_reset;
        realtime  t;
        `uvm_object_utils(side_sample)
        function new(string name = "side_sample"); super.new(name); endfunction
    endclass

    class dma_side_monitor extends uvm_monitor;
        `uvm_component_utils(dma_side_monitor)
        virtual dma_if vif;
        uvm_analysis_port #(side_sample) ap;
        function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual dma_if)::get(this, "", "dvif", vif))
                `uvm_fatal("NOVIF", "dma_side_monitor: no virtual interface")
        endfunction
        task run_phase(uvm_phase phase);
            side_sample s;
            forever begin
                @(negedge vif.hclk);
                s = side_sample::type_id::create("s");
                s.in_reset = (vif.rst_n !== 1'b1);
                s.req = vif.req; s.ack = vif.ack; s.complete = vif.complete; s.error = vif.error;
                s.t = $realtime;
                ap.write(s);
            end
        endtask
    endclass

    // ======================================================================= request agent
    // One item: channel ch raises its request n times. Each assertion lasts
    // width pclk cycles, or, with width 0, until the DMA acknowledges it (the
    // way a FIFO-backed peripheral behaves, [N-7.7]); then gap pclk cycles low.
    class req_item extends uvm_sequence_item;
        int unsigned ch, n = 1, width = 0, gap = 1;
        int unsigned max_wait_pclk = 4000;     // give up on an acknowledge after this
        `uvm_object_utils(req_item)
        function new(string name = "req_item"); super.new(name); endfunction
    endclass
    typedef uvm_sequencer #(req_item) req_sequencer;

    class req_driver extends uvm_driver #(req_item);
        `uvm_component_utils(req_driver)
        virtual dma_if vif;
        bit busy [NCH];
        bit abort [NCH];                      // stop the channel's remaining assertions
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual dma_if)::get(this, "", "dvif", vif))
                `uvm_fatal("NOVIF", "req_driver: no virtual interface")
        endfunction
        // peripherals assert and release on a pclk edge ([N-7.9])
        task pclk_edge(); @(posedge vif.pclk); #1; endtask
        task one_channel(req_item it);
            for (int k = 0; k < it.n && !abort[it.ch]; k++) begin
                pclk_edge();
                vif.req[it.ch] = 1'b1;
                if (it.width == 0) begin
                    int unsigned w = 0;
                    while (vif.ack[it.ch] !== 1'b1 && w < it.max_wait_pclk && !abort[it.ch]) begin
                        @(negedge vif.hclk); w++;
                    end
                end else repeat (it.width) pclk_edge();
                pclk_edge();
                vif.req[it.ch] = 1'b0;
                repeat (it.gap) pclk_edge();
            end
            busy[it.ch] = 0;
            abort[it.ch] = 0;
        endtask
        task run_phase(uvm_phase phase);
            vif.req = 6'd0;
            forever begin
                seq_item_port.get_next_item(req);
                while (busy[req.ch]) @(negedge vif.hclk);
                busy[req.ch] = 1;
                begin
                    req_item it = req;
                    fork one_channel(it); join_none
                end
                seq_item_port.item_done();
            end
        endtask
        task wait_idle(int ch); while (busy[ch]) @(negedge vif.hclk); endtask
        task stop(int ch); if (busy[ch]) begin abort[ch] = 1; wait_idle(ch); end endtask
    endclass

    class dma_req_agent extends uvm_agent;
        `uvm_component_utils(dma_req_agent)
        req_sequencer sqr;
        req_driver    drv;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            sqr = req_sequencer::type_id::create("sqr", this);
            drv = req_driver::type_id::create("drv", this);
        endfunction
        function void connect_phase(uvm_phase phase); drv.seq_item_port.connect(sqr.seq_item_export); endfunction
    endclass

    // ======================================================================= reference model
    typedef struct packed {
        bit        en;
        bit [1:0]  mode;
        bit        sinc, dinc;
        bit [1:0]  size;
        bit        iec, iee;
        bit [31:0] sar, dar;
        bit [15:0] cnt, rem;
        bit        comp, err;
        bit [2:0]  errph;
    } chan_t;

    typedef struct {
        realtime t;
        chan_t   c [NCH];
    } snap_t;

    // From GARUDA-DMA-SPEC-001 only: the register map (6), channel operation
    // (7.1), the modes (7.2), errors (7.5) and reachability (7.7).
    class dma_ref_model extends uvm_object;
        `uvm_object_utils(dma_ref_model)
        chan_t c [NCH];
        snap_t hist [$];

        function new(string name = "dma_ref_model"); super.new(name); reset(0); endfunction

        function void reset(realtime t);
            foreach (c[i]) begin c[i] = '0; c[i].size = 2'd2; end
            hist.delete();
            snap(t);
        endfunction

        // keep every state of the last 200 ns
        function void snap(realtime t);
            snap_t s;
            s.t = t; s.c = c;
            hist.push_back(s);
            while (hist.size() > 2 && hist[1].t < t - 200ns) void'(hist.pop_front());
        endfunction

        static function bit active(chan_t x); return x.en && x.rem != 16'd0; endfunction

        // ---- address decode (spec 6) -------------------------------------
        static function bit chan_rgn(bit [11:0] a);
            return a[11:8] == 4'h0 && a[7:5] < NCH && a[1:0] == 2'b00 && a[4:2] <= 3'd5;
        endfunction
        static function bit pslverr(bit [11:0] a, bit wr);
            bit hit = chan_rgn(a) || a == 12'h100;
            return !hit || (wr && (a == 12'h100 || (chan_rgn(a) && a[4:2] == 3'd4)));
        endfunction

        // the value a read of offset a returns in state s
        static function bit [31:0] read_value(chan_t s [NCH], bit [11:0] a);
            chan_t x;
            bit [31:0] g;
            if (a == 12'h100) begin
                g = 32'd0;
                for (int n = 0; n < NCH; n++) begin
                    g[n] = active(s[n]); g[8 + n] = s[n].comp; g[16 + n] = s[n].err;
                end
                return g;
            end
            if (!chan_rgn(a)) return 32'd0;
            x = s[a[7:5]];
            case (a[4:2])
                3'd0: return {23'd0, x.iee, x.iec, x.size, x.dinc, x.sinc, x.mode, x.en};
                3'd1: return x.sar;
                3'd2: return x.dar;
                3'd3: return {16'd0, x.cnt};
                3'd4: return {10'd0, x.errph, x.err, x.comp, active(x), x.rem};
                default: return 32'd0;                       // ICLR reads 0
            endcase
        endfunction

        // ---- software writes ----------------------------------------------
        function void apb_write(bit [11:0] a, bit [31:0] d, realtime t);
            int n;
            if (!chan_rgn(a)) return;
            n = a[7:5];
            case (a[4:2])
                3'd0: begin
                    if (d[2:1] != 2'b11) c[n].mode = d[2:1];         // [N-6.1]
                    c[n].sinc = d[3]; c[n].dinc = d[4];
                    if (d[6:5] != 2'b11) c[n].size = d[6:5];         // F03: SIZE 3 refused like MODE 3
                    c[n].iec = d[7]; c[n].iee = d[8];
                    if (d[0] && !c[n].en) begin                      // [N-7.1] arm: REMAINING from CNT
                        c[n].en = 1'b1; c[n].rem = c[n].cnt;
                        c[n].comp = (c[n].cnt == 16'd0);             // R-6: COMPLETE only with REMAINING 0
                        if (c[n].cnt == 16'd0) begin                 // nothing to move: complete at once
                            snap(t); c[n].en = 1'b0;
                        end
                    end else if (!d[0]) c[n].en = 1'b0;
                end
                3'd1: c[n].sar = d;
                3'd2: c[n].dar = d;
                3'd3: c[n].cnt = d[15:0];
                3'd5: begin
                    if (d[0]) c[n].comp = 1'b0;
                    if (d[1]) begin c[n].err = 1'b0; c[n].errph = 3'd0; end
                end
                default: ;
            endcase
            snap(t);
        endfunction

        // ---- hardware events ------------------------------------------------
        function void beat_done(int n, realtime t);               // [N-7.1], [N-7.3]
            int unsigned st = step_of(c[n].size);
            c[n].rem--;
            if (c[n].sinc) c[n].sar += st;
            if (c[n].dinc) c[n].dar += st;
            if (c[n].rem == 16'd0) begin c[n].comp = 1'b1; c[n].en = 1'b0; end
            snap(t);
        endfunction

        function void beat_error(int n, int phase, realtime t);   // [N-7.13]
            c[n].err = 1'b1; c[n].errph = phase; c[n].en = 1'b0;
            snap(t);
        endfunction

        // ---- the states to compare a sample at time t with -------------------
        function void window(realtime t, ref snap_t out [$]);
            int first = 0;
            out.delete();
            for (int k = 0; k < hist.size(); k++) if (hist[k].t <= t - WIN_BEFORE) first = k;
            for (int k = first; k < hist.size(); k++) if (hist[k].t <= t + WIN_AFTER) out.push_back(hist[k]);
        endfunction
    endclass

    // ======================================================================= coverage
    class dma_coverage extends uvm_component;
        `uvm_component_utils(dma_coverage)

        covergroup cg_dma_cr with function sample(int ch, int mode, int size, bit sinc, bit dinc);
            option.per_instance = 1;
            cp_ch:   coverpoint ch   { bins ch[] = {[0:5]}; }
            cp_mode: coverpoint mode { bins p2m = {0}; bins m2p = {1}; bins m2m = {2}; }
            cp_size: coverpoint size { bins b = {0}; bins h = {1}; bins w = {2}; }
            cp_sinc: coverpoint sinc;
            cp_dinc: coverpoint dinc;
            x_fields: cross cp_mode, cp_size, cp_sinc, cp_dinc, cp_ch;
        endgroup

        covergroup cg_dma_cr3 with function sample(int field_kind, bit en);
            option.per_instance = 1;
            cp_field: coverpoint field_kind { bins mode3 = {0}; bins size3 = {1}; }
            cp_en:    coverpoint en;
            cp_size3: cross cp_field, cp_en;
        endgroup

        covergroup cg_dma_cnt with function sample(int cnt);
            option.per_instance = 1;
            cp_cnt: coverpoint cnt { bins zero = {0}; bins one = {1}; bins two = {2};
                                     bins mid = {[3:65534]}; bins max = {65535}; }
        endgroup

        covergroup cg_dma_iclr with function sample(int which, bit flag_set);
            option.per_instance = 1;
            cp_bit:  coverpoint which { bins complete = {0}; bins error = {1}; }
            cp_when: coverpoint flag_set { bins flag_clear = {0}; bins flag_set = {1}; }
            x_bit_when: cross cp_bit, cp_when;
        endgroup

        covergroup cg_dma_apb with function sample(int kind, bit wr);
            option.per_instance = 1;
            cp_kind: coverpoint kind { bins cr = {0}; bins sar = {1}; bins dar = {2}; bins cnt = {3};
                                       bins stat = {4}; bins iclr = {5}; bins gstat = {6};
                                       bins ch6_7 = {10}; bins gap = {11}; bins high = {12}; bins unaligned = {13}; }
            cp_rw: coverpoint wr;
            x_unmapped_rw: cross cp_kind, cp_rw;
        endgroup

        covergroup cg_dma_live with function sample(int kind);
            option.per_instance = 1;
            cp_write_while_active: coverpoint kind { bins sar = {1}; bins dar = {2}; bins cnt = {3}; }
            cp_stop_phase: coverpoint kind { bins between_beats = {10}; bins in_read = {11}; bins in_write = {12}; }
        endgroup

        covergroup cg_dma_xfer with function sample(int mode, int size, int ch, int soff, int doff);
            option.per_instance = 1;
            cp_mode: coverpoint mode { bins p2m = {0}; bins m2p = {1}; bins m2m = {2}; }
            cp_size: coverpoint size { bins b = {0}; bins h = {1}; bins w = {2}; }
            cp_ch:   coverpoint ch   { bins ch[] = {[0:5]}; }
            x_mode_size_ch: cross cp_mode, cp_size, cp_ch;
            cp_soff: coverpoint soff { bins o[] = {[0:3]}; }
            cp_doff: coverpoint doff { bins o[] = {[0:3]}; }
            x_size_offset: cross cp_size, cp_soff, cp_doff {
                ignore_bins half_odd = binsof(cp_size) intersect {1} && (binsof(cp_soff) intersect {1, 3} || binsof(cp_doff) intersect {1, 3});
                ignore_bins word_off = binsof(cp_size) intersect {2} && (binsof(cp_soff) intersect {[1:3]} || binsof(cp_doff) intersect {[1:3]});
            }
        endgroup

        covergroup cg_dma_req with function sample(int kind, int width);
            option.per_instance = 1;
            cp_req_width: coverpoint width iff (kind == 0) { bins one_pclk = {2}; bins few = {[3:8]}; bins held = {[9:$]}; }
            cp_withdrawn: coverpoint kind { bins withdrawn = {1}; }
            cp_req_vs_en: coverpoint kind { bins req_while_disabled = {2}; }
        endgroup

        covergroup cg_dma_arb with function sample(int pair, int nwait, int starved);
            option.per_instance = 1;
            cp_pair: coverpoint pair { bins p[] = {[0:14]}; }
            cp_many: coverpoint nwait { bins two = {2}; bins three_plus = {[3:6]}; }
            cp_starved_cycles: coverpoint starved { bins one = {1}; bins ten = {[2:10]}; bins hundred = {[11:$]}; }
        endgroup

        covergroup cg_dma_err with function sample(int phase, int mode, int pos, int ch);
            option.per_instance = 1;
            cp_phase: coverpoint phase { bins read = {1}; bins write = {2}; }
            cp_mode:  coverpoint mode  { bins p2m = {0}; bins m2p = {1}; bins m2m = {2}; }
            cp_pos:   coverpoint pos   { bins first = {0}; bins middle = {1}; bins last = {2}; }
            x_phase_mode_beat: cross cp_phase, cp_mode, cp_pos;
            cp_error_ch: coverpoint ch { bins ch[] = {[0:5]}; }
        endgroup

        covergroup cg_dma_irq with function sample(int ch, int kind, int ie);
            option.per_instance = 1;
            cp_ch:   coverpoint ch { bins ch[] = {[0:5]}; }
            cp_kind: coverpoint kind { bins complete = {0}; bins error = {1}; }
            cp_ie:   coverpoint ie { bins off = {0}; bins on = {1}; bins set_after = {2}; }
            x_ch_kind_ie: cross cp_ch, cp_kind, cp_ie;
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_dma_cr = new(); cg_dma_cr3 = new(); cg_dma_cnt = new(); cg_dma_iclr = new();
            cg_dma_apb = new(); cg_dma_live = new(); cg_dma_xfer = new(); cg_dma_req = new();
            cg_dma_arb = new(); cg_dma_err = new(); cg_dma_irq = new();
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("COV", $sformatf({"cg_dma_cr %0.1f%%, cg_dma_cr3 %0.1f%%, cg_dma_cnt %0.1f%%, cg_dma_iclr %0.1f%%, ",
                "cg_dma_apb %0.1f%%, cg_dma_live %0.1f%%, cg_dma_xfer %0.1f%%, cg_dma_req %0.1f%%, ",
                "cg_dma_arb %0.1f%%, cg_dma_err %0.1f%%, cg_dma_irq %0.1f%%"},
                cg_dma_cr.get_inst_coverage(), cg_dma_cr3.get_inst_coverage(), cg_dma_cnt.get_inst_coverage(),
                cg_dma_iclr.get_inst_coverage(), cg_dma_apb.get_inst_coverage(), cg_dma_live.get_inst_coverage(),
                cg_dma_xfer.get_inst_coverage(), cg_dma_req.get_inst_coverage(), cg_dma_arb.get_inst_coverage(),
                cg_dma_err.get_inst_coverage(), cg_dma_irq.get_inst_coverage()), UVM_NONE)
        endfunction
    endclass

    // ======================================================================= scoreboard
    `uvm_analysis_imp_decl(_apb)
    `uvm_analysis_imp_decl(_xaddr)
    `uvm_analysis_imp_decl(_xdone)
    `uvm_analysis_imp_decl(_side)

    class dma_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(dma_scoreboard)
        uvm_analysis_imp_apb   #(apb_item, dma_scoreboard)    apb_imp;
        uvm_analysis_imp_xaddr #(ahb_xfer, dma_scoreboard)    xaddr_imp;
        uvm_analysis_imp_xdone #(ahb_xfer, dma_scoreboard)    xdone_imp;
        uvm_analysis_imp_side  #(side_sample, dma_scoreboard) side_imp;
        dma_ref_model model;
        dma_coverage  cov;

        // the beat in flight: its channel and the source lanes it read
        int        fl_ch = -1;
        bit [31:0] fl_src;
        bit [1:0]  fl_soff;
        int        fl_pos;                    // 0 first, 1 middle, 2 last beat (coverage)
        // sb_req: request assertions and the beats they produced
        int unsigned req_id [NCH], beat_req_id [NCH];
        bit [5:0]  prev_req, prev_err_line, prev_comp_line;
        int unsigned req_len [NCH];
        bit        beat_in_assert [NCH];
        // sb_ack: the cycles in which ack[n] must be high
        int        ack_due [NCH][$];
        // sb_irq: interrupt-enable written after its flag (coverage)
        // arbitration: cycles each channel has been waiting
        int unsigned wait_beats [NCH];
        int unsigned n_beats [NCH];
        // when each channel last became able to ask for a beat: armed (M2M) or
        // its request rose (P2M, M2P). The DMA grants about two cycles before
        // the address phase appears, so only a channel that has been waiting
        // longer than that can have been passed over (sb_arb).
        realtime since_arm [NCH], since_req [NCH];
        // A beat consumes the request that is high in the cycle after it completes
        // (the channel's taken flag). An assertion that rises while the channel's
        // own previous beat is still on the bus is therefore consumed by that beat
        // and never gets one of its own. A compliant peripheral holds its request
        // until the beat is taken ([N-7.7]) and never does this; the specification
        // does not say what happens if one does (Docs/bugs/track_a.md DMA-19).
        int take_cyc [NCH];
        int unsigned n_absorbed;
        int unsigned n_reads, n_writes, n_regrd, n_regwr, n_side, n_err, n_beat_err;
        bit [5:0] cur_req;
        bit in_reset = 1;
        // sb_irq compares each sample once the model has had WIN_AFTER to catch
        // up: an ICLR or IE write reaches the DUT at its hclk strobe, the model
        // only when the APB access ends
        side_sample irq_q [$];

        function new(string name, uvm_component parent);
            super.new(name, parent);
            foreach (take_cyc[n]) take_cyc[n] = -1;
            apb_imp = new("apb_imp", this); xaddr_imp = new("xaddr_imp", this);
            xdone_imp = new("xdone_imp", this); side_imp = new("side_imp", this);
        endfunction

        function void fail(string id, string msg); n_err++; `uvm_error(id, msg) endfunction

        // which channel's beat is this read? the one whose SAR it is, among the
        // channels that still have beats to move; on a tie the higher priority
        function int owner(bit [31:0] a, bit [2:0] sz);
            int best = -1;
            for (int n = 0; n < NCH; n++)
                if (model.c[n].rem != 0 && model.c[n].sar == a && {1'b0, model.c[n].size} == sz &&
                    (best < 0 || model.c[n].en > model.c[best].en ||
                     (model.c[n].en == model.c[best].en && PRIO[n] > PRIO[best]))) best = n;
            return best;
        endfunction

        // ---- AHB address phases: sb_addr, sb_req, arbitration coverage ---------
        function void write_xaddr(ahb_xfer x);
            int n, nw, pair; bit [NCH-1:0] waiting;
            if (forbidden(x.addr)) fail("sb_addr", $sformatf("transfer to ISRAM / Boot ROM: %s", x.convert2string()));
            if (x.write) begin
                if (fl_ch < 0) fail("sb_addr", $sformatf("write with no read before it: %s", x.convert2string()));
                return;
            end
            if (fl_ch >= 0) fail("sb_addr", $sformatf("read while the beat of channel %0d is in flight: %s", fl_ch, x.convert2string()));
            n = owner(x.addr, x.size);
            if (n < 0) begin
                fail("sb_addr", $sformatf("read at an address no channel's SAR holds: %s", x.convert2string()));
                return;
            end
            fl_ch = n; fl_pos = (model.c[n].rem == model.c[n].cnt) ? 0 : (model.c[n].rem == 1) ? 2 : 1;
            // sb_req: a peripheral channel needs an assertion that has not had its beat
            if (model.c[n].mode != M2M) begin
                if (req_id[n] == beat_req_id[n])
                    fail("sb_req", $sformatf("channel %0d: a beat with no new request assertion ([N-7.10])", n));
                beat_req_id[n] = req_id[n];
                beat_in_assert[n] = 1;
            end
            // arbitration: who else was waiting for this beat
            waiting = 0;
            for (int k = 0; k < NCH; k++)
                if (dma_ref_model::active(model.c[k]) && !forbidden(model.c[k].sar) &&
                    (model.c[k].mode == M2M || (cur_req[k] && req_id[k] != beat_req_id[k]) || k == n))
                    waiting[k] = 1;
            nw = $countones(waiting);
            for (int i = 0; i < NCH; i++) for (int j = i + 1; j < NCH; j++)
                if (waiting[i] && waiting[j]) begin
                    pair = i * (11 - i) / 2 + (j - i - 1);
                    cov.cg_dma_arb.sample(pair, nw, 0);
                end
            for (int k = 0; k < NCH; k++) begin
                if (k == n) begin
                    if (wait_beats[k] > 0) cov.cg_dma_arb.sample(-1, 0, wait_beats[k]);
                    wait_beats[k] = 0;
                end else if (waiting[k]) begin
                    realtime since = (model.c[k].mode == M2M) ? since_arm[k] : since_req[k];
                    wait_beats[k]++;
                    if (PRIO[k] > PRIO[n] && x.t_addr - since >= 4 * HCLK)
                        fail("sb_arb", $sformatf("channel %0d (mode %0d) granted while channel %0d of higher priority waited: mode %0d, waiting %0t, en %0b rem %0d sar %08h, req %0b id %0d/%0d",
                                                 n, model.c[n].mode, k, model.c[k].mode, x.t_addr - since, model.c[k].en, model.c[k].rem,
                                                 model.c[k].sar, cur_req[k], req_id[k], beat_req_id[k]));
                end
            end
        endfunction

        // ---- AHB data phases: sb_data, sb_beats ---------------------------------
        function void write_xdone(ahb_xfer x);
            int n = fl_ch;
            chan_t s;
            bit [31:0] want, got;
            if (n < 0) return;                                    // already reported
            s = model.c[n];
            if (!x.write) begin
                n_reads++;
                if (x.err) begin                                  // [N-7.13] read failed
                    n_beat_err++;
                    model.beat_error(n, 1, x.t_done);
                    cov.cg_dma_err.sample(1, s.mode, fl_pos, n);
                    fl_ch = -1;
                    return;
                end
                fl_src = x.data; fl_soff = x.addr[1:0];
                if (forbidden(s.dar)) begin                       // [N-7.20] the write is refused
                    n_beat_err++;
                    model.beat_error(n, 2, x.t_done);
                    cov.cg_dma_err.sample(2, s.mode, fl_pos, n);
                    fl_ch = -1;
                end
                return;
            end
            n_writes++;
            if (x.addr != s.dar || x.size != {1'b0, s.size})
                fail("sb_addr", $sformatf("channel %0d wrote %s, model expects 0x%08h size %0d",
                                          n, x.convert2string(), s.dar, s.size));
            if (x.err) begin                                      // [N-7.13] write failed
                n_beat_err++;
                model.beat_error(n, 2, x.t_done);
                cov.cg_dma_err.sample(2, s.mode, fl_pos, n);
                fl_ch = -1;
                return;
            end
            // sb_data: the destination lanes hold the source lanes ([N-7.2], F17)
            case (s.size)
                2'd0: begin want = (fl_src >> (8 * fl_soff)) & 32'hFF;   got = (x.data >> (8 * x.addr[1:0])) & 32'hFF; end
                2'd1: begin want = (fl_src >> (8 * fl_soff)) & 32'hFFFF; got = (x.data >> (8 * x.addr[1:0])) & 32'hFFFF; end
                default: begin want = fl_src; got = x.data; end
            endcase
            if (got !== want)
                fail("sb_data", $sformatf("channel %0d beat %0d: wrote %0h, the source held %0h (%s)",
                                          n, n_beats[n], got, want, x.convert2string()));
            cov.cg_dma_xfer.sample(s.mode, s.size, n, fl_soff, x.addr[1:0]);
            n_beats[n]++;
            model.beat_done(n, x.t_done);
            // sb_ack: ack[n] high in the ACK_CYCLES cycles after this one ([N-7.8], D-16)
            for (int k = 1; k <= ACK_CYCLES; k++) ack_due[n].push_back(cycle_of(x.t_done) + k);
            take_cyc[n] = cycle_of(x.t_done) + 1;
            fl_ch = -1;
        endfunction

        // ---- APB accesses: sb_reg, sb_stat, sb_gstat, sb_pslverr ----------------
        function int kind_of(bit [11:0] a);
            if (a == 12'h100) return 6;
            if (dma_ref_model::chan_rgn(a)) return a[4:2];
            if (a[1:0] != 2'b00) return 13;
            if (a[11:8] == 4'h0 && a[7:5] >= NCH) return 10;
            if (a[11:8] == 4'h0) return 11;
            return 12;
        endfunction

        function void write_apb(apb_item it);
            bit exp_err = dma_ref_model::pslverr(it.addr, it.write);
            int k = kind_of(it.addr);
            int n = it.addr[7:5];
            realtime tc = $realtime - 8ns;        // PRDATA is captured at the SETUP->ACCESS edge
            cov.cg_dma_apb.sample(k, it.write);
            if (it.slverr !== exp_err)
                fail("sb_pslverr", $sformatf("%s 0x%03h: PSLVERR %0b, model %0b", it.write ? "write" : "read",
                                             it.addr, it.slverr, exp_err));
            if (it.waits != 0) fail("sb_pready", $sformatf("access to 0x%03h waited %0d pclk (R-3)", it.addr, it.waits));
            if (it.write) begin
                n_regwr++;
                if (k <= 5) begin
                    chan_t s = model.c[n];
                    if (dma_ref_model::active(s) && k >= 1 && k <= 3) cov.cg_dma_live.sample(k);
                    if (k == 0) begin
                        if (it.wdata[2:1] == 2'b11) cov.cg_dma_cr3.sample(0, it.wdata[0]);
                        if (it.wdata[6:5] == 2'b11) cov.cg_dma_cr3.sample(1, it.wdata[0]);
                        if (it.wdata[0] && !s.en) begin
                            since_arm[n] = $realtime;
                            cov.cg_dma_cnt.sample(s.cnt);
                            cov.cg_dma_cr.sample(n, it.wdata[2:1] == 2'b11 ? s.mode : it.wdata[2:1],
                                                 it.wdata[6:5] == 2'b11 ? s.size : it.wdata[6:5], it.wdata[3], it.wdata[4]);
                        end
                        if (!it.wdata[0] && dma_ref_model::active(s))
                            cov.cg_dma_live.sample(fl_ch == n ? 11 : 10);
                        if (it.wdata[7] && !s.iec && s.comp) cov.cg_dma_irq.sample(n, 0, 2);
                        if (it.wdata[8] && !s.iee && s.err)  cov.cg_dma_irq.sample(n, 1, 2);
                    end
                    if (k == 5) begin
                        if (it.wdata[0]) cov.cg_dma_iclr.sample(0, s.comp);
                        if (it.wdata[1]) cov.cg_dma_iclr.sample(1, s.err);
                    end
                end
                model.apb_write(it.addr, it.wdata, $realtime);
                return;
            end
            n_regrd++;
            begin
                snap_t w [$];
                bit [31:0] e;
                bit ok = 0;
                string seen = "";
                // a channel whose SAR the DMA refuses errors with no bus transfer:
                // the model learns when from the first status that shows it
                if (k == 4 && it.rdata[18] && it.rdata[21:19] == 3'd1 && !model.c[n].err &&
                    dma_ref_model::active(model.c[n]) && forbidden(model.c[n].sar)) begin
                    n_beat_err++;
                    model.beat_error(n, 1, tc);
                    cov.cg_dma_err.sample(1, model.c[n].mode, 0, n);
                end
                if (k == 6)
                    for (int m = 0; m < NCH; m++)
                        if (it.rdata[16 + m] && !model.c[m].err && dma_ref_model::active(model.c[m]) && forbidden(model.c[m].sar)) begin
                            n_beat_err++;
                            model.beat_error(m, 1, tc);
                            cov.cg_dma_err.sample(1, model.c[m].mode, 0, m);
                        end
                model.window(tc, w);
                foreach (w[i]) begin
                    e = dma_ref_model::read_value(w[i].c, it.addr);
                    if (it.rdata === e) ok = 1;
                    seen = {seen, $sformatf(" %08h", e)};
                end
                if (!ok) fail(k == 4 ? "sb_stat" : k == 6 ? "sb_gstat" : "sb_reg",
                              $sformatf("read 0x%03h at %0t: DUT %08h, model in the window:%s", it.addr, tc, it.rdata, seen));
            end
        endfunction

        // ---- sideband, every cycle: sb_ack, sb_irq, request bookkeeping -------------
        function void write_side(side_sample s);
            int cyc = cycle_of(s.t);
            snap_t w [$];
            n_side++;
            if (s.in_reset) begin
                in_reset = 1;
                model.reset(s.t);
                foreach (ack_due[n]) ack_due[n].delete();
                fl_ch = -1; prev_req = 0; cur_req = 0;
                irq_q.delete();
                return;
            end
            in_reset = 0;
            cur_req = s.req;
            for (int n = 0; n < NCH; n++) begin
                bit due = 0;
                // requests: rise, fall, width, withdrawn
                if (s.req[n] && !prev_req[n]) begin
                    req_id[n]++; req_len[n] = 0; beat_in_assert[n] = 0; since_req[n] = s.t;
                    if (!dma_ref_model::active(model.c[n])) cov.cg_dma_req.sample(2, 0);
                end
                if (s.req[n]) req_len[n]++;
                if (take_cyc[n] == cyc) begin
                    if (s.req[n] && req_id[n] != beat_req_id[n]) n_absorbed++;
                    if (s.req[n]) beat_req_id[n] = req_id[n];
                    take_cyc[n] = -1;
                end
                if (!s.req[n] && prev_req[n]) begin
                    cov.cg_dma_req.sample(0, req_len[n]);
                    if (!beat_in_assert[n] && dma_ref_model::active(model.c[n]) && model.c[n].mode != M2M)
                        cov.cg_dma_req.sample(1, 0);
                end
                // sb_ack
                while (ack_due[n].size() > 0 && ack_due[n][0] < cyc) void'(ack_due[n].pop_front());
                if (ack_due[n].size() > 0 && ack_due[n][0] == cyc) due = 1;
                if (s.ack[n] !== due)
                    fail("sb_ack", $sformatf("channel %0d cycle %0d: ack %0b, expected %0b", n, cyc, s.ack[n], due));
            end
            prev_req = s.req;
            // a refused SAR, seen first on the error interrupt
            for (int n = 0; n < NCH; n++)
                if (s.error[n] && !prev_err_line[n] && !model.c[n].err && dma_ref_model::active(model.c[n]) &&
                    forbidden(model.c[n].sar)) begin
                    n_beat_err++;
                    model.beat_error(n, 1, s.t);
                    cov.cg_dma_err.sample(1, model.c[n].mode, 0, n);
                end
            // sb_irq: complete = COMPLETE & IE_COMP, error = ERROR & IE_ERR ([N-7.4]),
            // judged WIN_AFTER later
            irq_q.push_back(s);
            while (irq_q.size() > 0 && irq_q[0].t <= s.t - WIN_AFTER - HCLK) check_irq(irq_q.pop_front());
        endfunction

        function void check_irq(side_sample s);
            snap_t w [$];
            model.window(s.t, w);
            for (int n = 0; n < NCH; n++) begin
                bit okc = 0, oke = 0;
                foreach (w[i]) begin
                    if (s.complete[n] === (w[i].c[n].comp & w[i].c[n].iec)) okc = 1;
                    if (s.error[n]    === (w[i].c[n].err  & w[i].c[n].iee)) oke = 1;
                end
                if (!okc) fail("sb_irq", $sformatf("channel %0d: complete interrupt %0b at %0t, not in the model's window",
                                                   n, s.complete[n], s.t));
                if (!oke) fail("sb_irq", $sformatf("channel %0d: error interrupt %0b at %0t, not in the model's window",
                                                   n, s.error[n], s.t));
                if (s.complete[n] && !prev_comp_line[n]) cov.cg_dma_irq.sample(n, 0, 1);
                if (s.error[n] && !prev_err_line[n])     cov.cg_dma_irq.sample(n, 1, 1);
                if (model.c[n].comp && !model.c[n].iec && !s.complete[n]) cov.cg_dma_irq.sample(n, 0, 0);
                if (model.c[n].err && !model.c[n].iee && !s.error[n])     cov.cg_dma_irq.sample(n, 1, 0);
            end
            prev_err_line = s.error; prev_comp_line = s.complete;
        endfunction

        function void report_phase(uvm_phase phase);
            int unsigned tot = 0;
            foreach (n_beats[n]) tot += n_beats[n];
            `uvm_info("SB", $sformatf({"dma_scoreboard: %0d beats (per channel %0d %0d %0d %0d %0d %0d), %0d failed beats, ",
                                       "%0d AHB reads, %0d AHB writes, %0d register reads, %0d register writes, ",
                                       "%0d sideband cycles compared; %0d mismatches; %0d request assertions taken by the beat before them"},
                                      tot, n_beats[0], n_beats[1], n_beats[2], n_beats[3], n_beats[4], n_beats[5],
                                      n_beat_err, n_reads, n_writes, n_regrd, n_regwr, n_side, n_err, n_absorbed), UVM_NONE)
            if (n_regrd == 0 || n_side == 0) `uvm_error("SB", "the scoreboard compared nothing")
            if (fl_ch >= 0) `uvm_error("sb_beats", $sformatf("the beat of channel %0d never finished", fl_ch))
        endfunction
    endclass

    // ======================================================================= environment
    class dma_env extends uvm_env;
        `uvm_component_utils(dma_env)
        apb_agent        apb;
        dma_ahb_slave    slave;
        dma_ahb_monitor  amon;
        dma_side_monitor smon;
        dma_req_agent    reqs;
        dma_scoreboard   sb;
        dma_coverage     cov;
        dma_ref_model    model;
        dma              regmodel;
        apb_reg_adapter  adapter;
        uvm_reg_predictor #(apb_item) predictor;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            apb   = apb_agent::type_id::create("apb", this);
            slave = dma_ahb_slave::type_id::create("slave", this);
            amon  = dma_ahb_monitor::type_id::create("amon", this);
            smon  = dma_side_monitor::type_id::create("smon", this);
            reqs  = dma_req_agent::type_id::create("reqs", this);
            sb    = dma_scoreboard::type_id::create("sb", this);
            cov   = dma_coverage::type_id::create("cov", this);
            model = dma_ref_model::type_id::create("model");
            sb.model = model; sb.cov = cov;
            regmodel = new("regmodel");
            regmodel.build();
            regmodel.lock_model();
            regmodel.reset();
            adapter   = apb_reg_adapter::type_id::create("adapter");
            predictor = uvm_reg_predictor #(apb_item)::type_id::create("predictor", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            apb.mon.ap.connect(sb.apb_imp);
            amon.ap_addr.connect(sb.xaddr_imp);
            amon.ap_done.connect(sb.xdone_imp);
            smon.ap.connect(sb.side_imp);
            regmodel.default_map.set_sequencer(apb.sqr, adapter);
            regmodel.default_map.set_auto_predict(0);
            predictor.map     = regmodel.default_map;
            predictor.adapter = adapter;
            apb.mon.ap.connect(predictor.bus_in);
        endfunction
    endclass

    `include "dma_seq_lib.svh"
    `include "dma_test_lib.svh"
endpackage
