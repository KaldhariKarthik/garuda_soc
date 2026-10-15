`timescale 1ns/1ps
// =============================================================================
// apb_target.sv -- APB3 target model for the bridge environment (Track A bus plan B2)
//
// One instance per window, on pclk. Configured by the test through its variables:
//   wait_fix >= 0   exactly this many ACCESS cycles with PREADY low before PREADY
//   wait_max        otherwise 0..wait_max low cycles, drawn per transfer
//   never_ready     PREADY never rises (the bridge's 16-sample timeout must end it)
//   err_lo/err_hi   PSLVERR for offsets in [err_lo, err_hi) when hi > lo
//   pop_off         an offset that behaves like a FIFO data register: each completed
//                   read pops the next value (fifo_q), so a duplicated or lost APB
//                   read is visible in the data (a side-effect sentinel)
// Every APB transfer it sees is logged in log_q (completed or abandoned by the
// bridge's timeout) and counted in n_side (side effects: completed writes and
// completed reads of the pop register). The target is the responder only; the
// protocol is checked by tb/common/apb_checker.v on the same wires.
// =============================================================================
module apb_target #(
    parameter int W = 0                        // window index (for messages)
)(
    input  wire        pclk,
    input  wire        preset_n,
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [11:0] paddr,
    input  wire [31:0] pwdata,
    output logic [31:0] prdata,
    output logic        pready,
    output logic        pslverr
);
    typedef struct {
        logic [11:0] addr;
        logic        write;
        logic [31:0] wdata;
        logic [31:0] rdata;
        logic        err;
        logic        abandoned;               // PSEL dropped with PREADY low (bridge timeout)
        longint      cyc;
    } apb_log_t;

    int          wait_fix = 0;
    int unsigned wait_max = 0;
    bit          never_ready = 1'b0;
    logic [11:0] err_lo = 12'd0, err_hi = 12'd0;
    int          pop_off = -1;
    logic [31:0] mem [logic [11:0]];
    logic [31:0] fifo_q [$];
    apb_log_t    log_q [$];
    int unsigned n_side = 0;
    longint      cyc = 0;

    function automatic logic [31:0] peek(input logic [11:0] a);
        return mem.exists({a[11:2], 2'b00}) ? mem[{a[11:2], 2'b00}] : {20'hA9B00 | W[3:0], a};
    endfunction
    function automatic void poke(input logic [11:0] a, input logic [31:0] d);
        mem[{a[11:2], 2'b00}] = d;
    endfunction

    int  left;                                  // low cycles still to give in this ACCESS
    bit  in_xfer;
    bit  done;                                  // this access already completed (PREADY seen high)
    // On a divided window the bridge holds PENABLE after PREADY (spec 6.2): the target
    // completes the access ONCE, at the first PREADY-high ACCESS cycle, and keeps PREADY
    // and PRDATA steady until PSEL drops (no second side effect, no re-arm).
    logic [31:0] rd_hold;
    assign prdata = (psel && penable && pready && !pwrite && done) ? rd_hold :
                    (psel && penable && pready && !pwrite) ?
                    ((pop_off >= 0 && paddr == pop_off[11:0]) ? (fifo_q.size() ? fifo_q[0] : 32'd0) : peek(paddr)) : 32'd0;
    assign pslverr = psel && penable && pready && (err_hi > err_lo) && (paddr >= err_lo) && (paddr < err_hi);

    always @(posedge pclk or negedge preset_n) begin
        if (!preset_n) begin
            pready <= 1'b0; in_xfer <= 1'b0; left <= 0; done <= 1'b0;
        end else begin
            cyc++;
            if (psel && !penable) begin                         // SETUP: decide the wait
                in_xfer <= 1'b1; done <= 1'b0;
                left    <= (wait_fix >= 0) ? wait_fix : (wait_max ? $urandom_range(wait_max, 0) : 0);
                pready  <= (!never_ready) && ((wait_fix >= 0) ? wait_fix == 0 : wait_max == 0);
            end else if (psel && penable) begin                 // ACCESS
                if (done) begin
                    // extended ACCESS after completion: hold PREADY and the read data
                end else if (pready) begin                       // completes at this edge
                    automatic apb_log_t e;
                    e.addr = paddr; e.write = pwrite; e.wdata = pwdata; e.err = pslverr;
                    e.rdata = prdata; e.abandoned = 1'b0; e.cyc = cyc;
                    log_q.push_back(e);
                    if (!pslverr) begin
                        if (pwrite) begin poke(paddr, pwdata); n_side++; end
                        else if (pop_off >= 0 && paddr == pop_off[11:0] && fifo_q.size()) begin void'(fifo_q.pop_front()); n_side++; end
                    end
                    rd_hold <= prdata; done <= 1'b1; in_xfer <= 1'b0;
                end else begin
                    if (left > 1) left <= left - 1;
                    else if (!never_ready) pready <= 1'b1;
                end
            end else begin
                done <= 1'b0;
                if (in_xfer) begin                               // PSEL dropped without PREADY: abandoned
                    automatic apb_log_t e;
                    e.addr = paddr; e.write = pwrite; e.wdata = pwdata; e.err = 1'b1; e.rdata = 32'd0;
                    e.abandoned = 1'b1; e.cyc = cyc;
                    log_q.push_back(e);
                end
                pready <= 1'b0; in_xfer <= 1'b0;
            end
        end
    end
endmodule
