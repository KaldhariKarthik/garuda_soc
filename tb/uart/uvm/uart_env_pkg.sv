`timescale 1ns/1ps
// =============================================================================
// uart_env_pkg.sv - UVM environment for blocks 16, 17 and 18, the UARTs.
//
// Plan: tb/uart/GARUDA_UART_vplan.csv. Names of checks and covergroups are the
// names in the plan.
//
//   uart_line_agent  the other end of the line: sends frames on rx at the
//                    programmed format, with a baud mismatch, parity and framing
//                    errors, breaks and short pulses; decodes every frame on tx
//                    and measures its bit period
//   uart_monitor     one item per pclk cycle: reset and the APB pins
//   uart_scoreboard  every frame on tx against the bytes written (sb_tx); every
//                    byte read against the frames sent (sb_rx); LSR (sb_lsr);
//                    the FIFOs across clears, a full FIFO and an overrun
//                    (sb_fifo); IRQSTAT (sb_irqstat); the registers firmware
//                    alone changes (sb_reg); PSLVERR (sb_pslverr); the bit
//                    period on tx (sb_bit_period); the DMA request (sb_dma)
//   uart_coverage    the plan's covergroups
//
// The 16550 register file, the receiver and the transmitter are vendored and
// are not modelled cycle by cycle. The scoreboard keeps the two FIFOs as queues,
// moved by what the line agent sees and sends, and allows each LSR bit the time
// the specification states before it must agree. Relations that hold in every
// cycle are properties, in rtl/uart/garuda_uart_sva.sv.
// =============================================================================
package uart_env_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import garuda_apb_pkg::*;
    import uart_reg_pkg::*;

    localparam real PCLK_NS = 8.0;
    localparam int  FIFO_N  = 16;

    // ------------------------------------------------------------------ the line
    // the format both ends use; the tests set it when they program LCR and the divisor
    class uart_line_cfg;
        bit [15:0] div = 0;          // one bit lasts div + 1 pclk
        int        bits = 5;         // data bits, 5 to 8
        bit        parity, stop2;
        function real bit_ns(); return (div + 1) * PCLK_NS; endfunction
        function bit [7:0] mask(); return 8'hFF >> (8 - bits); endfunction
    endclass

    typedef enum { UART_FRAME, UART_BREAK, UART_PULSE } uart_kind_e;

    class uart_frame extends uvm_sequence_item;
        rand uart_kind_e  kind;
        rand bit [7:0]    data;
        rand bit          bad_parity, bad_stop;
        rand int          skew;          // the sender's bit period against the programmed one, in tenths of a percent
        rand int unsigned gap;           // idle time before the frame, in tenths of a bit
        rand int unsigned len;           // BREAK: low time in tenths of a bit; PULSE: in hundredths of a bit
        // observed on tx by the monitor
        bit parity_ok, stop_ok; realtime t_last; int n_last; bit [15:0] div_at; int bits_at;   // t_last: start edge to the last edge, n_last bits
        constraint c_kind { kind dist { UART_FRAME := 100 }; }
        constraint c_err  { bad_parity dist { 0 := 92, 1 := 8 }; bad_stop dist { 0 := 94, 1 := 6 }; }
        constraint c_skew { skew dist { 0 := 40, [-40:40] :/ 60 }; }
        constraint c_gap  { gap dist { 0 := 30, [1:30] :/ 50, [31:400] :/ 20 }; len inside {[1:400]}; }
        `uvm_object_utils(uart_frame)
        function new(string name = "uart_frame"); super.new(name); endfunction
    endclass

    // what the transmitter is doing, for the coverage and the tests
    class uart_line_state;
        bit tx_busy;                     // a frame is on tx
        int unsigned n_tx, n_rx;
    endclass

    // sends frames on rx
    class uart_line_driver extends uvm_driver #(uart_frame);
        `uvm_component_utils(uart_line_driver)
        virtual uart_if vif;
        uart_line_cfg cfg;
        uart_line_state line;
        uvm_analysis_port #(uart_frame) ap;     // a frame at the start of its stop bit: the receiver takes it half a bit later
        function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual uart_if)::get(this, "", "uvif", vif)) `uvm_fatal("NOVIF", "uart_line_driver: no virtual interface")
        endfunction
        // every edge on a grid of 0.8 ns from 0.4 ns: never on an edge of pclk
        task align();
            longint p = longint'($realtime * 1000.0), r;
            r = (p - 400) % 800; if (r < 0) r += 800;
            if (r != 0) #((800 - r) * 1ps);
        endtask
        task hold(real ns); #(ns); align(); endtask
        task run_phase(uvm_phase phase);
            vif.rx = 1'b1;
            forever begin
                seq_item_port.get_next_item(req);
                align();
                drive(req);
                seq_item_port.item_done();
            end
        endtask
        task drive(uart_frame f);
            real t = cfg.bit_ns() * (1.0 + f.skew / 1000.0); bit par = 0; bit [7:0] d = f.data & cfg.mask();
            hold(t * f.gap / 10.0);
            case (f.kind)
                UART_BREAK: begin                                    // the receiver takes one 0x00 with a framing error (F20)
                    real frame = t * (1 + cfg.bits + cfg.parity);
                    f.data = 0; f.bad_parity = 0; f.bad_stop = 1;
                    vif.rx = 1'b0; hold(frame); ap.write(f); hold(t * f.len / 10.0 - frame);
                    vif.rx = 1'b1; hold(2 * t);
                end
                UART_PULSE: begin vif.rx = 1'b0; hold(t * f.len / 100.0); vif.rx = 1'b1; hold(2 * t); end
                default: begin
                    f.data = d; f.div_at = cfg.div; f.bits_at = cfg.bits;
                    vif.rx = 1'b0; hold(t);
                    for (int i = 0; i < cfg.bits; i++) begin vif.rx = d[i]; par ^= d[i]; hold(t); end
                    if (cfg.parity) begin vif.rx = par ^ f.bad_parity; hold(t); end else f.bad_parity = 0;
                    vif.rx = !f.bad_stop;
                    line.n_rx++;
                    ap.write(f);
                    hold(t);
                    vif.rx = 1'b1;
                    if (f.bad_stop) hold(t);                         // back to idle before the next start bit
                end
            endcase
        endtask
    endclass

    // decodes frames on tx
    typedef enum { UART_TX_START, UART_TX_DONE } uart_tx_e;
    class uart_tx_ev extends uvm_sequence_item;
        uart_tx_e kind; uart_frame f;
        `uvm_object_utils(uart_tx_ev)
        function new(string name = "uart_tx_ev"); super.new(name); endfunction
    endclass

    class uart_line_monitor extends uvm_monitor;
        `uvm_component_utils(uart_line_monitor)
        virtual uart_if vif;
        uart_line_cfg cfg;
        uart_line_state line;
        uvm_analysis_port #(uart_tx_ev) ap;
        function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual uart_if)::get(this, "", "uvif", vif)) `uvm_fatal("NOVIF", "uart_line_monitor: no virtual interface")
        endfunction
        realtime t_edge;                 // the last time tx moved
        task run_phase(uvm_phase phase);
            uart_tx_ev e; uart_frame f; real t; realtime t0; bit par;
            fork forever begin @(vif.tx); t_edge = $realtime; end join_none
            forever begin
                @(negedge vif.tx);
                if (vif.preset_n !== 1'b1) continue;
                t = cfg.bit_ns(); t0 = $realtime; line.tx_busy = 1; line.n_tx++;
                f = uart_frame::type_id::create("f"); f.div_at = cfg.div; f.bits_at = cfg.bits;
                e = uart_tx_ev::type_id::create("e"); e.kind = UART_TX_START; e.f = f; ap.write(e);
                #(t * 0.5);
                if (vif.tx !== 1'b0) `uvm_error("sb_tx", "the start bit on tx is shorter than half a bit")
                par = 0;
                for (int i = 0; i < cfg.bits; i++) begin #(t); f.data[i] = vif.tx; par ^= vif.tx; end
                f.parity_ok = 1;
                if (cfg.parity) begin #(t); f.parity_ok = (vif.tx === par); end
                #(t); f.stop_ok = (vif.tx === 1'b1);
                // the last edge before the stop bit is a whole number of bits after the start edge
                f.t_last = t_edge - t0; f.n_last = $rtoi(f.t_last / t + 0.5);
                if (cfg.stop2) begin #(t); f.stop_ok &= (vif.tx === 1'b1); end
                line.tx_busy = 0;
                e = uart_tx_ev::type_id::create("e"); e.kind = UART_TX_DONE; e.f = f; ap.write(e);
            end
        endtask
    endclass

    class uart_line_agent extends uvm_agent;
        `uvm_component_utils(uart_line_agent)
        uart_line_driver  drv;
        uart_line_monitor mon;
        uvm_sequencer #(uart_frame) sqr;
        uart_line_cfg   cfg;
        uart_line_state line;
        function new(string name, uvm_component parent); super.new(name, parent); cfg = new(); line = new(); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            drv = uart_line_driver::type_id::create("drv", this);
            mon = uart_line_monitor::type_id::create("mon", this);
            sqr = uvm_sequencer #(uart_frame)::type_id::create("sqr", this);
            drv.cfg = cfg; mon.cfg = cfg; drv.line = line; mon.line = line;
        endfunction
        function void connect_phase(uvm_phase phase); drv.seq_item_port.connect(sqr.seq_item_export); endfunction
    endclass

    // ------------------------------------------------------------------ the pclk-side monitor
    class uart_cycle_item extends uvm_sequence_item;
        bit preset_n;
        bit psel, penable, pwrite; bit [11:0] paddr; bit [31:0] pwdata;
        logic tx, irq, dma_req; bit dma_ack;
        logic [31:0] prdata; logic pready, pslverr;
        `uvm_object_utils(uart_cycle_item)
        function new(string name = "uart_cycle_item"); super.new(name); endfunction
    endclass

    class uart_monitor extends uvm_monitor;
        `uvm_component_utils(uart_monitor)
        virtual uart_if vif;
        uvm_analysis_port #(uart_cycle_item) ap;
        function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual uart_if)::get(this, "", "uvif", vif)) `uvm_fatal("NOVIF", "uart_monitor: no virtual interface")
        endfunction
        task run_phase(uvm_phase phase);
            uart_cycle_item it;
            forever begin
                @(vif.cb);
                it = uart_cycle_item::type_id::create("it");
                it.preset_n = (vif.cb.preset_n === 1'b1);
                it.psel = vif.cb.psel; it.penable = vif.cb.penable; it.pwrite = vif.cb.pwrite;
                it.paddr = vif.cb.paddr; it.pwdata = vif.cb.pwdata;
                it.tx = vif.cb.tx; it.irq = vif.cb.irq; it.dma_req = vif.cb.dma_req; it.dma_ack = vif.cb.dma_ack;
                it.prdata = vif.cb.prdata; it.pready = vif.cb.pready; it.pslverr = vif.cb.pslverr;
                ap.write(it);
            end
        endtask
    endclass

    // a flag that takes time to change (see i2c_env_pkg: the same idea)
    class uart_tbit;
        bit val, unk; longint sure_at;
        function void now(bit v);               val = v; unk = 0; sure_at = 0; endfunction
        function void by(bit v, longint when);  if (unk || val != v) begin val = v; unk = 0; sure_at = when; end endfunction
        function void unknown();                unk = 1; endfunction
        function bit  sure(longint t);          return !unk && t >= sure_at; endfunction
        function bit  check(logic got, longint t);
            if (unk) return 0;
            if (t >= sure_at) return got !== val;
            if (got === val) sure_at = t;
            return 0;
        endfunction
    endclass

    // ------------------------------------------------------------------ coverage
    class uart_coverage extends uvm_component;
        `uvm_component_utils(uart_coverage)

        covergroup cg_uart_apb with function sample(int kind, bit wr);
            option.per_instance = 1;
            cp_reg: coverpoint kind { bins RBR_THR = {0}; bins IER = {1}; bins IIR_FCR = {2}; bins LCR = {3}; bins MCR = {4}; bins LSR = {5}; bins MSR = {6}; bins SCR = {7};
                                      bins IRQSTAT = {8}; bins IRQEN = {9}; bins DMACTL = {10}; bins ID = {11}; }
            cp_rw: coverpoint wr { bins read = {0}; bins write = {1}; }
            x_reg_rw: cross cp_reg, cp_rw;
            cp_unmapped: coverpoint kind { bins between_ip_and_tail = {20}; bins unaligned_in_ip = {27}; bins first_past_ip = {21}; bins last_before_tail = {22};
                                           bins above_tail = {23}; bins unaligned_tail = {24}; bins alias_of_ip_register = {25}; bins alias_of_shim_register = {26}; }
            x_unmapped_rw: cross cp_unmapped, cp_rw;
        endgroup

        covergroup cg_uart_reg with function sample(int kind, bit dlab, bit off4, bit wr, bit [7:0] v);
            option.per_instance = 1;
            cp_dlab: coverpoint dlab iff (kind == 0); cp_off: coverpoint off4 iff (kind == 0) { bins x00 = {0}; bins x04 = {1}; }
            cp_wr: coverpoint wr iff (kind == 0) { bins read = {0}; bins write = {1}; }
            x_dlab_offset: cross cp_dlab, cp_off, cp_wr;
            cp_ier: coverpoint v iff (kind == 1) { bins receive_data = {8'h01}; bins transmit_empty = {8'h02}; bins line_status = {8'h04}; bins all = {8'hFF}; bins none = {0}; }
        endgroup

        covergroup cg_uart_fcr with function sample(bit rx, int state);
            option.per_instance = 1;
            cp_which: coverpoint rx { bins transmit = {0}; bins receive = {1}; }
            cp_state: coverpoint state { bins empty = {0}; bins part_full = {1}; bins full = {2}; bins frame_in_the_shifter = {3}; }
            x_clear_state: cross cp_which, cp_state { ignore_bins rx_shifter = binsof(cp_which.receive) && binsof(cp_state.frame_in_the_shifter); }
        endgroup

        covergroup cg_uart_fmt with function sample(bit rx, int bits, bit parity, bit stop2);
            option.per_instance = 1;
            cp_dir: coverpoint rx { bins transmit = {0}; bins receive = {1}; }
            cp_len: coverpoint bits { bins five = {5}; bins six = {6}; bins seven = {7}; bins eight = {8}; }
            cp_parity: coverpoint parity { bins off = {0}; bins even = {1}; }
            cp_stop: coverpoint stop2 { bins one = {0}; bins two = {1}; }
            x_len_parity_stop: cross cp_dir, cp_len, cp_parity, cp_stop;
        endgroup

        covergroup cg_uart_baud with function sample(int kind, int v);
            option.per_instance = 1;
            cp_divisor: coverpoint v iff (kind == 0) { bins below_the_minimum[] = {[0:1]}; bins minimum_2 = {2}; bins a_few_pclk = {[3:20]}; bins d134 = {134}; bins d1084 = {1084}; bins d2169 = {2169};
                                                      bins d13020 = {13020}; bins max = {16'hFFFF}; bins other = default; }
            cp_mismatch: coverpoint v iff (kind == 1) { bins slower[] = {[-40:-1]} with (item % 10 == 0); bins exact = {0}; bins faster[] = {[1:40]} with (item % 10 == 0);
                                                       bins other = default; }
            cp_back_to_back: coverpoint v iff (kind == 2) { bins no_gap = {0}; bins gap = {[1:$]}; }
        endgroup

        covergroup cg_uart_fifo with function sample(int kind, int v);
            option.per_instance = 1;
            cp_tx_level: coverpoint v iff (kind == 0) { bins empty = {0}; bins one = {1}; bins fifteen = {15}; bins sixteen = {16}; bins write_while_full = {17}; }
            cp_rx_level: coverpoint v iff (kind == 1) { bins empty = {0}; bins one = {1}; bins fifteen = {15}; bins sixteen = {16}; bins overrun_by_one = {17};
                                                        bins overrun_by_several = {[18:$]}; }
        endgroup

        covergroup cg_uart_err with function sample(int kind, int pos);
            option.per_instance = 1;
            cp_kind: coverpoint kind { bins parity = {0}; bins framing = {1}; bins both = {2}; }
            cp_position: coverpoint pos { bins first = {0}; bins middle = {[1:14]}; bins last = {15}; }
            x_kind_position: cross cp_kind, cp_position { ignore_bins both = binsof(cp_kind.both); }
            cp_two_in_a_row: coverpoint pos iff (kind == 3) { bins two_errors_in_a_row = {0}; }
        endgroup

        covergroup cg_uart_rx with function sample(int kind, int v);
            option.per_instance = 1;
            cp_glitch: coverpoint v iff (kind == 0) { bins one_pclk = {0}; bins quarter_bit = {1}; bins under_half_bit = {2}; }
            cp_break: coverpoint v iff (kind == 1) { bins one_frame = {1}; bins two_frames = {2}; bins ten_frames = {10}; }
        endgroup

        covergroup cg_uart_irq with function sample(int src, bit en, int clr);
            option.per_instance = 1;
            cp_src: coverpoint src { bins receive_data = {0}; bins transmit_empty = {1}; bins line_error = {2}; }
            cp_en: coverpoint en iff (clr < 0);
            x_src_en: cross cp_src, cp_en;
            cp_clear: coverpoint clr iff (clr >= 0) { bins condition_gone = {0}; bins condition_still_true = {1}; }
            x_src_en_clear: cross cp_src, cp_clear;
        endgroup

        covergroup cg_uart_dma with function sample(int kind);
            option.per_instance = 1;
            x_dir_level: coverpoint kind { bins receive_with_one_byte = {0}; bins receive_with_sixteen = {1}; bins transmit_with_the_fifo_empty = {2};
                                           bins transmit_with_the_fifo_nearly_full = {3}; }
            cp_both_bits: coverpoint kind { bins both_bits_data_and_space = {4}; }
            cp_dlab: coverpoint kind { bins held_off_by_dlab = {5}; }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg_uart_apb = new(); cg_uart_reg = new(); cg_uart_fcr = new(); cg_uart_fmt = new(); cg_uart_baud = new();
            cg_uart_fifo = new(); cg_uart_err = new(); cg_uart_rx = new(); cg_uart_irq = new(); cg_uart_dma = new();
        endfunction

        function void apb_access(apb_item it, bit mapped);
            int kind;
            if (mapped) kind = (it.addr < 12'h020) ? it.addr[4:2] : 8 + it.addr[3:2];
            else if (it.addr[1:0] != 2'b00) kind = (it.addr >= 12'hFE0) ? 24 : ((it.addr < 12'h020) ? 27 : -1);
            else if (it.addr == 12'h020) kind = 21;
            else if (it.addr[11:5] != 0 && $countones(it.addr[11:5]) == 1) kind = 25;
            else if ($countones(~it.addr[11:5]) == 1 && it.addr[4] == 1'b0) kind = 26;
            else if (it.addr == 12'hFDC) kind = 22;
            else if (it.addr >= 12'hFF0) kind = 23;
            else kind = 20;
            cg_uart_apb.sample(kind, it.write);
        endfunction
    endclass

    // ------------------------------------------------------------------ scoreboard
    `uvm_analysis_imp_decl(_apb)
    `uvm_analysis_imp_decl(_cyc)
    `uvm_analysis_imp_decl(_txe)
    `uvm_analysis_imp_decl(_rxf)

    typedef struct { bit [7:0] data; bit pe, fe; } uart_rx_t;

    class uart_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(uart_scoreboard)
        uvm_analysis_imp_apb #(apb_item, uart_scoreboard)        apb_imp;
        uvm_analysis_imp_cyc #(uart_cycle_item, uart_scoreboard) cyc_imp;
        uvm_analysis_imp_txe #(uart_tx_ev, uart_scoreboard)      txe_imp;
        uvm_analysis_imp_rxf #(uart_frame, uart_scoreboard)      rxf_imp;
        uart_coverage   cov;
        uart_line_cfg   cfg;
        uart_line_state line;
        virtual uart_if vif;
        // registers that only firmware changes
        bit [7:0]  lcr, ier, dll, dlm; bit [2:0] irqen; bit [1:0] dmactl;
        // the transmit side: in the FIFO, and taken by the shifter and not yet seen whole on the line
        bit [7:0]  tx_fifo[$], tx_line[$]; longint tx_unsure_until; bit tx_loose;
        // the receive side: in the FIFO, on their way (the stop bit is on the line), and the one
        // the receiver holds while the FIFO is full
        uart_rx_t  rx_fifo[$], rx_way[$]; longint rx_way_by[$]; uart_rx_t rx_held; bit rx_held_v; longint rx_unsure_until; bit rx_loose;
        int unsigned rx_over;
        // the three interrupt flags
        uart_tbit  irqs[3];
        longint    cyc; bit prev_ack; bit [31:0] id;
        int unsigned n_rd, n_wr, n_err, n_tx_cmp, n_rx_cmp, n_lsr_cmp, n_lsr_skip, n_period;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            apb_imp = new("apb_imp", this); cyc_imp = new("cyc_imp", this); txe_imp = new("txe_imp", this); rxf_imp = new("rxf_imp", this);
            foreach (irqs[i]) irqs[i] = new();
            reset_model();
        endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual uart_if)::get(this, "", "uvif", vif)) `uvm_fatal("NOVIF", "uart_scoreboard: no virtual interface")
        endfunction

        function void err(string id_, string msg);
            n_err++;
            if (n_err <= 20) `uvm_error(id_, msg)
        endfunction

        function void reset_model();
            lcr = 0; ier = 0; dll = 0; dlm = 0; irqen = 0; dmactl = 0;
            tx_fifo.delete(); tx_line.delete(); rx_fifo.delete(); rx_way.delete(); rx_way_by.delete(); rx_held_v = 0; rx_over = 0;
            tx_unsure_until = cyc + 4; rx_unsure_until = cyc + 4;
            irqs[0].now(0); irqs[2].now(0); irqs[1].by(1, cyc + 8);          // THRE is true out of reset: its flag sets at once
        endfunction

        // the test let the line do something the model does not follow (a divisor below the minimum,
        // a reset in mid-frame); it has emptied both FIFOs with FCR and the model starts again from that
        function void resync();
            tx_fifo.delete(); tx_line.delete(); rx_fifo.delete(); rx_way.delete(); rx_way_by.delete(); rx_held_v = 0; rx_over = 0;
            tx_unsure_until = cyc + 8; rx_unsure_until = cyc + 8; tx_loose = 0; rx_loose = 0;
            foreach (irqs[i]) irqs[i].unknown();
        endfunction

        function bit dlab(); return lcr[7]; endfunction
        function bit in_ip(bit [11:0] a);  return (a[1:0] == 2'b00) && (a < 12'h020); endfunction
        function bit mapped(bit [11:0] a); return in_ip(a) || (a[1:0] == 2'b00 && a >= 12'hFE0 && a <= 12'hFEC); endfunction
        // how long after a change on the line the vendored block and the wrapper's poll may lag
        function longint half_bit(); return (longint'(cfg.div) + 1) / 2 + 8; endfunction
        function bit rx_sure(); return !rx_loose && rx_way.size() == 0 && cyc > rx_unsure_until; endfunction
        function bit tx_sure(); return !tx_loose && cyc > tx_unsure_until; endfunction
        function bit thre(); return tx_fifo.size() == 0; endfunction
        function bit temt(); return tx_fifo.size() == 0 && tx_line.size() == 0; endfunction

        // a byte enters the receive FIFO, or is held, or is lost
        function void rx_arrive(uart_rx_t b);
            if (rx_fifo.size() < FIFO_N) begin rx_fifo.push_back(b); cov.cg_uart_fifo.sample(1, rx_fifo.size()); rx_over = 0; end
            else begin
                rx_over++; cov.cg_uart_fifo.sample(1, FIFO_N + rx_over);
                if (!rx_held_v) begin rx_held = b; rx_held_v = 1; end        // the receiver waits with it; later ones are lost (F17)
            end
            rx_unsure_until = cyc + 6;
        endfunction

        // ---- the line agent sent a frame: its stop bit starts now
        function void write_rxf(uart_frame f);
            uart_rx_t b;
            b.data = f.data; b.pe = f.bad_parity; b.fe = f.bad_stop;
            if (rx_loose) return;
            // the receiver samples the stop bit half a bit after it starts by its own count, which a
            // sender 4 percent off has moved by up to 0.4 bit: by the end of the stop bit it has the byte
            rx_way.push_back(b); rx_way_by.push_back(cyc + (longint'(cfg.div) + 1) + 12);
            cov.cg_uart_fmt.sample(1, cfg.bits, cfg.parity, cfg.stop2);
            cov.cg_uart_baud.sample(1, f.skew); cov.cg_uart_baud.sample(2, f.gap);
        endfunction

        // ---- a frame starts or ends on tx
        function void write_txe(uart_tx_ev e);
            if (e.kind == UART_TX_START) begin
                if (tx_fifo.size() != 0) tx_line.push_back(tx_fifo.pop_front());
                else if (!tx_loose) err("sb_tx", "a frame started on tx with nothing written to send");
                tx_unsure_until = cyc + 5;
                return;
            end
            // the whole frame
            cov.cg_uart_fmt.sample(0, cfg.bits, cfg.parity, cfg.stop2);
            cov.cg_uart_baud.sample(0, cfg.div);
            tx_unsure_until = cyc + half_bit() + (cfg.stop2 ? longint'(cfg.div) + 1 : 0);
            if (tx_loose) begin tx_line.delete(); return; end
            if (tx_line.size() == 0) return;
            begin
                bit [7:0] exp = tx_line.pop_front() & cfg.mask();
                n_tx_cmp++;
                if (e.f.data !== exp) err("sb_tx", $sformatf("frame %02h on tx, the byte written was %02h", e.f.data, exp));
                if (!e.f.parity_ok)   err("sb_tx", $sformatf("frame %02h on tx with the wrong parity bit", e.f.data));
                if (!e.f.stop_ok)     err("sb_tx", $sformatf("frame %02h on tx with a stop bit low", e.f.data));
                n_period++;
                // n bits after the start edge, within one pclk (the vendored transmitter's start bit is
                // one pclk longer than its other bits) and 1 percent ([N-7.1])
                begin
                    real want = e.f.n_last * cfg.bit_ns(), off = e.f.t_last - want;
                    if (off < -0.01 * want - 0.5 || off > 0.01 * want + PCLK_NS + 0.5)
                        err("sb_bit_period", $sformatf("the last edge of a frame on tx came %0.1f ns after the start edge; %0d bits at divisor %0d are %0.1f ns", e.f.t_last, e.f.n_last, cfg.div, want));
                end
            end
        endfunction

        // ---- every pclk cycle
        function void write_cyc(uart_cycle_item it);
            bit lvl[3], lsure[3];
            cyc++;
            if (!it.preset_n) begin
                reset_model();
                if (it.tx !== 1'b1) err("sb_tx", "tx low in reset");
                if (it.irq !== 1'b0) err("sb_irqstat", "irq high in reset");
                return;
            end
            if (it.pready !== 1'b1) err("sb_pready", "PREADY low");
            // frames whose stop bit has been sampled by now are in the FIFO
            while (rx_way.size() != 0 && cyc >= rx_way_by[0]) begin rx_arrive(rx_way.pop_front()); void'(rx_way_by.pop_front()); end
            // the three conditions the interrupt flags follow, and whether the model is sure of them
            lvl[0] = rx_fifo.size() != 0;                                lsure[0] = rx_sure();
            lvl[1] = thre();                                             lsure[1] = tx_sure();
            lvl[2] = rx_fifo.size() != 0 && (rx_fifo[0].pe || rx_fifo[0].fe); lsure[2] = rx_sure();
            foreach (irqs[i]) begin
                if (lsure[i] && lvl[i]) irqs[i].by(1, cyc + 8);                  // the wrapper polls LSR in idle cycles
                else if (!lsure[i] && !(irqs[i].val && !irqs[i].unk)) irqs[i].unknown();
            end
            // the DMA request, when nothing it depends on is changing ([N-7.6])
            if (rx_sure() && tx_sure() && !it.dma_ack && !prev_ack && cyc > rx_unsure_until + 4 && cyc > tx_unsure_until + 4) begin
                bit exp = ((dmactl[0] && lvl[0]) || (dmactl[1] && lvl[1])) && !dlab();
                if (it.dma_req !== exp) err("sb_dma", $sformatf("dma_req %0b, expected %0b (DMACTL %02b, %0d bytes received, %0d to send, DLAB %0b)",
                                                                it.dma_req, exp, dmactl, rx_fifo.size(), tx_fifo.size(), dlab()));
                if (exp && dmactl == 2'b01) cov.cg_uart_dma.sample((rx_fifo.size() == FIFO_N) ? 1 : (rx_fifo.size() == 1) ? 0 : -1);
                if (exp && dmactl == 2'b10) cov.cg_uart_dma.sample((tx_fifo.size() == 0) ? 2 : -1);
                if (exp && dmactl == 2'b11 && lvl[0] && lvl[1]) cov.cg_uart_dma.sample(4);
                if (dmactl != 0 && dlab() && (lvl[0] || lvl[1])) cov.cg_uart_dma.sample(5);
            end
            prev_ack = it.dma_ack;
            if (it.psel && it.penable) access(it);
        endfunction

        function void cmp(string id_, uart_cycle_item it, bit [31:0] exp);
            if (it.prdata !== exp) err(id_, $sformatf("read 0x%03h: DUT %08h, expected %08h", it.paddr, it.prdata, exp));
        endfunction

        function void access(uart_cycle_item it);
            bit m = mapped(it.paddr); bit [7:0] d = it.pwdata[7:0];
            if (it.pslverr !== !m) err("sb_pslverr", $sformatf("%s 0x%03h: PSLVERR %0b, expected %0b", it.pwrite ? "write" : "read", it.paddr, it.pslverr, !m));
            if (!m) begin if (!it.pwrite) cmp("sb_reg", it, 32'd0); return; end
            if (it.paddr < 12'h008) cov.cg_uart_reg.sample(0, dlab(), it.paddr[2], it.pwrite, 0);
            if (it.pwrite) begin
                n_wr++;
                case (it.paddr)
                    12'h000: if (dlab()) dll = d;
                             else begin                                          // THR
                                 if (tx_fifo.size() < FIFO_N) begin tx_fifo.push_back(d); cov.cg_uart_fifo.sample(0, tx_fifo.size()); end
                                 else cov.cg_uart_fifo.sample(0, FIFO_N + 1);        // full: the byte is dropped (F16)
                                 tx_unsure_until = cyc + 5;
                                 if (dmactl == 2'b10 && tx_fifo.size() >= FIFO_N - 2) cov.cg_uart_dma.sample(3);
                             end
                    12'h004: if (dlab()) dlm = d; else begin ier = d; cov.cg_uart_reg.sample(1, 0, 0, 1, d); end
                    12'h008: begin                                               // FCR
                        if (d[1]) begin
                            cov.cg_uart_fcr.sample(1, (rx_fifo.size() == 0) ? 0 : (rx_fifo.size() == FIFO_N) ? 2 : 1);
                            rx_fifo.delete(); rx_unsure_until = cyc + 6;
                            if (rx_held_v) begin rx_fifo.push_back(rx_held); rx_held_v = 0; end   // the byte the receiver was holding goes in
                        end
                        if (d[2]) begin
                            cov.cg_uart_fcr.sample(0, (tx_fifo.size() == 0) ? ((tx_line.size() != 0) ? 3 : 0) : (tx_fifo.size() == FIFO_N) ? 2 : 1);
                            tx_fifo.delete(); tx_unsure_until = cyc + 5;
                        end
                    end
                    12'h00C: lcr = d;
                    12'hFE0: for (int i = 0; i < 3; i++) if (it.pwdata[i]) begin
                                 bit lv = (i == 0) ? rx_fifo.size() != 0 : (i == 1) ? thre() : (rx_fifo.size() != 0 && (rx_fifo[0].pe || rx_fifo[0].fe));
                                 bit su = (i == 1) ? tx_sure() : rx_sure();
                                 if (!su) irqs[i].unknown();
                                 else if (lv) begin irqs[i].unknown(); irqs[i].by(1, cyc + 8); end      // the condition is still true: it sets again
                                 else irqs[i].now(0);
                                 if (su) cov.cg_uart_irq.sample(i, 0, lv);
                             end
                    12'hFE4: irqen  = it.pwdata[2:0];
                    12'hFE8: dmactl = it.pwdata[1:0];
                    default: ;                                                   // MCR, LSR, MSR, SCR and ID: a write does nothing
                endcase
            end else begin
                n_rd++;
                case (it.paddr)
                    12'h000: if (dlab()) cmp("sb_reg", it, {24'd0, dll});
                             else begin                                          // RBR
                                 // a byte whose stop bit is on the line has arrived if firmware reads it now
                                 if (rx_fifo.size() == 0 && rx_way.size() != 0) begin rx_arrive(rx_way.pop_front()); void'(rx_way_by.pop_front()); end
                                 if (rx_fifo.size() != 0) begin
                                     uart_rx_t b = rx_fifo.pop_front();
                                     n_rx_cmp++;
                                     if (!rx_loose && it.prdata !== {24'd0, b.data}) err("sb_rx", $sformatf("byte read %02h, the frame sent was %02h", it.prdata[7:0], b.data));
                                     if (rx_held_v) begin rx_fifo.push_back(rx_held); rx_held_v = 0; end
                                 end
                                 rx_unsure_until = cyc + 6;
                             end
                    12'h004: cmp("sb_reg", it, {24'd0, dlab() ? dlm : ier});
                    // IIR: "FIFOs present" in bits 7:6. The identification in bits 3:0 belongs to the 16550's
                    // own interrupt unit, which GARUDA does not use ([N-7.5]); its reset value is checked by the register test.
                    12'h008: if (it.prdata[31:4] !== 28'h000_000C) err("sb_reg", $sformatf("read 0x008: IIR %08h, bits 31:4 are 0x000000C", it.prdata));
                    12'h00C: cmp("sb_reg", it, {24'd0, lcr});
                    12'h014: begin                                               // LSR
                        bit [7:0] l = it.prdata[7:0];
                        if (it.prdata[31:8] !== 24'd0 || l[1] || l[4] || l[7]) err("sb_lsr", $sformatf("LSR %08h: a bit that is always 0 is set", it.prdata));
                        // a byte whose stop bit is on the line is in the FIFO once LSR shows it
                        if (l[0] && rx_fifo.size() == 0 && rx_way.size() != 0) begin rx_arrive(rx_way.pop_front()); void'(rx_way_by.pop_front()); rx_unsure_until = cyc; end
                        if (rx_sure()) begin
                            n_lsr_cmp++;
                            if (l[0] !== (rx_fifo.size() != 0)) err("sb_lsr", $sformatf("LSR.DR %0b with %0d bytes in the model's FIFO", l[0], rx_fifo.size()));
                            else if (l[0] && {l[3], l[2]} !== {rx_fifo[0].fe, rx_fifo[0].pe})
                                err("sb_lsr", $sformatf("LSR FE %0b PE %0b, the byte at the head (%02h) was sent with FE %0b PE %0b", l[3], l[2], rx_fifo[0].data, rx_fifo[0].fe, rx_fifo[0].pe));
                        end else n_lsr_skip++;
                        if (tx_sure()) begin
                            n_lsr_cmp++;
                            if (l[5] !== thre()) err("sb_fifo", $sformatf("LSR.THRE %0b with %0d bytes in the model's transmit FIFO", l[5], tx_fifo.size()));
                            if (l[6] !== temt()) err("sb_fifo", $sformatf("LSR.TEMT %0b with %0d bytes to send and %0d on the line", l[6], tx_fifo.size(), tx_line.size()));
                        end else n_lsr_skip++;
                    end
                    12'h010, 12'h018, 12'h01C: cmp("sb_reg", it, 32'd0);        // MCR, MSR, SCR: not implemented
                    12'hFE0: begin
                        string nm[3] = '{"receive data", "transmit empty", "line error"};
                        foreach (irqs[i]) if (irqs[i].check(it.prdata[i], cyc))
                            err("sb_irqstat", $sformatf("IRQSTAT bit %0d (%s) reads %0b, expected %0b", i, nm[i], it.prdata[i], irqs[i].val));
                        if (it.prdata[31:3] !== 29'd0) err("sb_irqstat", $sformatf("IRQSTAT upper bits %08h", it.prdata));
                        foreach (irqs[i]) if (it.prdata[i]) cov.cg_uart_irq.sample(i, irqen[i], -1);
                    end
                    12'hFE4: cmp("sb_reg", it, {29'd0, irqen});
                    12'hFE8: cmp("sb_reg", it, {30'd0, dmactl});
                    12'hFEC: cmp("sb_reg", it, {16'h6A5D, 8'd16 + 8'(vif.inst), 8'd1});
                    default: ;
                endcase
            end
        endfunction

        function void write_apb(apb_item it);
            cov.apb_access(it, mapped(it.addr));
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SB", $sformatf("uart_scoreboard: %0d reads, %0d writes; %0d frames on tx compared, %0d bit periods; %0d bytes read compared; LSR halves compared %0d, in transition %0d; %0d mismatches",
                                      n_rd, n_wr, n_tx_cmp, n_period, n_rx_cmp, n_lsr_cmp, n_lsr_skip, n_err), UVM_NONE)
            if ((n_rd + n_wr) == 0) `uvm_error("SB", "the scoreboard compared nothing")
        endfunction
    endclass

    // ------------------------------------------------------------------ environment
    class uart_env extends uvm_env;
        `uvm_component_utils(uart_env)
        apb_agent       apb;
        uart_line_agent line_agt;
        uart_monitor    mon;
        uart_scoreboard sb;
        uart_coverage   cov;
        uart_reg_pkg::uart regmodel;
        apb_reg_adapter adapter;
        uvm_reg_predictor #(apb_item) predictor;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            apb  = apb_agent::type_id::create("apb", this);
            line_agt = uart_line_agent::type_id::create("line_agt", this);
            mon  = uart_monitor::type_id::create("mon", this);
            sb   = uart_scoreboard::type_id::create("sb", this);
            cov  = uart_coverage::type_id::create("cov", this);
            sb.cov = cov; sb.cfg = line_agt.cfg; sb.line = line_agt.line;
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
            line_agt.mon.ap.connect(sb.txe_imp);
            line_agt.drv.ap.connect(sb.rxf_imp);
            regmodel.default_map.set_sequencer(apb.sqr, adapter);
            regmodel.default_map.set_auto_predict(0);
            predictor.map = regmodel.default_map; predictor.adapter = adapter;
            apb.mon.ap.connect(predictor.bus_in);
        endfunction
    endclass

    `include "uart_test_lib.svh"
endpackage
