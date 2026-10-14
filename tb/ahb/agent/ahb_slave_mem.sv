`timescale 1ns/1ps
// =============================================================================
// ahb_slave_mem.sv -- AHB-Lite slave responder for block benches
// (Track A; DMA plan D4; the slave part of Karthik's plan 6A.1, for reuse by the
// interconnect, bridge and chip-bench work).
//
// One slave port, cycle-accurate, configured by the test through its variables
// and tasks (hierarchical access), seeded by the simulator seed (+verilator+seed):
//   - memory: sparse words; sub-word writes update only the lanes HSIZE and
//     HADDR[1:0] select; reads return the whole word (the master picks lanes);
//   - FIFO registers: up to 8 word addresses that behave like a peripheral data
//     register: a read pops the next value (0 when empty), a write pushes;
//   - wait states: 0..rwait_max on a read data phase, 0..wwait_max on a write
//     (or exactly rwait_fix / wwait_fix when those are >= 0);
//   - address-phase stalls: while no data phase is pending, HREADY may go low for
//     1..stall_max cycles (stall_pct % of idle cycles). On GARUDA's shared bus this
//     is what a master sees when another master holds the bus (lost arbitration);
//     it holds M3's address phase (vPlan F48, planted defect M19);
//   - ERROR: the legal two-cycle response (HRESP with HREADY low, then HRESP with
//     HREADY high), on the err_rd_n-th read / err_wr_n-th write after
//     clear_counts(), or on any access inside [err_lo, err_hi);
//   - a log of every completed transfer (log_q) for scoreboards and checkers.
// Interconnect mode (IC_MODE = 1, bus plan B1 A3): the slave sits behind
// ahb_interconnect. It takes an address phase on HSEL & HREADY (the global ready,
// input hready_in) & HTRANS[1]; `hready` is its HREADYOUT; with no data phase it
// drives HREADYOUT high (an interconnect slave never stalls an address phase:
// address-phase stalls come from arbitration, which the real interconnect does).
// With IC_MODE = 0 (the default, every DMA bench) hsel/hready_in are ignored and
// the behaviour is unchanged.
// HRDATA is 32'hDEAD_BEEF outside a read's final data cycle, so a master that
// samples it at the wrong time reads a recognisable value. A data phase with no
// wait completes in its first cycle (the response is decided when the address is
// accepted).
// =============================================================================
module ahb_slave_mem
    import ahb_agent_pkg::*;
#(
    parameter bit IC_MODE = 1'b0
)(
    input  wire        hclk,
    input  wire        hreset_n,
    input  wire        hsel,          // IC_MODE only
    input  wire        hready_in,     // IC_MODE only: the interconnect's global HREADY
    input  wire [31:0] haddr,
    input  wire [1:0]  htrans,
    input  wire        hwrite,
    input  wire [2:0]  hsize,
    input  wire [31:0] hwdata,
    output logic [31:0] hrdata,
    output logic        hready,
    output logic        hresp
);
    // ---- configuration (the test sets these) -------------------------------------
    int unsigned rwait_max = 0, wwait_max = 0;
    int          rwait_fix = -1, wwait_fix = -1;     // >= 0: exactly this many waits (cycle-exact sweeps)
    int unsigned stall_max = 0, stall_pct = 0;
    int          err_rd_n = -1, err_wr_n = -1;        // 0 = first read/write after clear_counts()
    logic [31:0] err_lo = 32'd0, err_hi = 32'd0;      // ERROR on [err_lo, err_hi) when hi > lo

    // ---- state -----------------------------------------------------------------------
    logic [31:0] mem [logic [31:0]];
    logic [31:0] fifo_addr [8];
    logic        fifo_used [8];
    logic [31:0] fifo_q [8][$];
    int          n_rd = 0, n_wr = 0;                   // transfers accepted since clear_counts()

    ahb_agent_pkg::ahb_txn_t log_q [$];

    logic        dp, dp_wr, dp_err;
    logic [31:0] dp_addr;
    logic [2:0]  dp_size;
    int unsigned dp_wait;
    logic        err2;                                 // second cycle of an ERROR comes next
    int unsigned stall;

    initial for (int i = 0; i < 8; i++) begin fifo_used[i] = 1'b0; fifo_addr[i] = 32'd0; end

    // ---- tasks for the test ------------------------------------------------------------
    function automatic void clear_counts();
        n_rd = 0; n_wr = 0;
    endfunction
    function automatic void poke(input logic [31:0] a, input logic [31:0] d);
        mem[{a[31:2], 2'b00}] = d;
    endfunction
    function automatic logic [31:0] peek(input logic [31:0] a);
        return mem.exists({a[31:2], 2'b00}) ? mem[{a[31:2], 2'b00}] : 32'd0;
    endfunction
    function automatic int fifo_index(input logic [31:0] a);
        for (int i = 0; i < 8; i++) if (fifo_used[i] && fifo_addr[i] == {a[31:2], 2'b00}) return i;
        return -1;
    endfunction
    function automatic void fifo_add(input logic [31:0] a);
        for (int i = 0; i < 8; i++) if (!fifo_used[i]) begin
            fifo_used[i] = 1'b1; fifo_addr[i] = {a[31:2], 2'b00}; fifo_q[i].delete(); return;
        end
        $fatal(1, "ahb_slave_mem: more than 8 FIFO registers");
    endfunction
    function automatic void fifo_push(input logic [31:0] a, input logic [31:0] d);
        int i = fifo_index(a);
        if (i < 0) $fatal(1, "ahb_slave_mem: %08h is not a FIFO register", a);
        fifo_q[i].push_back(d);
    endfunction
    function automatic int fifo_level(input logic [31:0] a);
        int i = fifo_index(a);
        return (i < 0) ? -1 : fifo_q[i].size();
    endfunction
    function automatic void fifo_flush(input logic [31:0] a);
        int i = fifo_index(a);
        if (i >= 0) fifo_q[i].delete();
    endfunction
    function automatic logic [31:0] fifo_pop(input logic [31:0] a);
        int i = fifo_index(a);
        if (i < 0 || fifo_q[i].size() == 0) return 32'd0;
        return fifo_q[i].pop_front();
    endfunction

    function automatic logic [31:0] merge(input logic [31:0] old, input logic [31:0] wd,
                                          input logic [1:0] a, input logic [2:0] sz);
        logic [31:0] v = old;
        case (sz)
            3'd0:    v[8*a +: 8]     = wd[8*a +: 8];
            3'd1:    v[16*a[1] +: 16] = wd[16*a[1] +: 16];
            default: v = wd;
        endcase
        return v;
    endfunction

    function automatic logic [31:0] read_word(input logic [31:0] a);
        int i = fifo_index(a);
        if (i >= 0) return fifo_pop(a);
        return peek(a);
    endfunction

    // ---- the slave -----------------------------------------------------------------------
    always @(posedge hclk or negedge hreset_n) begin
        if (!hreset_n) begin
            hready <= 1'b1; hresp <= 1'b0; hrdata <= 32'hDEAD_BEEF;
            dp <= 1'b0; dp_wr <= 1'b0; dp_err <= 1'b0; dp_addr <= 32'd0; dp_size <= 3'd0;
            dp_wait <= 0; err2 <= 1'b0; stall <= 0;
        end else begin
            automatic logic done, take;
            done = dp && hready;                           // the pending data phase ends at this edge
            take = IC_MODE ? (hsel && hready_in && htrans[1])  // an address phase is accepted at this edge
                           : (hready && htrans[1]);
            hrdata <= 32'hDEAD_BEEF;
            // -- finish the data phase that ends now
            if (done) begin
                if (dp_wr && !dp_err) begin
                    automatic int i = fifo_index(dp_addr);
                    if (i >= 0) fifo_q[i].push_back(hwdata);
                    else        mem[{dp_addr[31:2], 2'b00}] = merge(peek(dp_addr), hwdata, dp_addr[1:0], dp_size);
                    log_q.push_back('{dp_addr, 1'b1, dp_size, hwdata, 1'b0});
                end else if (dp_err) begin
                    log_q.push_back('{dp_addr, dp_wr, dp_size, dp_wr ? hwdata : 32'd0, 1'b1});
                end
                dp <= 1'b0;
            end
            // -- accept a new address phase; its first data cycle is decided here, so a
            //    zero-wait transfer completes in one data cycle
            if (take) begin
                automatic logic e;
                automatic int unsigned w;
                automatic logic [31:0] rw;
                e = (err_hi > err_lo && haddr >= err_lo && haddr < err_hi) ||
                    (!hwrite && err_rd_n >= 0 && n_rd == err_rd_n) ||
                    ( hwrite && err_wr_n >= 0 && n_wr == err_wr_n);
                w = hwrite ? ((wwait_fix >= 0) ? wwait_fix : (wwait_max > 0) ? $urandom_range(wwait_max, 0) : 0)
                           : ((rwait_fix >= 0) ? rwait_fix : (rwait_max > 0) ? $urandom_range(rwait_max, 0) : 0);
                if (hwrite) n_wr++; else n_rd++;
                dp <= 1'b1; dp_wr <= hwrite; dp_addr <= haddr; dp_size <= hsize; dp_err <= e;
                if (w > 0) begin
                    dp_wait <= w - 1; hready <= 1'b0; hresp <= 1'b0; err2 <= 1'b0;   // first wait cycle
                end else if (e) begin
                    dp_wait <= 0; hready <= 1'b0; hresp <= 1'b1; err2 <= 1'b1;       // ERROR, first cycle
                end else begin
                    dp_wait <= 0; hready <= 1'b1; hresp <= 1'b0; err2 <= 1'b0;       // OKAY, zero wait
                    if (!hwrite) begin
                        rw = read_word(haddr);
                        hrdata <= rw;
                        log_q.push_back('{haddr, 1'b0, hsize, rw, 1'b0});
                    end
                end
            end else if (dp && !done) begin
                // -- inside a data phase
                if (err2) begin
                    hready <= 1'b1; hresp <= 1'b1; err2 <= 1'b0;         // ERROR, second cycle
                end else if (dp_wait > 0) begin
                    dp_wait <= dp_wait - 1; hready <= 1'b0; hresp <= 1'b0;
                end else if (dp_err) begin
                    hready <= 1'b0; hresp <= 1'b1; err2 <= 1'b1;         // ERROR, first cycle
                end else begin
                    hready <= 1'b1; hresp <= 1'b0;                        // OKAY
                    if (!dp_wr) begin
                        automatic logic [31:0] w = read_word(dp_addr);
                        hrdata <= w;
                        log_q.push_back('{dp_addr, 1'b0, dp_size, w, 1'b0});
                    end
                end
            end else begin
                // -- no data phase pending: idle, or an address-phase stall
                hresp <= 1'b0;
                if (IC_MODE) begin
                    hready <= 1'b1;
                end else if (stall > 0) begin
                    stall <= stall - 1; hready <= (stall == 1);
                end else if (stall_max > 0 && $urandom_range(99, 0) < stall_pct) begin
                    stall <= $urandom_range(stall_max, 1); hready <= 1'b0;
                end else
                    hready <= 1'b1;
            end
        end
    end
endmodule
