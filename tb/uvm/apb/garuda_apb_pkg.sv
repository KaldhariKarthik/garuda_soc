`timescale 1ns/1ps
// =============================================================================
// garuda_apb_pkg.sv - APB3 master agent shared by every block environment.
//
//   apb_item      one access: offset, direction, write data; response fields
//                 (read data, PSLVERR, wait states) filled in by the driver
//                 and by the monitor
//   apb_driver    SETUP for one pclk, ACCESS until PREADY, optional idle gap
//   apb_monitor   publishes every completed access on an analysis port
//   apb_agent     sequencer + driver + monitor
//   apb_reg_adapter  register-model bus adapter
//
// Word accesses only: the bridge rejects anything else before it reaches a
// peripheral (AHB2APB [N-7.12]).
// =============================================================================
package garuda_apb_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    class apb_item extends uvm_sequence_item;
        rand bit [11:0] addr;
        rand bit        write;
        rand bit [31:0] wdata;
        rand int unsigned idle;          // pclk cycles of idle after the access
             bit [31:0] rdata;
             bit        slverr;
             int unsigned waits;         // pclk cycles PREADY was low

        constraint c_idle { idle inside {[0:3]}; }

        `uvm_object_utils_begin(apb_item)
            `uvm_field_int(addr,   UVM_ALL_ON)
            `uvm_field_int(write,  UVM_ALL_ON)
            `uvm_field_int(wdata,  UVM_ALL_ON)
            `uvm_field_int(rdata,  UVM_ALL_ON)
            `uvm_field_int(slverr, UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "apb_item"); super.new(name); endfunction

        function string convert2string();
            return $sformatf("%s 0x%03h wdata=%08h rdata=%08h slverr=%0b",
                             write ? "WR" : "RD", addr, wdata, rdata, slverr);
        endfunction
    endclass

    typedef uvm_sequencer #(apb_item) apb_sequencer;

    class apb_driver extends uvm_driver #(apb_item);
        `uvm_component_utils(apb_driver)
        virtual garuda_apb_if vif;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual garuda_apb_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "apb_driver: no virtual interface")
        endfunction

        task idle_bus();
            vif.drv_cb.psel    <= 1'b0;
            vif.drv_cb.penable <= 1'b0;
            vif.drv_cb.pwrite  <= 1'b0;
        endtask

        task run_phase(uvm_phase phase);
            idle_bus();
            forever begin
                // a reset in the middle of an access abandons it
                fork
                    drive_items();
                    @(negedge vif.preset_n);
                join_any
                disable fork;
                // The chip's APB master (the bridge's pclk side) is reset asynchronously by
                // preset_n, so PSEL drops at once and an access in flight never completes.
                // A clocking-block drive would only take effect at the next pclk edge and
                // let that access land in the middle of the reset.
                vif.psel = 1'b0; vif.penable = 1'b0; vif.pwrite = 1'b0;
                idle_bus();
                if (req != null) begin
                    // the access in flight when the reset arrived is finished for the sequence
                    seq_item_port.item_done();
                    req = null;
                end
                wait (vif.preset_n === 1'b1);
            end
        endtask

        task drive_items();
            int unsigned idle;
            forever begin
                wait (vif.preset_n === 1'b1);
                seq_item_port.get_next_item(req);
                @(vif.drv_cb);
                forever begin
                    vif.drv_cb.psel    <= 1'b1;                 // SETUP
                    vif.drv_cb.penable <= 1'b0;
                    vif.drv_cb.pwrite  <= req.write;
                    vif.drv_cb.paddr   <= req.addr;
                    vif.drv_cb.pwdata  <= req.wdata;
                    @(vif.drv_cb);
                    vif.drv_cb.penable <= 1'b1;                 // ACCESS
                    req.waits = 0;
                    forever begin
                        @(vif.drv_cb);
                        if (vif.drv_cb.pready === 1'b1) break;
                        req.waits++;
                    end
                    req.rdata  = vif.drv_cb.prdata;
                    req.slverr = vif.drv_cb.pslverr;
                    idle = req.idle;
                    seq_item_port.item_done();
                    req = null;
                    // idle = 0 and the next access already waiting: back to back, PSEL stays high
                    if (idle == 0) seq_item_port.try_next_item(req);
                    if (req == null) break;
                end
                vif.drv_cb.psel    <= 1'b0;
                vif.drv_cb.penable <= 1'b0;
                repeat (idle) @(vif.drv_cb);
            end
        endtask
    endclass

    class apb_monitor extends uvm_monitor;
        `uvm_component_utils(apb_monitor)
        virtual garuda_apb_if vif;
        uvm_analysis_port #(apb_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual garuda_apb_if)::get(this, "", "vif", vif))
                `uvm_fatal("NOVIF", "apb_monitor: no virtual interface")
        endfunction

        task run_phase(uvm_phase phase);
            apb_item it;
            int unsigned waits = 0;
            forever begin
                @(vif.mon_cb);
                if (vif.preset_n !== 1'b1) begin waits = 0; continue; end
                if (vif.mon_cb.psel === 1'b1 && vif.mon_cb.penable === 1'b1) begin
                    if (vif.mon_cb.pready === 1'b1) begin
                        it = apb_item::type_id::create("it");
                        it.addr   = vif.mon_cb.paddr;
                        it.write  = vif.mon_cb.pwrite;
                        it.wdata  = vif.mon_cb.pwdata;
                        it.rdata  = vif.mon_cb.prdata;
                        it.slverr = vif.mon_cb.pslverr;
                        it.waits  = waits;
                        waits = 0;
                        ap.write(it);
                    end else waits++;
                end
            end
        endtask
    endclass

    class apb_agent extends uvm_agent;
        `uvm_component_utils(apb_agent)
        apb_sequencer sqr;
        apb_driver    drv;
        apb_monitor   mon;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            mon = apb_monitor::type_id::create("mon", this);
            if (get_is_active() == UVM_ACTIVE) begin
                sqr = apb_sequencer::type_id::create("sqr", this);
                drv = apb_driver::type_id::create("drv", this);
            end
        endfunction

        function void connect_phase(uvm_phase phase);
            if (get_is_active() == UVM_ACTIVE) drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // Register-model adapter: one register access is one APB access.
    class apb_reg_adapter extends uvm_reg_adapter;
        `uvm_object_utils(apb_reg_adapter)

        function new(string name = "apb_reg_adapter");
            super.new(name);
            supports_byte_enable = 0;
            provides_responses   = 0;
        endfunction

        virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
            apb_item it = apb_item::type_id::create("it");
            it.addr  = rw.addr[11:0];
            it.write = (rw.kind == UVM_WRITE);
            it.wdata = rw.data;
            it.idle  = 0;
            return it;
        endfunction

        virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
            apb_item it;
            if (!$cast(it, bus_item)) `uvm_fatal("ADAPT", "bus2reg: not an apb_item")
            rw.kind   = it.write ? UVM_WRITE : UVM_READ;
            rw.addr   = it.addr;
            rw.data   = it.write ? it.wdata : it.rdata;
            rw.status = it.slverr ? UVM_NOT_OK : UVM_IS_OK;
        endfunction
    endclass

    // One access from a sequence, with the response copied back.
    class apb_access_seq extends uvm_sequence #(apb_item);
        `uvm_object_utils(apb_access_seq)
        rand bit [11:0] addr;
        rand bit        write;
        rand bit [31:0] wdata;
        rand int unsigned idle;
             bit [31:0] rdata;
             bit        slverr;
        constraint c_idle { idle inside {[0:3]}; }

        function new(string name = "apb_access_seq"); super.new(name); endfunction

        task body();
            req = apb_item::type_id::create("req");
            start_item(req);
            req.addr = addr; req.write = write; req.wdata = wdata; req.idle = idle;
            finish_item(req);
            rdata = req.rdata; slverr = req.slverr;
        endtask
    endclass
endpackage
