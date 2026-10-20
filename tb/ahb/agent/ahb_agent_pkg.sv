`timescale 1ns/1ps
// ahb_agent_pkg.sv -- types shared by the AHB-Lite bench agents (Track A, DMA plan D4)
package ahb_agent_pkg;
    // one completed AHB transfer, as a slave saw it
    typedef struct packed {
        logic [31:0] addr;
        logic        write;
        logic [2:0]  size;
        logic [31:0] data;     // write data, or the read word returned
        logic        err;      // answered with ERROR
    } ahb_txn_t;
    // one item a master agent presents (tb/ahb/agent/ahb_master_agent.sv, bus plan B1)
    typedef struct {
        logic [31:0] addr;
        logic        write;
        logic [2:0]  size;
        logic        incr;        // HBURST INCR (else SINGLE)
        logic        seq;         // present as SEQ (continues the previous beat)
        logic [31:0] wdata;
        int unsigned gap;         // IDLE cycles before this item may be presented
        int unsigned tag;         // issue number (for the scoreboard)
    } ahb_item_t;
    // one transfer a master agent completed, as the master saw it
    typedef struct {
        logic [31:0] addr;
        logic        write;
        logic [2:0]  size;
        logic [31:0] wdata;
        logic [31:0] rdata;
        logic        err;
        int unsigned tag;
        longint      cyc;         // cycle the data phase completed
    } ahb_done_t;
endpackage
