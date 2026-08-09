`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 9: DMA Controller - VERIFICATION MODEL
// dma_ahb_slave_model.sv - AHB-Lite slave: memory region + FIFO ports
//
// STATUS: verification only. Never compiled into a synthesis run, never
// instantiated by rtl/dma. It lives in tb/dma for exactly that reason.
//
// The address-phase/data-phase sequencer, the wait-state draw and the
// two-cycle ERROR response are modelled on rtl/ahb/ahb_mem_slave.v, which is
// already proven against the core's two AHB masters. Reusing that structure
// rather than inventing one means a protocol disagreement between this model
// and the DMA points at the DMA, not at a fresh bug in the model.
//
// WHY THIS ISN'T JUST ahb_mem_slave.v
// A DMA moving sensor data reads a peripheral FIFO at a FIXED address
// (CR.SINC=0). Against a plain memory, every one of those reads returns the
// same word - so a DMA that read the source once and replayed it 14 times, or
// that lost the ordering of beats entirely, would pass. The FIFO ports below
// return a DIFFERENT value per read and pop on completion, which makes beat
// ordering and beat count observable at the source. That is what turns the
// Sec. 14 "all 14 bytes arrive at DAR in correct order" criterion into a real
// check instead of a tautology.
//
// MEMORY MAP
//   [MEM_BASE,  MEM_BASE+MEM_BYTES)     word-addressable RAM, byte enables
//   [FIFO_BASE, FIFO_BASE+NFIFO*4)      one FIFO port per word address:
//                                         read  -> pops the read queue
//                                         write -> pushes the write queue
//   anything else                        two-cycle ERROR response
// =============================================================================

module dma_ahb_slave_model #(
    parameter [31:0]  MEM_BASE  = 32'h2000_0000,
    parameter integer MEM_BYTES = 8192,
    parameter [31:0]  FIFO_BASE = 32'h4000_1000,
    parameter integer NFIFO     = 8,
    parameter integer FIFO_DEPTH = 512
)(
    input  wire        clk_i,
    input  wire        rst_n_i,

    // Wait-state injection. Inputs, not parameters, so a test can change the
    // bus timing without a separate elaboration.
    input  wire [7:0]  waits_i,
    input  wire        rand_waits_i,

    // Bus-error injection window
    input  wire        err_en_i,
    input  wire [31:0] err_base_i,
    input  wire [31:0] err_size_i,

    // AHB-Lite slave port
    input  wire [31:0] haddr_i,
    input  wire [1:0]  htrans_i,
    input  wire        hwrite_i,
    input  wire [2:0]  hsize_i,
    input  wire [31:0] hwdata_i,
    output wire [31:0] hrdata_o,
    output wire        hready_o,
    output wire        hresp_o
);

    localparam integer MEM_WORDS = MEM_BYTES/4;

    reg [31:0] mem [0:MEM_WORDS-1];

    // FIFO storage, flattened to one dimension (index = port*FIFO_DEPTH + ptr)
    // so the model stays inside the unpacked-array support of every simulator
    // in this project's flow.
    reg [31:0] rd_q [0:NFIFO*FIFO_DEPTH-1];
    reg [31:0] wr_q [0:NFIFO*FIFO_DEPTH-1];
    integer    rd_head [0:NFIFO-1];
    integer    rd_tail [0:NFIFO-1];
    integer    wr_tail [0:NFIFO-1];

    // Observability counters for the testbench
    integer    rd_beats;     // completed read data phases
    integer    wr_beats;     // completed write data phases

    // ---- captured data phase ----------------------------------------------
    reg        dp_valid, dp_write;
    reg [31:0] dp_addr;
    reg [2:0]  dp_size;
    reg [7:0]  wcnt;
    reg        dp_err, err2;

    integer i;

    // -----------------------------------------------------------------------
    // Decode of the CAPTURED (data-phase) address
    // -----------------------------------------------------------------------
    wire dp_in_mem  = (dp_addr >= MEM_BASE)  && (dp_addr < (MEM_BASE  + MEM_BYTES));
    wire dp_in_fifo = (dp_addr >= FIFO_BASE) && (dp_addr < (FIFO_BASE + NFIFO*4));

    wire [31:0] dp_widx = (dp_addr - MEM_BASE)  >> 2;
    wire [31:0] dp_fidx = (dp_addr - FIFO_BASE) >> 2;

    // Decode of the address currently being PRESENTED (address phase)
    wire ap_ok = ((haddr_i >= MEM_BASE)  && (haddr_i < (MEM_BASE  + MEM_BYTES))) ||
                 ((haddr_i >= FIFO_BASE) && (haddr_i < (FIFO_BASE + NFIFO*4)));

    wire ap_err_win = err_en_i && (haddr_i >= err_base_i) &&
                                  (haddr_i <  (err_base_i + err_size_i));

    // -----------------------------------------------------------------------
    // HREADYOUT low while wait states remain, or during the ERROR's 1st cycle.
    // The two-cycle error response is mandatory - see dma_ahb_master.v, which
    // relies on that first HREADY=0/HRESP=1 cycle to retract its pipelined
    // write address phase.
    // -----------------------------------------------------------------------
    assign hready_o = (wcnt == 8'd0) && !(dp_err && !err2);
    assign hresp_o  = dp_err;

    // Per-access wait-state draw.
    //
    // Uses a local xorshift rather than $random: Icarus Verilog 14 accepts
    // $random(seed) and then ignores the seed, so seeded runs are not
    // reproducible and a "seed sweep" silently repeats one stimulus ten times.
    // Keeping the generator local and explicit also decouples the bus timing
    // sequence from how many random numbers the testbench itself drew.
    reg [31:0] rng = 32'h9E37_79B9;

    task automatic set_seed;
        input [31:0] s;
        begin rng = (s == 32'h0) ? 32'h9E37_79B9 : s; end
    endtask

    function [31:0] draw_waits;
        input [7:0] maxw;
        input       rand_en;
        begin
            if (!rand_en || maxw == 8'd0) draw_waits = maxw;
            else begin
                rng = rng ^ (rng << 13);
                rng = rng ^ (rng >> 17);
                rng = rng ^ (rng << 5);
                draw_waits = rng[7:0] % (maxw + 1);
            end
        end
    endfunction

    // Byte-enable merge on writes (HSIZE: 0=byte, 1=half, 2=word)
    function [31:0] merge;
        input [31:0] old_w;
        input [31:0] new_w;
        input [2:0]  sz;
        input [1:0]  off;
        begin
            merge = old_w;
            case (sz)
                3'b000: case (off)
                            2'd0: merge[ 7: 0] = new_w[ 7: 0];
                            2'd1: merge[15: 8] = new_w[15: 8];
                            2'd2: merge[23:16] = new_w[23:16];
                            2'd3: merge[31:24] = new_w[31:24];
                        endcase
                3'b001: if (off[1]) merge[31:16] = new_w[31:16];
                        else        merge[15: 0] = new_w[15: 0];
                default: merge = new_w;
            endcase
        end
    endfunction

    // Right-justify the addressed lane out of HWDATA, for the FIFO write path.
    function [31:0] lane_extract;
        input [31:0] d;
        input [2:0]  sz;
        input [1:0]  off;
        begin
            case (sz)
                3'b000: lane_extract = (d >> (8*off))     & 32'h0000_00FF;
                3'b001: lane_extract = (d >> (16*off[1])) & 32'h0000_FFFF;
                default: lane_extract = d;
            endcase
        end
    endfunction

    // -----------------------------------------------------------------------
    // Read data. FIFO ports present the head of their queue; the pop happens
    // in the sequencer when the data phase actually completes, so a wait-
    // stated read does not consume more than one entry.
    // -----------------------------------------------------------------------
    wire [31:0] fifo_head = (dp_in_fifo && (rd_head[dp_fidx] < rd_tail[dp_fidx]))
                            ? rd_q[dp_fidx*FIFO_DEPTH + rd_head[dp_fidx]]
                            : 32'hDEAD_BEEF;   // read from an empty FIFO

    assign hrdata_o = (dp_valid && !dp_write && !dp_err)
                      ? (dp_in_fifo ? fifo_head
                                    : (dp_in_mem ? mem[dp_widx] : 32'h0))
                      : 32'h0000_0000;

    // -----------------------------------------------------------------------
    // Sequencer
    // -----------------------------------------------------------------------
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            dp_valid <= 1'b0;
            dp_write <= 1'b0;
            dp_addr  <= 32'h0;
            dp_size  <= 3'b010;
            wcnt     <= 8'd0;
            dp_err   <= 1'b0;
            err2     <= 1'b0;
        end else if (dp_err && !err2) begin
            err2 <= 1'b1;                        // drive the 2nd ERROR cycle
        end else if (dp_err && err2) begin
            dp_err <= 1'b0; err2 <= 1'b0; dp_valid <= 1'b0;
        end else if (hready_o) begin
            // Commit the completing data phase before capturing the next
            // address phase.
            if (dp_valid && dp_write) begin
                wr_beats <= wr_beats + 1;
                if (dp_in_fifo) begin
                    wr_q[dp_fidx*FIFO_DEPTH + wr_tail[dp_fidx]] <=
                        lane_extract(hwdata_i, dp_size, dp_addr[1:0]);
                    wr_tail[dp_fidx] <= wr_tail[dp_fidx] + 1;
                end else if (dp_in_mem) begin
                    mem[dp_widx] <= merge(mem[dp_widx], hwdata_i, dp_size,
                                          dp_addr[1:0]);
                end
            end
            if (dp_valid && !dp_write) begin
                rd_beats <= rd_beats + 1;
                if (dp_in_fifo && (rd_head[dp_fidx] < rd_tail[dp_fidx]))
                    rd_head[dp_fidx] <= rd_head[dp_fidx] + 1;
            end

            dp_valid <= htrans_i[1];
            dp_write <= hwrite_i;
            dp_addr  <= haddr_i;
            dp_size  <= hsize_i;
            wcnt     <= htrans_i[1] ? draw_waits(waits_i, rand_waits_i) : 8'd0;
            dp_err   <= htrans_i[1] && (!ap_ok || ap_err_win);
        end else begin
            if (wcnt != 8'd0) wcnt <= wcnt - 8'd1;
        end
    end

    // -----------------------------------------------------------------------
    // Testbench API (called hierarchically)
    // -----------------------------------------------------------------------
    task automatic init_model;
        begin
            for (i = 0; i < MEM_WORDS; i = i + 1) mem[i] = 32'h0;
            for (i = 0; i < NFIFO; i = i + 1) begin
                rd_head[i] = 0; rd_tail[i] = 0; wr_tail[i] = 0;
            end
            rd_beats = 0;
            wr_beats = 0;
        end
    endtask

    // Push one entry onto a source FIFO (what the DMA will read).
    task automatic push_rd;
        input integer f;
        input [31:0]  d;
        begin
            rd_q[f*FIFO_DEPTH + rd_tail[f]] = d;
            rd_tail[f] = rd_tail[f] + 1;
        end
    endtask

    function automatic integer rd_avail;
        input integer f;
        begin rd_avail = rd_tail[f] - rd_head[f]; end
    endfunction

    function automatic integer wr_count;
        input integer f;
        begin wr_count = wr_tail[f]; end
    endfunction

    function automatic [31:0] wr_get;
        input integer f;
        input integer idx;
        begin wr_get = wr_q[f*FIFO_DEPTH + idx]; end
    endfunction

    // Byte-accurate view of the memory region, for destination checking.
    function automatic [7:0] mem_byte;
        input [31:0] addr;
        reg [31:0] w;
        begin
            w = mem[(addr - MEM_BASE) >> 2];
            case (addr[1:0])
                2'd0: mem_byte = w[ 7: 0];
                2'd1: mem_byte = w[15: 8];
                2'd2: mem_byte = w[23:16];
                default: mem_byte = w[31:24];
            endcase
        end
    endfunction

    function automatic [31:0] mem_word;
        input [31:0] addr;
        begin mem_word = mem[(addr - MEM_BASE) >> 2]; end
    endfunction

    task automatic mem_set_word;
        input [31:0] addr;
        input [31:0] d;
        begin mem[(addr - MEM_BASE) >> 2] = d; end
    endtask

endmodule
