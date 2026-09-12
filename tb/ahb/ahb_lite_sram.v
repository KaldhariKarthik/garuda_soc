`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - VERIFICATION MODEL
// ahb_lite_sram.v - AHB-Lite slave with HSEL + HREADY, byte enables, waits
//
// STATUS: this is a VERIFICATION MODEL, not SoC RTL. It stands in for Blocks
// 3 (Instruction SRAM), 4 (Data SRAM) and 5 (Boot ROM), whose design
// specifications have not been written yet. It lives in tb/ for that reason
// and must not migrate into rtl/ - when those specs land, the real memories
// replace it and this file stays where it is, as the thing that proved the
// interconnect before they existed.
//
// -----------------------------------------------------------------------------
// WHY NOT rtl/ahb/ahb_mem_slave.v
// -----------------------------------------------------------------------------
// That model predates the interconnect and cannot sit on it: it has no HSEL
// input and no HREADY input, because it was written for a world where each
// master was wired straight to its own port of a dual-ported memory (its own
// header says so). A slave on a shared layer needs both:
//   HSEL     - it is one of five slaves and must only answer when addressed;
//   HREADY   - the address phase is accepted on the GLOBAL ready, which is
//              some other slave's HREADYOUT whenever that other slave owns the
//              data phase. A slave that latches on its own HREADYOUT instead
//              will capture transfers that were never accepted.
// That second point is the one that actually bites, and it is invisible until
// two slaves are used back to back.
//
// -----------------------------------------------------------------------------
// PROTOCOL
// -----------------------------------------------------------------------------
//   address phase accepted when  HSEL && HREADY && HTRANS[1]
//   data phase follows; HREADYOUT low for the drawn wait count
//   deselected or idle           HREADYOUT=1, HRESP=OKAY   (AMBA requires this;
//                                a slave holding HREADYOUT low while not
//                                selected stalls the entire shared layer)
//   in-region but out of SIZE_BYTES, or inside the injected error window
//                                two-cycle ERROR (HREADY=0/HRESP=1, then
//                                HREADY=1/HRESP=1) - mandatory per
//                                GARUDA-AHB-SPEC-001 Sec. 1.4, and load-bearing
//                                for dma_ahb_master's write-address cancel
//
// Wait states are drawn from a local xorshift PRNG, never $random: Icarus
// Verilog 14 accepts $random(seed) and silently ignores the seed, so a seed
// sweep built on it repeats one stimulus N times and reports N passes (see
// TOOL-4 in docs/DMA_RTL_LOG.md). Seeds here reproduce on any simulator.
//
// READ_ONLY=1 makes the model a ROM: writes are accepted on the bus (OKAY, no
// error) but discarded, which is what a boot ROM does. Preload with bd_load_hex
// or bd_write.
// =============================================================================

module ahb_lite_sram #(
    parameter [31:0]  BASE_ADDR  = 32'h0000_0000,
    parameter integer SIZE_BYTES = 65536,
    parameter integer READ_ONLY  = 0,
    parameter integer SEED       = 32'h1357_9BDF
)(
    input  wire        hclk_i,
    input  wire        hreset_n_i,

    // Wait-state injection. Inputs rather than parameters so one elaboration
    // covers every timing configuration in a regression.
    input  wire [7:0]  waits_i,
    input  wire        rand_waits_i,

    // PRNG seed, sampled out of reset. An INPUT, not just the SEED parameter:
    // a parameter is fixed at elaboration, so a regression that sweeps a
    // +SEED plusarg over a single build would draw byte-identical wait states
    // on every run and report N passes for one stimulus. That is precisely
    // TOOL-4 in docs/BUGS.md wearing different clothes, and it was caught here
    // by a seed sweep whose reported numbers did not move. The parameter is
    // kept as a per-instance salt so that four slaves in one testbench do not
    // all stall on the same cycles.
    input  wire [31:0] seed_i,

    // Error-injection window (absolute addresses)
    input  wire        err_en_i,
    input  wire [31:0] err_base_i,
    input  wire [31:0] err_size_i,

    // AHB-Lite slave port
    input  wire        hsel_i,
    input  wire [31:0] haddr_i,
    input  wire [1:0]  htrans_i,
    input  wire        hwrite_i,
    input  wire [2:0]  hsize_i,
    input  wire [31:0] hwdata_i,
    input  wire        hready_i,        // GLOBAL HREADY
    output wire [31:0] hrdata_o,
    output wire        hreadyout_o,
    output wire        hresp_o
);

    localparam integer NWORDS = SIZE_BYTES/4;

    reg [31:0] mem [0:NWORDS-1];

    integer k;
    initial for (k = 0; k < NWORDS; k = k + 1) mem[k] = 32'h0000_0000;

    // ---- data-phase state --------------------------------------------------
    reg        dp_valid;      // a transfer is in its data phase here
    reg        dp_write;
    reg [31:0] dp_addr;
    reg [2:0]  dp_size;
    reg [7:0]  wcnt;
    reg        dp_err;
    reg        err2;          // second (completing) cycle of the ERROR response

    // ---- address-phase qualification --------------------------------------
    wire in_region  = (haddr_i[31:28] == BASE_ADDR[31:28]);
    wire in_size    = (haddr_i >= BASE_ADDR) && (haddr_i < (BASE_ADDR + SIZE_BYTES));
    wire in_err_win = err_en_i && (haddr_i >= err_base_i) &&
                                  (haddr_i <  (err_base_i + err_size_i));

    // Accept only on the GLOBAL ready - see header.
    wire accept = hsel_i && hready_i && htrans_i[1];

    // -----------------------------------------------------------------------
    // HREADYOUT / HRESP. High and OKAY whenever nothing is in flight here, so
    // a deselected slave never stalls the layer.
    // -----------------------------------------------------------------------
    assign hreadyout_o = (wcnt == 8'd0) && !(dp_err && !err2);
    assign hresp_o     = dp_err;

    wire [31:0] widx = (dp_addr - BASE_ADDR) >> 2;

    assign hrdata_o = (dp_valid && !dp_write && !dp_err) ? mem[widx[30:0]]
                                                         : 32'h0000_0000;

    // -----------------------------------------------------------------------
    // Byte-enable merge from HSIZE / HADDR[1:0]
    // -----------------------------------------------------------------------
    function [31:0] merge;
        input [31:0] old_w;
        input [31:0] new_w;
        input [2:0]  hsz;
        input [1:0]  aoff;
        begin
            merge = old_w;
            case (hsz)
                3'b000: case (aoff)
                            2'd0: merge[ 7: 0] = new_w[ 7: 0];
                            2'd1: merge[15: 8] = new_w[15: 8];
                            2'd2: merge[23:16] = new_w[23:16];
                            2'd3: merge[31:24] = new_w[31:24];
                        endcase
                3'b001: if (aoff[1]) merge[31:16] = new_w[31:16];
                        else         merge[15: 0] = new_w[15: 0];
                default: merge = new_w;
            endcase
        end
    endfunction

    // -----------------------------------------------------------------------
    // Local xorshift PRNG for the wait-state draw (see header, TOOL-4)
    // -----------------------------------------------------------------------
    reg [31:0] prng;

    function [31:0] xs32;
        input [31:0] s;
        reg   [31:0] x;
        begin
            x = s;
            x = x ^ (x << 13);
            x = x ^ (x >> 17);
            x = x ^ (x << 5);
            xs32 = x;
        end
    endfunction

    // The draw is a pure combinational function of the CURRENT prng value and
    // the generator is advanced by a non-blocking assignment in the sequencer.
    // An earlier version mutated prng inside a function called from the
    // sequencer; that works, but it puts a blocking write to a sequential
    // register inside a clocked block, which simulators are free to schedule
    // differently and which lint flags. One driver, one assignment style.
    wire [7:0] wdraw = (!rand_waits_i || waits_i == 8'd0)
                         ? waits_i
                         : (prng[15:8] % (waits_i + 8'd1));

    // -----------------------------------------------------------------------
    // Sequencer
    // -----------------------------------------------------------------------
    // Branch order is load-bearing. The wait-state burn comes FIRST, before the
    // error response, because HREADYOUT is low for both and an error that
    // jumped the queue would leave wcnt non-zero after the response completed -
    // which pins HREADYOUT low forever and hangs the layer. The observable
    // behaviour is "N wait states, then the two-cycle ERROR", which is what a
    // real slave that discovers the fault after an access latency does.
    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            dp_valid <= 1'b0;
            dp_write <= 1'b0;
            dp_addr  <= 32'b0;
            dp_size  <= 3'b010;
            wcnt     <= 8'd0;
            dp_err   <= 1'b0;
            err2     <= 1'b0;
            prng     <= ((seed_i ^ SEED) == 32'd0) ? 32'h1 : (seed_i ^ SEED);
        end else if (wcnt != 8'd0) begin
            wcnt <= wcnt - 8'd1;

        end else if (dp_err && !err2) begin
            // ERROR cycle 1 is being driven now (HREADYOUT=0, HRESP=ERROR).
            // This is the warning cycle dma_ahb_master uses to retract its
            // pipelined write address phase.
            err2 <= 1'b1;

        end else if (dp_err && err2) begin
            // ERROR cycle 2 is being driven now (HREADYOUT=1, HRESP=ERROR), so
            // a new address phase CAN be accepted in this same cycle. The write
            // is deliberately not committed on any error path.
            dp_err   <= 1'b0;
            err2     <= 1'b0;
            dp_valid <= accept;
            if (accept) begin
                dp_write <= hwrite_i;
                dp_addr  <= haddr_i;
                dp_size  <= hsize_i;
                wcnt     <= wdraw;
                dp_err   <= !in_size || in_err_win;
            end

        end else begin
            // HREADYOUT is high here by construction (wcnt==0, no error
            // pending), so this is the cycle a data phase completes and the
            // next address phase is accepted.
            if (dp_valid && dp_write && (READ_ONLY == 0))
                mem[widx[30:0]] <= merge(mem[widx[30:0]], hwdata_i, dp_size, dp_addr[1:0]);

            dp_valid <= accept;
            if (accept) begin
                dp_write <= hwrite_i;
                dp_addr  <= haddr_i;
                dp_size  <= hsize_i;
                wcnt     <= wdraw;
                dp_err   <= !in_size || in_err_win;
            end else begin
                wcnt   <= 8'd0;
                dp_err <= 1'b0;
            end
        end

        // Advance the generator on every accepted transfer, so successive
        // accesses draw different wait counts rather than repeating one value
        // for the whole run. Outside the if/else chain because every accepting
        // branch above needs it and none of them should have to remember.
        if (hreset_n_i && accept) prng <= xs32(prng);
    end


    // -----------------------------------------------------------------------
    // Backdoor access for the testbench
    // -----------------------------------------------------------------------
    task bd_load_hex;
        input [1023:0] path;
        begin
            $readmemh(path, mem);
        end
    endtask

    task bd_write;
        input [31:0] byte_addr;
        input [31:0] data;
        begin
            mem[(byte_addr - BASE_ADDR) >> 2] = data;
        end
    endtask

    function [31:0] bd_read;
        input [31:0] byte_addr;
        begin
            bd_read = mem[(byte_addr - BASE_ADDR) >> 2];
        end
    endfunction

    // in_region is computed for readability of the decode intent but the
    // interconnect already guarantees it via HSEL; referenced here so lint
    // does not flag it.
    wire _unused_in_region = in_region;

endmodule

`default_nettype wire
