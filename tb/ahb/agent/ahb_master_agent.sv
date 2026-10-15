`timescale 1ns/1ps
// =============================================================================
// ahb_master_agent.sv -- AHB-Lite master agent for block and env benches
// (Track A bus plan B1 phase A3; the master half of Karthik's plan 6A.1).
//
// Plain SystemVerilog shaped like a UVM agent: a sequencer (the item queue the
// test fills with push()), a driver (the always block: a compliant, registered
// AHB-Lite master), and a monitor (every completed transfer goes to done_q with
// its response, read data and the cycle it completed). The test drives it by
// hierarchical calls, like ahb_slave_mem.
//
// Shapes of the four GARUDA masters (set per instance by the bench):
//   idle_in_dp = 0  the next address phase is presented during the current data
//                   phase (pipelined): the I-port. Back-to-back with gap 0 is the
//                   shape that starved the first arbiter (AHB-2).
//   idle_in_dp = 1  HTRANS is IDLE for the whole data phase: the D-port, the
//                   debug SBA and the DMA (dma_engine.v E_RD / E_WD).
//   cancel_on_err   0 (default): a presented transfer is held until accepted,
//                   even through an ERROR (the I-port since BUS-C). 1: after the
//                   first cycle of an ERROR in its own data phase the agent drops
//                   the next transfer to IDLE, as AHB-Lite allows, and presents it
//                   again later (used to reproduce AHB-7's slave-side retraction).
// An item with burst = 1 (INCR) and seq = 1 is presented as SEQ; the test makes
// it continue the previous beat at +4 (the I-port's fetch bursts).
//
// Sampling: everything is decided at posedge from registered outputs and the
// interconnect's combinational HREADY/HRESP/HRDATA, so one edge = one bus cycle.
// =============================================================================
module ahb_master_agent #(
    parameter int        ID    = 0,
    parameter logic [3:0] HPROT = 4'b0011
)(
    input  wire         hclk,
    input  wire         hreset_n,
    output logic [31:0] haddr,
    output logic [1:0]  htrans,
    output logic        hwrite,
    output logic [2:0]  hsize,
    output logic [2:0]  hburst,
    output logic [3:0]  hprot,
    output logic [31:0] hwdata,
    input  wire  [31:0] hrdata,
    input  wire         hready,
    input  wire         hresp
);
    typedef ahb_agent_pkg::ahb_item_t item_t;
    typedef ahb_agent_pkg::ahb_done_t done_t;

    // ---- configuration ----------------------------------------------------------
    bit idle_in_dp    = 1'b0;
    bit cancel_on_err = 1'b0;

    // ---- driver state -----------------------------------------------------------------
    item_t       ap, dp;               // the address phase being presented / the data phase
    logic        ap_v, dp_v;
    int unsigned gap_cnt;
    logic        gap_armed;
    logic        need_nonseq;          // the last cycle presented was IDLE: a burst restarts with NONSEQ

    // ---- sequencer / monitor state ------------------------------------------------
    item_t       q[$];
    done_t       done_q[$];
    int unsigned n_issued = 0, n_cancel = 0;
    longint      cyc = 0;

    function automatic void push(input logic [31:0] a, input bit w, input logic [31:0] d,
                                 input logic [2:0] sz = 3'd2, input int unsigned gap = 0,
                                 input bit incr = 1'b0, input bit seq = 1'b0);
        item_t it;
        it.addr = a; it.write = w; it.size = sz; it.incr = incr; it.seq = seq;
        it.wdata = d; it.gap = gap; it.tag = n_issued;
        n_issued++;
        q.push_back(it);
    endfunction
    function automatic bit busy();
        return (q.size() != 0) || ap_v || dp_v;
    endfunction
    function automatic void flush();               // reset: forget everything in flight
        q.delete(); done_q.delete(); n_issued = 0; n_cancel = 0;
    endfunction

    // ---- driver ---------------------------------------------------------------------
    assign hprot = HPROT;

    always @(posedge hclk or negedge hreset_n) begin
        if (!hreset_n) begin
            haddr <= 32'd0; htrans <= 2'b00; hwrite <= 1'b0; hsize <= 3'd2; hburst <= 3'd0;
            hwdata <= 32'd0; ap_v <= 1'b0; dp_v <= 1'b0; gap_cnt <= 0; gap_armed <= 1'b0;
            need_nonseq <= 1'b1;
        end else begin
            automatic logic ap_n = ap_v, dp_n = dp_v, cancelled = 1'b0;
            automatic item_t dp_new = dp;
            cyc++;
            // 1) the data phase in flight completes
            if (dp_v && hready) begin
                automatic done_t d;
                d.addr = dp.addr; d.write = dp.write; d.size = dp.size; d.wdata = dp.wdata;
                d.rdata = hrdata; d.err = hresp; d.tag = dp.tag; d.cyc = cyc;
                done_q.push_back(d);
                dp_n = 1'b0;
            end
            // 2) the presented address phase is accepted
            if (ap_v && hready) begin
                dp_new = ap; dp_n = 1'b1; ap_n = 1'b0;
                hwdata <= ap.write ? ap.wdata : 32'd0;
            end
            // 2b) AHB-Lite cancel after the first ERROR cycle (optional): the next
            //     transfer is dropped to IDLE, and nothing new is presented in the
            //     cycle after the ERROR first cycle (FA-4 of tb/ahb/formal)
            if (cancel_on_err && dp_v && !hready && hresp) begin
                if (ap_v) begin q.push_front(ap); n_cancel++; end
                ap_n = 1'b0; cancelled = 1'b1;
            end
            dp <= dp_new; dp_v <= dp_n;
            // 3) present the next address phase, or IDLE
            if (!ap_n) begin
                automatic bit may = (q.size() != 0) && (!idle_in_dp || !dp_n) && !cancelled;
                // the arming cycle is the first of `gap` IDLE cycles
                if (may && !gap_armed && q[0].gap != 0) begin gap_cnt <= q[0].gap - 1; gap_armed <= 1'b1; end
                if (may && ((gap_armed && gap_cnt == 0) || (!gap_armed && q[0].gap == 0))) begin
                    automatic item_t it = q.pop_front();
                    ap <= it; ap_n = 1'b1; gap_armed <= 1'b0;
                    haddr <= it.addr; hwrite <= it.write; hsize <= it.size;
                    hburst <= it.incr ? 3'b001 : 3'b000;
                    // like the I-port (BUS-B): after any IDLE cycle a burst re-opens with NONSEQ
                    htrans <= (it.seq && !need_nonseq) ? 2'b11 : 2'b10;
                    need_nonseq <= 1'b0;
                end else begin
                    if (gap_armed && gap_cnt != 0) gap_cnt <= gap_cnt - 1;
                    htrans <= 2'b00;
                    need_nonseq <= 1'b1;
                end
            end
            ap_v <= ap_n;
        end
    end
endmodule
