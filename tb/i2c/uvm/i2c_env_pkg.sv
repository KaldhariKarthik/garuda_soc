`timescale 1ns/1ps
// =============================================================================
// i2c_env_pkg.sv - UVM environment for block 15, the I2C master.
//
// Plan: tb/i2c/GARUDA_I2C_vplan.csv. Names of checks and covergroups are the
// names in the plan.
//
//   i2c_bus_monitor  reads the two lines only: START, STOP, each byte with its
//                    acknowledge bit, and the shortest SCL period of each byte
//   i2c_slave        a slave on the bus: answers one address, acknowledges or
//                    refuses, returns bytes, and holds SCL low (clock stretching)
//                    after the address, after a byte or in the middle of one
//   i2c_other        what else can happen on the lines: a second master that
//                    wins arbitration or makes its own START and STOP, and spikes
//   i2c_monitor      one item per pclk cycle: reset and the APB pins
//   i2c_scoreboard   the registers that firmware alone changes, on every read
//                    (sb_reg); every bus event against the command that caused
//                    it (sb_bus); the byte read against the byte the slave sent
//                    (sb_rx); STATUS and IRQSTAT (sb_status); PSLVERR
//                    (sb_pslverr); the SCL period (sb_scl_period)
//   i2c_coverage     the plan's covergroups
//
// The bit and byte controllers are vendored and are not modelled cycle by cycle:
// the scoreboard knows what each command must put on the bus and in the
// registers, and allows each status bit a bounded time to change (the bit time
// and the input filter both depend on PRESCALE). Relations that hold in every
// cycle are properties, in rtl/i2c/garuda_i2c_sva.sv.
// =============================================================================
package i2c_env_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import garuda_apb_pkg::*;
    import i2c_reg_pkg::*;

    localparam bit [31:0] I2C_ID   = 32'h6A5D_0F01;
    localparam real       TENTH_NS = 0.8;                   // a tenth of the 8 ns pclk period
    localparam real       PCLK_NS  = 8.0;

    // ------------------------------------------------------------------ the bus
    typedef enum { I2C_START, I2C_STOP, I2C_BYTE } i2c_ev_e;

    class i2c_bus_ev extends uvm_sequence_item;
        i2c_ev_e  kind;
        bit [7:0] data;
        bit       nack;            // the ninth bit: 1 = not acknowledged
        realtime  min_period;      // shortest time between two rising edges of SCL in the byte
        bit       stretched;       // the slave held SCL low somewhere in the byte
        realtime  rises[$];        // when SCL rose, for a message
        `uvm_object_utils(i2c_bus_ev)
        function new(string name = "i2c_bus_ev"); super.new(name); endfunction
        function string convert2string();
            return (kind == I2C_BYTE) ? $sformatf("BYTE %02h %s", data, nack ? "NACK" : "ACK") : kind.name();
        endfunction
    endclass

    // where the bus is, shared by the agent's parts, the tests and the coverage
    class i2c_line_state;
        bit in_xfer;               // between a START and a STOP
        int bit_no;                // rising edges of SCL since the last START
        bit stretched;             // the slave stretched in the byte in progress
        bit spike;                 // an injected spike is on a line: not bus activity
        int n_start, n_stop;
    endclass

    class i2c_bus_monitor extends uvm_monitor;
        `uvm_component_utils(i2c_bus_monitor)
        virtual i2c_if vif;
        i2c_line_state line;
        uvm_analysis_port #(i2c_bus_ev) ap;
        realtime last_rises[$];
        function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual i2c_if)::get(this, "", "ivif", vif)) `uvm_fatal("NOVIF", "i2c_bus_monitor: no virtual interface")
        endfunction
        function void emit(i2c_ev_e k, bit [7:0] d = 0, bit nack = 0, realtime mp = 0, bit st = 0);
            i2c_bus_ev e = i2c_bus_ev::type_id::create("e");
            e.kind = k; e.data = d; e.nack = nack; e.min_period = mp; e.stretched = st; e.rises = last_rises;
            ap.write(e);
        endfunction
        task run_phase(uvm_phase phase);
            bit pscl, psda, scl, sda; int nb = 0; bit [8:0] sh; realtime t_rise = 0, mp = 0; realtime rs[$];
            pscl = vif.scl; psda = vif.sda;
            forever begin
                @(vif.scl or vif.sda);
                #0.01;                                                 // both lines may move in the same pclk: read them once they have
                if (line.spike) continue;
                scl = vif.scl; sda = vif.sda;
                if (pscl && scl && psda && !sda) begin
                    rs.delete(); emit(I2C_START); line.in_xfer = 1; line.bit_no = 0; line.stretched = 0; line.n_start++; nb = 0; mp = 0;
                end else if (pscl && scl && !psda && sda) begin
                    emit(I2C_STOP); line.in_xfer = 0; line.n_stop++; nb = 0;
                end else if (!pscl && scl && line.in_xfer) begin
                    sh = {sh[7:0], sda}; nb++; line.bit_no++;
                    if (nb > 1 && (mp == 0 || $realtime - t_rise < mp)) mp = $realtime - t_rise;
                    t_rise = $realtime; rs.push_back(t_rise);
                    if (nb == 9) begin last_rises = rs; rs.delete(); emit(I2C_BYTE, sh[8:1], sh[0], mp, line.stretched); nb = 0; mp = 0; line.stretched = 0; end
                end
                pscl = scl; psda = sda;
            end
        endtask
    endclass

    // ------------------------------------------------------------------ the slave
    class i2c_slave_cfg extends uvm_object;
        bit [6:0]    addr = 7'h50;
        bit          present = 1;        // answers its address
        int          nack_data_at = -1;  // refuses the n-th byte written to it in a transfer (0 = the first)
        bit [7:0]    rd_q[$];            // the bytes it returns; random when empty
        int unsigned stretch_addr = 0;   // SCL held low after the address byte, in tenths of a pclk
        int unsigned stretch_data = 0;   // after a data byte
        int unsigned stretch_mid  = 0;   // after the fourth bit of every byte
        // what it saw and did, for the scoreboard and the tests
        bit [7:0]    wr_seen[$], rd_sent[$];
        `uvm_object_utils(i2c_slave_cfg)
        function new(string name = "i2c_slave_cfg"); super.new(name); endfunction
        function void plain(); present = 1; nack_data_at = -1; stretch_addr = 0; stretch_data = 0; stretch_mid = 0; rd_q.delete(); endfunction
    endclass

    class i2c_slave extends uvm_component;
        `uvm_component_utils(i2c_slave)
        virtual i2c_if vif;
        i2c_slave_cfg  cfg;
        i2c_line_state line;
        typedef enum { S_IDLE, S_ADDR, S_ACKA, S_RXD, S_ACKD, S_TXD, S_MACK } st_e;
        st_e st = S_IDLE;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual i2c_if)::get(this, "", "ivif", vif)) `uvm_fatal("NOVIF", "i2c_slave: no virtual interface")
        endfunction
        // the slave gives up: what a real device does after its own timeout or a power cycle
        function void release_all(); st = S_IDLE; vif.slv_sda_low = 1'b0; vif.slv_scl_low = 1'b0; endfunction
        task stretch(int unsigned n);
            if (n == 0) return;
            vif.slv_scl_low = 1'b1; line.stretched = 1;
            fork begin #(n * TENTH_NS + 0.4); vif.slv_scl_low = 1'b0; end join_none
        endtask
        task run_phase(uvm_phase phase);
            bit pscl, psda, scl, sda, rw, mack; int n = 0, idx = 0; bit [7:0] sh, tx;
            pscl = vif.scl; psda = vif.sda;
            forever begin
                @(vif.scl or vif.sda);
                #0.01;                                                 // both lines may move in the same pclk: read them once they have
                if (line.spike) continue;
                scl = vif.scl; sda = vif.sda;
                if (pscl && scl && psda && !sda) begin st = S_ADDR; n = 0; idx = 0; vif.slv_sda_low = 1'b0; end
                else if (pscl && scl && !psda && sda) begin st = S_IDLE; vif.slv_sda_low = 1'b0; end
                else if (!pscl && scl) begin                          // rising edge: take a bit
                    case (st)
                        S_ADDR, S_RXD: begin sh = {sh[6:0], sda}; n++; end
                        S_TXD:  n++;
                        S_MACK: mack = sda;
                        default: ;
                    endcase
                end else if (pscl && !scl) begin                      // falling edge: change what it drives
                    case (st)
                        S_ADDR: if (n == 8) begin
                                    rw = sh[0];
                                    if (cfg.present && sh[7:1] == cfg.addr) begin vif.slv_sda_low = 1'b1; st = S_ACKA; stretch(cfg.stretch_addr); end
                                    else st = S_IDLE;
                                end else if (n == 4) stretch(cfg.stretch_mid);
                        S_ACKA, S_ACKD: begin
                                    if (rw && st == S_ACKA) begin
                                        tx = (cfg.rd_q.size() != 0) ? cfg.rd_q.pop_front() : $urandom_range(0, 255);
                                        cfg.rd_sent.push_back(tx);
                                        vif.slv_sda_low = !tx[7]; st = S_TXD;
                                    end else begin vif.slv_sda_low = 1'b0; st = S_RXD; end
                                    n = 0;
                                end
                        S_RXD:  if (n == 8) begin
                                    cfg.wr_seen.push_back(sh);
                                    if (cfg.nack_data_at == idx) st = S_IDLE;
                                    else begin vif.slv_sda_low = 1'b1; st = S_ACKD; stretch(cfg.stretch_data); end
                                    idx++;
                                end else if (n == 4) stretch(cfg.stretch_mid);
                        S_TXD:  if (n == 8) begin vif.slv_sda_low = 1'b0; st = S_MACK; stretch(cfg.stretch_data); end
                                else begin vif.slv_sda_low = !tx[7 - n]; if (n == 4) stretch(cfg.stretch_mid); end
                        S_MACK: if (mack) st = S_IDLE;                 // the master is done: the line stays released
                                else begin
                                    tx = (cfg.rd_q.size() != 0) ? cfg.rd_q.pop_front() : $urandom_range(0, 255);
                                    cfg.rd_sent.push_back(tx);
                                    vif.slv_sda_low = !tx[7]; st = S_TXD; n = 0; idx++;
                                end
                        default: ;
                    endcase
                end
                pscl = scl; psda = sda;
            end
        endtask
    endclass

    // ------------------------------------------------------------------ a second master, and spikes
    class i2c_other extends uvm_component;
        `uvm_component_utils(i2c_other)
        virtual i2c_if vif;
        i2c_line_state line;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual i2c_if)::get(this, "", "ivif", vif)) `uvm_fatal("NOVIF", "i2c_other: no virtual interface")
        endfunction
        task wait_t(int unsigned n); #(n * TENTH_NS + 0.4); endtask
        // a pulse shorter than the input filter passes: not bus activity ([N-9.3])
        task spike(bit on_sda, int unsigned tenths);
            line.spike = 1;
            if (on_sda) vif.oth_sda_low = 1'b1; else vif.oth_scl_low = 1'b1;
            wait_t(tenths);
            vif.oth_sda_low = 1'b0; vif.oth_scl_low = 1'b0;
            #0.1 line.spike = 0;
        endtask
        // another master sends a 0 where this block sends a 1: SDA low across one high time of SCL
        // (the block lets go of SCL when it sees it has lost, so the other master's own
        // clock is not waited for: SDA is held for hold_t after SCL rose)
        task win_arbitration(int unsigned hold_t);
            @(negedge vif.scl); wait_t(2);
            vif.oth_sda_low = 1'b1;
            @(posedge vif.scl); wait_t(hold_t);
            vif.oth_sda_low = 1'b0;
        endtask
        // another master's START and STOP with this block idle ([N-6.3])
        task foreign_start(int unsigned t); vif.oth_sda_low = 1'b1; wait_t(t); vif.oth_scl_low = 1'b1; wait_t(t); endtask
        task foreign_stop(int unsigned t);  vif.oth_scl_low = 1'b0; wait_t(t); vif.oth_sda_low = 1'b0; wait_t(t); endtask
        function void release_all(); vif.oth_scl_low = 1'b0; vif.oth_sda_low = 1'b0; endfunction
    endclass

    // ------------------------------------------------------------------ the pclk-side monitor
    class i2c_cycle_item extends uvm_sequence_item;
        bit preset_n;
        bit psel, penable, pwrite; bit [11:0] paddr; bit [31:0] pwdata;
        logic scl_oe, sda_oe, irq, dma_req; bit dma_ack;
        logic [31:0] prdata; logic pready, pslverr;
        `uvm_object_utils(i2c_cycle_item)
        function new(string name = "i2c_cycle_item"); super.new(name); endfunction
    endclass

    class i2c_monitor extends uvm_monitor;
        `uvm_component_utils(i2c_monitor)
        virtual i2c_if vif;
        uvm_analysis_port #(i2c_cycle_item) ap;
        function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual i2c_if)::get(this, "", "ivif", vif)) `uvm_fatal("NOVIF", "i2c_monitor: no virtual interface")
        endfunction
        task run_phase(uvm_phase phase);
            i2c_cycle_item it;
            forever begin
                @(vif.cb);
                it = i2c_cycle_item::type_id::create("it");
                it.preset_n = (vif.cb.preset_n === 1'b1);
                it.psel = vif.cb.psel; it.penable = vif.cb.penable; it.pwrite = vif.cb.pwrite;
                it.paddr = vif.cb.paddr; it.pwdata = vif.cb.pwdata;
                it.scl_oe = vif.cb.scl_oe; it.sda_oe = vif.cb.sda_oe; it.irq = vif.cb.irq; it.dma_req = vif.cb.dma_req;
                it.dma_ack = vif.cb.dma_ack;
                it.prdata = vif.cb.prdata; it.pready = vif.cb.pready; it.pslverr = vif.cb.pslverr;
                ap.write(it);
            end
        endtask
    endclass

    // ------------------------------------------------------------------ a status bit that takes time to change
    // The scoreboard knows what a bit will become and by when. Before that time a
    // read may show the old or the new value; the first read of the new value
    // settles it. A bit whose history the scoreboard cannot know (an event in the
    // cycle of a clear, a second master) is "unknown" until something sets it again.
    class i2c_tbit;
        bit val, unk; longint sure_at, pend;       // pend: until when an event may still land
        function void now(bit v);               val = v; unk = 0; sure_at = 0; endfunction
        function void by(bit v, longint when);  if (when > pend) pend = when; if (unk || val != v) begin val = v; unk = 0; sure_at = when; end endfunction
        function void unknown();                unk = 1; endfunction
        function bit  sure(longint t);          return !unk && t >= sure_at; endfunction
        // firmware clears it: it is 0 afterwards unless an event is still on its way
        function void clear(longint t);         if (t >= pend) now(0); else unknown(); endfunction
        // 1 = mismatch
        function bit check(logic got, longint t);
            if (unk) return 0;
            if (t >= sure_at) return got !== val;
            if (got === val) sure_at = t;
            return 0;
        endfunction
    endclass

    typedef struct { i2c_ev_e kind; bit rd; bit [7:0] data; bit nack; bit last; } i2c_exp_t;

    // ------------------------------------------------------------------ coverage
    class i2c_coverage extends uvm_component;
        `uvm_component_utils(i2c_coverage)

        covergroup cg_i2c_apb with function sample(int kind, bit wr);
            option.per_instance = 1;
            cp_reg: coverpoint kind { bins PRESCALE = {0}; bins CTRL = {1}; bins TXDATA = {2}; bins RXDATA = {3}; bins CMD = {4}; bins STATUS = {5};
                                      bins TIMEOUT = {6}; bins IRQSTAT = {8}; bins IRQEN = {9}; bins DMACTL = {10}; bins ID = {11}; }
            cp_rw: coverpoint wr { bins read = {0}; bins write = {1}; }
            x_reg_rw: cross cp_reg, cp_rw;
            cp_unmapped: coverpoint kind { bins hole_in_ip = {28}; bins between_ip_and_tail = {20}; bins unaligned_in_ip = {27}; bins first_past_ip = {21};
                                           bins last_before_tail = {22}; bins above_tail = {23}; bins unaligned_tail = {24};
                                           bins alias_of_ip_register = {25}; bins alias_of_shim_register = {26}; }
            x_unmapped_rw: cross cp_unmapped, cp_rw;
        endgroup

        covergroup cg_i2c_cmd with function sample(bit [4:0] c, bit refused);
            option.per_instance = 1;
            cp_cmd: coverpoint c iff (!refused) { bins start_write = {5'h09}; bins write = {5'h08}; bins read_ack = {5'h04}; bins read_nack = {5'h14};
                                                  bins stop = {5'h02}; bins write_stop = {5'h0A}; bins read_nack_stop = {5'h16}; bins start_read = {5'h05, 5'h15};
                                                  bins read_with_write = {5'h0C, 5'h0D, 5'h1C}; bins start_with_stop_only = {5'h03, 5'h13}; }
            cp_refused: coverpoint c iff (refused) { bins nothing_to_do[] = {5'h00, 5'h01, 5'h10, 5'h11}; bins during_a_transfer = default; }
        endgroup

        covergroup cg_i2c_status with function sample(bit [5:0] s);
            option.per_instance = 1;
            cp_tip: coverpoint s[0]; cp_busy: coverpoint s[1]; cp_al: coverpoint s[2];
            cp_rxnack: coverpoint s[3]; cp_timeout: coverpoint s[4]; cp_rxvalid: coverpoint s[5];
        endgroup

        covergroup cg_i2c_xfer with function sample(bit rd, int len, bit rep);
            option.per_instance = 1;
            cp_dir: coverpoint rd { bins write = {0}; bins read = {1}; }
            cp_len: coverpoint len { bins address_only = {0}; bins one = {1}; bins two = {2}; bins eight = {8}; bins more = {[9:$]}; bins other = default; }
            x_dir_len: cross cp_dir, cp_len { ignore_bins none = binsof(cp_len.address_only); }
            cp_repeated_start: coverpoint rep { bins ended_by_a_repeated_start = {1}; bins ended_by_stop = {0}; }
        endgroup

        covergroup cg_i2c_rate with function sample(bit [15:0] p);
            option.per_instance = 1;
            cp_prescale: coverpoint p { bins below_the_minimum[] = {[0:2]}; bins minimum_3 = {3}; bins fast_mode_61 = {61}; bins standard_mode_249 = {249};
                                        bins max = {16'hFFFF}; bins other = default; }
        endgroup

        covergroup cg_i2c_stretch with function sample(int where, int len);
            option.per_instance = 1;
            cp_where: coverpoint where { bins after_address = {0}; bins after_data_byte = {1}; bins in_mid_byte = {2}; }
            cp_len: coverpoint len { bins short_stretch = {0}; bins long_stretch = {1}; bins just_under_timeout = {2}; }
            x_where_len: cross cp_where, cp_len;
        endgroup

        covergroup cg_i2c_glitch with function sample(bit on_sda, int width, bit in_xfer);
            option.per_instance = 1;
            cp_line: coverpoint on_sda { bins scl = {0}; bins sda = {1}; }
            cp_width: coverpoint width { bins one_pclk = {0}; bins under_filter = {1}; }
            cp_when: coverpoint in_xfer { bins idle = {0}; bins in_transfer = {1}; }
            x_line_width: cross cp_line, cp_width, cp_when;
        endgroup

        covergroup cg_i2c_nack with function sample(int where);
            option.per_instance = 1;
            cp_where: coverpoint where { bins address = {0}; bins first_data = {1}; bins middle_data = {2}; bins last_data = {3}; }
        endgroup

        covergroup cg_i2c_al with function sample(int where);
            option.per_instance = 1;
            cp_where: coverpoint where { bins address = {0}; bins data_byte = {1}; bins acknowledge_bit = {2}; bins foreign_stop = {3}; }
        endgroup

        covergroup cg_i2c_timeout with function sample(int value, int phase);
            option.per_instance = 1;
            cp_value: coverpoint value { bins one = {0}; bins under_a_byte = {1}; bins over_a_byte = {2}; bins max = {3}; }
            cp_phase: coverpoint phase { bins not_reached = {0}; bins in_start = {1}; bins in_address = {2}; bins in_data = {3}; bins in_stretch = {4}; }
            x_value_phase: cross cp_value, cp_phase {
                ignore_bins one_fires_at_once = binsof(cp_value.one) && !binsof(cp_phase.in_start);
                ignore_bins under_a_byte = binsof(cp_value.under_a_byte) && (binsof(cp_phase.not_reached) || binsof(cp_phase.in_start));
                ignore_bins over_a_byte = binsof(cp_value.over_a_byte) && (binsof(cp_phase.in_start) || binsof(cp_phase.in_address) || binsof(cp_phase.in_data));
                ignore_bins max = binsof(cp_value.max) && !binsof(cp_phase.not_reached); }
        endgroup

        covergroup cg_i2c_abort with function sample(int pos);
            option.per_instance = 1;
            cp_phase: coverpoint pos { bins bit_position[] = {[0:35]}; bins idle = {36}; bins between_bytes = {37}; }
        endgroup

        covergroup cg_i2c_irq with function sample(int src, bit en, int together);
            option.per_instance = 1;
            cp_src: coverpoint src iff (together == 0) { bins transfer_complete = {0}; bins arbitration_lost = {1}; bins timeout = {2}; bins nack = {3}; }
            cp_en: coverpoint en iff (together == 0);
            x_src_en: cross cp_src, cp_en;
            cp_together: coverpoint together iff (together != 0) { bins two_sources = {2}; }
        endgroup

        covergroup cg_i2c_dma with function sample(int kind);
            option.per_instance = 1;
            cp_kind: coverpoint kind { bins receive_request = {0}; bins transmit_request = {1}; bins both_enabled = {2}; }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_i2c_apb = new(); cg_i2c_cmd = new(); cg_i2c_status = new(); cg_i2c_xfer = new(); cg_i2c_rate = new(); cg_i2c_stretch = new();
            cg_i2c_glitch = new(); cg_i2c_nack = new(); cg_i2c_al = new(); cg_i2c_timeout = new(); cg_i2c_abort = new();
            cg_i2c_irq = new(); cg_i2c_dma = new();
        endfunction

        function void apb_access(apb_item it, bit mapped);
            int kind;
            if (mapped) kind = (it.addr < 12'h020) ? it.addr[4:2] : 8 + it.addr[3:2];
            else if (it.addr == 12'h01C) kind = 28;
            else if (it.addr[1:0] != 2'b00) kind = (it.addr >= 12'hFE0) ? 24 : ((it.addr < 12'h020) ? 27 : -1);
            else if (it.addr == 12'h020) kind = 21;
            else if (it.addr[11:5] != 0 && $countones(it.addr[11:5]) == 1) kind = 25;
            else if ($countones(~it.addr[11:5]) == 1 && it.addr[4] == 1'b0) kind = 26;
            else if (it.addr == 12'hFDC) kind = 22;
            else if (it.addr >= 12'hFF0) kind = 23;
            else kind = 20;
            cg_i2c_apb.sample(kind, it.write);
        endfunction
    endclass

    // ------------------------------------------------------------------ scoreboard
    `uvm_analysis_imp_decl(_apb)
    `uvm_analysis_imp_decl(_cyc)
    `uvm_analysis_imp_decl(_bus)

    class i2c_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(i2c_scoreboard)
        uvm_analysis_imp_apb #(apb_item, i2c_scoreboard)       apb_imp;
        uvm_analysis_imp_cyc #(i2c_cycle_item, i2c_scoreboard) cyc_imp;
        uvm_analysis_imp_bus #(i2c_bus_ev, i2c_scoreboard)     bus_imp;
        i2c_coverage   cov;
        i2c_line_state line;
        // registers that only firmware changes
        bit [15:0] prescale, timeout; bit en; bit [7:0] txdata; bit [3:0] irqen; bit [1:0] dmactl;
        // registers the block changes
        i2c_tbit   tip, busy, al, rxnack, tmo, rxvalid, irqs[4];
        bit [7:0]  rx_exp, byte_data; bit rx_known, byte_nack, byte_written; longint rx_sure_at, done_by;
        bit        prev_ack;
        // the command in progress and what it must put on the bus
        i2c_exp_t  exp_q[$];
        bit        cmd_live, cmd_rd, cmd_wr, cmd_idle_forever, cmd_undefined; bit [4:0] cmd_bits; longint cmd_cyc; bit [15:0] cmd_timeout;
        // the bus is not this block's alone for the moment (after an abort, a timeout, arbitration loss, a second master)
        bit        loose;
        // the transfer in progress on the bus, for the coverage
        bit        x_live, x_rd; int x_bytes;
        longint    cyc, abort_cyc = -100;
        int unsigned n_rd, n_wr, n_err, n_ev, n_ev_cmp, n_rx_cmp, n_st_cmp, n_st_skip, n_period;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            apb_imp = new("apb_imp", this); cyc_imp = new("cyc_imp", this); bus_imp = new("bus_imp", this);
            tip = new(); busy = new(); al = new(); rxnack = new(); tmo = new(); rxvalid = new();
            foreach (irqs[i]) irqs[i] = new();
            reset_model();
        endfunction

        function void err(string id, string msg);
            n_err++;
            if (n_err <= 20) `uvm_error(id, msg)
        endfunction

        function void reset_model();
            prescale = 0; timeout = 0; en = 0; txdata = 0; irqen = 0; dmactl = 0;
            tip.now(0); busy.now(0); al.now(0); rxnack.now(0); tmo.now(0); rxvalid.now(0);
            foreach (irqs[i]) irqs[i].now(0);
            rx_exp = 0; rx_known = 1; rx_sure_at = 0; done_by = 0; exp_q.delete(); cmd_live = 0; cmd_idle_forever = 0; cmd_timeout = 0; loose = 0; x_live = 0;
            tip.pend = 0; busy.pend = 0; al.pend = 0; rxnack.pend = 0; tmo.pend = 0; rxvalid.pend = 0;
            foreach (irqs[i]) irqs[i].pend = 0;
        endfunction

        // how long a status bit may take: the end of a command after its last bus event (two
        // states of the bit controller), and the input filter (three samples at PRESCALE / 4)
        function longint w_done();   return 4 * (longint'(prescale) + 1) + 24; endfunction
        function longint w_filter(); return longint'(prescale) + 24; endfunction

        function bit in_ip(bit [11:0] a);  return (a[1:0] == 2'b00) && (a <= 12'h018); endfunction
        function bit mapped(bit [11:0] a); return in_ip(a) || (a[1:0] == 2'b00 && a >= 12'hFE0 && a <= 12'hFEC); endfunction
        // the vendored controllers are held in reset: EN clear, or the four pclk after an ABORT or a timeout
        function bit held(); return !en || (cyc - abort_cyc >= 1 && cyc - abort_cyc <= 4); endfunction

        // the transfer in progress is given up: by ABORT, by the timeout, by EN, by reset
        function void give_up(string why);
            i2c_tbit flying[4] = '{irqs[0], irqs[3], rxnack, rxvalid};
            exp_q.delete(); cmd_live = 0; cmd_idle_forever = 0;
            tip.by(0, cyc + 3);
            loose = 1; busy.unknown(); x_live = 0;
            // a command that had just finished on the bus may or may not have been reported
            foreach (flying[i]) if (!flying[i].sure(cyc)) flying[i].unknown();
            if (cyc < rx_sure_at) rx_known = 0;
        endfunction

        // ---- the tests say what they are about to do to the bus
        function void expect_al(int where);
            al.by(1, cyc + 40 * (longint'(prescale) + 1) + 200); irqs[1].by(1, cyc + 40 * (longint'(prescale) + 1) + 200);
            exp_q.delete(); cmd_live = 0; tip.by(0, cyc + 40 * (longint'(prescale) + 1) + 200);
            loose = 1; busy.unknown(); x_live = 0;
            cov.cg_i2c_al.sample(where);
        endfunction
        function void expect_foreign(); loose = 1; endfunction
        // the bus is idle again and this block's alone
        function void tight(); loose = 0; busy.unknown(); endfunction

        // ---- every pclk cycle
        function void write_cyc(i2c_cycle_item it);
            cyc++;
            if (!it.preset_n) begin
                reset_model();
                if (it.scl_oe !== 1'b0 || it.sda_oe !== 1'b0) err("sb_bus", "a line pulled low in reset");
                if (it.irq !== 1'b0) err("sb_irq", "irq high in reset");
                return;
            end
            if (it.pready !== 1'b1) err("sb_pready", "PREADY low");
            // the timeout: TIMEOUT pclk after the command was accepted, if it is still in progress
            if (cmd_timeout != 0 && cyc == cmd_cyc + cmd_timeout && (cmd_live || cyc <= done_by)) begin
                if (cmd_live) begin                                    // its last bus event has not come: certainly in progress
                    tmo.by(1, cyc + 2); irqs[2].by(1, cyc + 2); abort_cyc = cyc;
                    cov.cg_i2c_timeout.sample(tclass(cmd_timeout), line.stretched ? 4 : (!line.in_xfer || line.bit_no <= 0) ? 1 : (line.bit_no <= 9) ? 2 : 3);
                    cov.cg_i2c_irq.sample(2, irqen[2], 0);
                    give_up("timeout");
                end else begin                                         // it ends about now: either may have won
                    tmo.unknown(); irqs[2].unknown(); abort_cyc = cyc; tip.unknown();
                    give_up("timeout at the end of a command");
                end
            end
            // the DMA request, when nothing it depends on is changing ([N-7.7])
            if (rxvalid.sure(cyc) && tip.sure(cyc) && !it.dma_ack && !prev_ack) begin
                bit exp = (dmactl[0] && rxvalid.val) || (dmactl[1] && en && !tip.val);
                if (it.dma_req !== exp) err("sb_dma", $sformatf("dma_req %0b, expected %0b (DMACTL %02b RXVALID %0b EN %0b TIP %0b)", it.dma_req, exp, dmactl, rxvalid.val, en, tip.val));
                if (exp && dmactl[0] && rxvalid.val) cov.cg_i2c_dma.sample(0);
                if (exp && dmactl[1] && en && !tip.val) cov.cg_i2c_dma.sample(1);
            end
            prev_ack = it.dma_ack;
            if (it.psel && it.penable) access(it);
        endfunction

        function int tclass(bit [15:0] t);
            longint byte_time = 9 * 5 * (longint'(prescale) + 1);
            return (t == 1) ? 0 : (t == 16'hFFFF) ? 3 : (t < byte_time) ? 1 : 2;
        endfunction

        function void access(i2c_cycle_item it);
            bit m = mapped(it.paddr); bit [31:0] d = it.pwdata; bit exp_err; bit skip_err = 0;
            exp_err = !m;
            if (it.pwrite) begin
                n_wr++;
                case (it.paddr)
                    12'h000: prescale = d[15:0];
                    12'h004: begin
                        if (d[1]) begin                                // ABORT
                            cov.cg_i2c_abort.sample(!line.in_xfer ? 36 : (tip.sure(cyc) && !tip.val) ? 37 : (line.bit_no > 35) ? 35 : line.bit_no);
                            abort_cyc = cyc; give_up("ABORT");
                        end
                        if (en && !d[0]) give_up("EN cleared");
                        en = d[0];
                    end
                    12'h008: txdata = d[7:0];
                    12'h010: begin
                        if (d[3:1] == 3'b000) begin exp_err = 1; cov.cg_i2c_cmd.sample(d[4:0], 1); end   // nothing to do: refused ([N-6.2c], I2C-7)
                        else if (!tip.sure(cyc)) begin skip_err = 1; loose = 1; tip.unknown(); end   // the transfer ends about now: either answer is right
                        else if (tip.val) begin exp_err = 1; cov.cg_i2c_cmd.sample(d[4:0], 1); end
                        else if (!held()) command(d[4:0]);
                    end
                    12'h018: timeout = d[15:0];
                    12'hFE0: begin
                        for (int i = 0; i < 4; i++) if (d[i]) irqs[i].clear(cyc);
                        if (d[1]) al.clear(cyc);
                        if (d[2]) tmo.clear(cyc);
                    end
                    12'hFE4: irqen  = d[3:0];
                    12'hFE8: begin dmactl = d[1:0]; if (d[1:0] == 2'b11) cov.cg_i2c_dma.sample(2); end
                    default: ;
                endcase
            end else begin
                n_rd++;
                case (it.paddr)
                    12'h000: cmp("sb_reg", it, {16'd0, prescale});
                    12'h004: cmp("sb_reg", it, {31'd0, en});
                    12'h008: cmp("sb_reg", it, {24'd0, txdata});
                    12'h00C: begin
                        if (rx_known && cyc >= rx_sure_at) begin n_rx_cmp++; cmp("sb_rx", it, {24'd0, rx_exp}); end
                        rxvalid.clear(cyc);
                    end
                    12'h010: cmp("sb_reg", it, 32'd0);
                    12'h014: begin
                        i2c_tbit b[6] = '{tip, busy, al, rxnack, tmo, rxvalid};
                        string nm[6] = '{"TIP", "BUSY", "AL", "RXNACK", "TIMEOUT", "RXVALID"};
                        // TIP is seen clear for the first time after a command: what the command leaves in
                        // RXDATA, RXVALID and RXNACK is there from the same clock edge
                        if (!tip.unk && cyc < tip.sure_at && !tip.val && it.prdata[0] === 1'b0) begin
                            if (!rxvalid.unk && cyc < rxvalid.sure_at) rxvalid.sure_at = cyc;
                            if (!rxnack.unk && cyc < rxnack.sure_at)   rxnack.sure_at = cyc;
                            if (cyc < rx_sure_at) rx_sure_at = cyc;
                        end
                        foreach (b[i]) begin
                            if (b[i].unk || !b[i].sure(cyc)) n_st_skip++; else n_st_cmp++;
                            if (b[i].check(it.prdata[i], cyc))
                                err("sb_status", $sformatf("STATUS.%s reads %0b, expected %0b (STATUS %02h)", nm[i], it.prdata[i], b[i].val, it.prdata[5:0]));
                        end
                        if (it.prdata[31:6] !== 26'd0) err("sb_status", $sformatf("STATUS upper bits %08h", it.prdata));
                        cov.cg_i2c_status.sample(it.prdata[5:0]);
                    end
                    12'h018: cmp("sb_reg", it, {16'd0, timeout});
                    12'hFE0: begin
                        string nm[4] = '{"transfer complete", "arbitration lost", "timeout", "NACK"};
                        foreach (irqs[i]) if (irqs[i].check(it.prdata[i], cyc))
                            err("sb_status", $sformatf("IRQSTAT bit %0d (%s) reads %0b, expected %0b", i, nm[i], it.prdata[i], irqs[i].val));
                        if (it.prdata[31:4] !== 28'd0) err("sb_status", $sformatf("IRQSTAT upper bits %08h", it.prdata));
                    end
                    12'hFE4: cmp("sb_reg", it, {28'd0, irqen});
                    12'hFE8: cmp("sb_reg", it, {30'd0, dmactl});
                    12'hFEC: cmp("sb_reg", it, I2C_ID);
                    default: cmp("sb_reg", it, 32'd0);
                endcase
            end
            if (!skip_err && it.pslverr !== exp_err)
                err("sb_pslverr", $sformatf("%s 0x%03h: PSLVERR %0b, expected %0b", it.pwrite ? "write" : "read", it.paddr, it.pslverr, exp_err));
        endfunction

        function void cmp(string id, i2c_cycle_item it, bit [31:0] exp);
            if (it.prdata !== exp) err(id, $sformatf("read 0x%03h: DUT %08h, expected %08h", it.paddr, it.prdata, exp));
        endfunction

        // A command was accepted: what it must put on the bus ([N-6.2] and the vendored byte controller)
        function void command(bit [4:0] c);
            bit sta = c[0], sto = c[1], rd = c[2], wr = c[3]; i2c_exp_t e;
            if (exp_q.size() != 0 && !loose) err("sb_bus", $sformatf("a command was accepted with %0d bus events of the one before still to come", exp_q.size()));
            exp_q.delete();
            cov.cg_i2c_cmd.sample(c, 0); cov.cg_i2c_rate.sample(prescale);
            // below the smallest usable PRESCALE the block loses arbitration to itself (I2C-8): nothing can be predicted
            if (prescale < 3) begin tip.unknown(); al.unknown(); irqs[1].unknown(); irqs[0].unknown(); busy.unknown(); rxnack.unknown(); loose = 1; return; end
            tip.now(1); cmd_live = 1; cmd_bits = c; cmd_cyc = cyc; cmd_timeout = timeout; cmd_rd = rd; cmd_wr = wr && !rd;
            cmd_undefined = (rd && wr) || (sta && sto && !rd && !wr);
            byte_written = 0; byte_nack = 0;
            if (sta) begin e.kind = I2C_START; e.last = 0; exp_q.push_back(e); loose = 0; end
            if (rd || wr || (sta && sto)) begin
                e.kind = I2C_BYTE; e.rd = rd; e.data = txdata; e.nack = c[4]; e.last = !sto; exp_q.push_back(e);
            end
            if (sto) begin e.kind = I2C_STOP; e.last = 1; exp_q.push_back(e); end
        endfunction

        // the command's last bus event was seen: it ends within w_done
        function void command_done();
            longint t = cyc + w_done();
            cmd_live = 0; done_by = t;
            tip.by(0, t);
            irqs[0].by(1, t);
            cov.cg_i2c_irq.sample(0, irqen[0], 0);
            if (cmd_timeout != 0) cov.cg_i2c_timeout.sample(tclass(cmd_timeout), 0);
            if (cmd_rd) begin rx_exp = byte_data; rx_known = 1; rx_sure_at = t; rxvalid.by(1, t); end
            if (cmd_wr && byte_written) begin
                rxnack.by(byte_nack, t);
                if (byte_nack) begin irqs[3].by(1, t); cov.cg_i2c_irq.sample(3, irqen[3], 0); cov.cg_i2c_irq.sample(0, 0, 2); end
            end
            if (cmd_undefined) rxnack.unknown();
        endfunction

        function void write_bus(i2c_bus_ev ev);
            i2c_exp_t e;
            n_ev++;
            `uvm_info("BUS", $sformatf("%s (expecting %0d events, loose %0b)", ev.convert2string(), exp_q.size(), loose), UVM_HIGH)
            // BUSY follows every START and STOP on the lines, this block's or not ([N-6.3])
            if (ev.kind == I2C_START) busy.by(1, cyc + w_filter());
            if (ev.kind == I2C_STOP)  busy.by(0, cyc + w_filter());
            // the transfer, for the coverage
            if (ev.kind == I2C_BYTE && x_live) begin
                if (x_bytes == 0) x_rd = ev.data[0];
                x_bytes++;
            end
            if (ev.kind != I2C_BYTE) begin
                if (x_live && x_bytes != 0) cov.cg_i2c_xfer.sample(x_rd, x_bytes - 1, ev.kind == I2C_START);
                x_live = (ev.kind == I2C_START); x_bytes = 0;
            end
            // while the bus is not this block's alone, only the event a command is waiting for counts
            if (loose && !(exp_q.size() != 0 && exp_q[0].kind == ev.kind)) return;
            if (exp_q.size() == 0) begin
                err("sb_bus", $sformatf("%s on the bus with no command to cause it", ev.convert2string()));
                return;
            end
            e = exp_q.pop_front(); n_ev_cmp++;
            // the SCL period of a byte the block sent whole (a byte cut short by ABORT, a timeout or a lost
            // arbitration ends with the line let go, which is not a clock edge)
            if (ev.kind == I2C_BYTE && !ev.stretched && ev.min_period != 0) begin
                n_period++;
                if (ev.min_period < 5 * (longint'(prescale) + 1) * PCLK_NS - 0.5)
                    err("sb_scl_period", $sformatf("an SCL period of %0.1f ns with PRESCALE %0d: the shortest allowed is %0.1f ns (SCL rose at %p)", ev.min_period, prescale,
                                                   5 * (longint'(prescale) + 1) * PCLK_NS, ev.rises));
            end
            if (ev.kind != e.kind) begin
                err("sb_bus", $sformatf("%s on the bus, the command 0x%02h makes a %s next", ev.convert2string(), cmd_bits, e.kind.name()));
                exp_q.delete(); loose = 1; return;
            end
            if (ev.kind == I2C_BYTE) begin
                if (e.rd) begin
                    if (ev.nack !== e.nack) err("sb_bus", $sformatf("the byte read was answered with %s, CMD.NACK is %0b", ev.nack ? "NACK" : "ACK", e.nack));
                    byte_data = ev.data;
                end else begin
                    if (ev.data !== e.data) err("sb_bus", $sformatf("byte %02h on the bus, TXDATA was %02h", ev.data, e.data));
                    byte_written = 1; byte_nack = ev.nack;
                end
            end
            if (e.last) command_done();
        endfunction

        function void write_apb(apb_item it);
            cov.apb_access(it, mapped(it.addr));
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SB", $sformatf("i2c_scoreboard: %0d reads, %0d writes; %0d bus events, %0d compared with a command; %0d bytes read compared; %0d SCL periods; STATUS bits compared %0d, in transition %0d; %0d mismatches",
                                      n_rd, n_wr, n_ev, n_ev_cmp, n_rx_cmp, n_period, n_st_cmp, n_st_skip, n_err), UVM_NONE)
            if ((n_rd + n_wr) == 0) `uvm_error("SB", "the scoreboard compared nothing")
        endfunction
    endclass

    // ------------------------------------------------------------------ environment
    class i2c_env extends uvm_env;
        `uvm_component_utils(i2c_env)
        apb_agent       apb;
        i2c_bus_monitor bus;
        i2c_slave       slave;
        i2c_other       other;
        i2c_monitor     mon;
        i2c_scoreboard  sb;
        i2c_coverage    cov;
        i2c_slave_cfg   scfg;
        i2c_line_state  line;
        i2c             regmodel;
        apb_reg_adapter adapter;
        uvm_reg_predictor #(apb_item) predictor;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            apb   = apb_agent::type_id::create("apb", this);
            bus   = i2c_bus_monitor::type_id::create("bus", this);
            slave = i2c_slave::type_id::create("slave", this);
            other = i2c_other::type_id::create("other", this);
            mon   = i2c_monitor::type_id::create("mon", this);
            sb    = i2c_scoreboard::type_id::create("sb", this);
            cov   = i2c_coverage::type_id::create("cov", this);
            scfg  = i2c_slave_cfg::type_id::create("scfg");
            line  = new();
            bus.line = line; slave.line = line; other.line = line; sb.line = line; slave.cfg = scfg; sb.cov = cov;
            regmodel = new("regmodel");
            regmodel.build();
            regmodel.lock_model();
            regmodel.reset();
            adapter   = apb_reg_adapter::type_id::create("adapter");
            predictor = uvm_reg_predictor #(apb_item)::type_id::create("predictor", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            mon.ap.connect(sb.cyc_imp);
            bus.ap.connect(sb.bus_imp);
            apb.mon.ap.connect(sb.apb_imp);
            regmodel.default_map.set_sequencer(apb.sqr, adapter);
            regmodel.default_map.set_auto_predict(0);
            predictor.map = regmodel.default_map; predictor.adapter = adapter;
            apb.mon.ap.connect(predictor.bus_in);
        endfunction
    endclass

    `include "i2c_test_lib.svh"
endpackage
