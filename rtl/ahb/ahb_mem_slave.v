`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Verification support model
// ahb_mem_slave.v - AHB-Lite memory slave, DUAL PORT (I-side + D-side)
//
// STATUS: this is a VERIFICATION MODEL, not SoC RTL. It stands in for the
// TCM + interconnect that do not exist yet (rtl/ahb/ is otherwise empty).
// It is dual-ported for exactly one reason: garuda_core_top exposes two
// independent AHB-Lite masters (I-port, D-port) and there is no arbiter or
// address decoder in the tree yet. Rather than fake a fabric, both masters
// are attached directly to one memory image through two ports.
//
// WHAT THIS THEREFORE DOES *NOT* VERIFY:
//   - multi-master arbitration          (no arbiter exists)
//   - address decoding / slave select   (no decoder exists)
//   - AHB-to-APB bridge CDC             (no bridge exists)
// Nothing about a passing tb_boot run should be read as evidence about the
// interconnect. It exercises the two master state machines and the pipeline
// behind them, nothing more.
//
// PROTOCOL (AHB-Lite, ARM IHI 0033):
//   Address phase accepted when HREADY(out)=1 && HTRANS[1]=1 (NONSEQ/SEQ).
//   Data phase follows; HREADYOUT is driven low for WAIT_STATES cycles to
//   inject wait states, which is how the D-port's "hold everything upstream"
//   path (Sec. 11.4) and the I-port's outstanding-fetch tracking get stressed.
//   Out-of-range access returns the mandatory TWO-cycle ERROR response.
//
// Memory is word-addressed internally; byte/halfword writes honour HSIZE.
// =============================================================================

module ahb_mem_slave #(
    parameter [31:0] BASE_ADDR   = 32'h1000_0000,
    parameter integer SIZE_BYTES = 32'h0004_0000   // 256 KB
)(
    input  wire        clk_i,
    input  wire        rst_n_i,

    // Wait-state injection, per port. Inputs rather than parameters so the
    // testbench can drive them from a plusarg without a separate elaboration.
    // When *_rand_i is set these are treated as the MAXIMUM and each access
    // draws its own count in 0..max (Core Sanity TB row 21). A fixed count
    // exercises one timing; a randomised one is what actually finds the
    // stall-window bugs, three of which have already been found this way.
    input  wire [7:0]  i_waits_i,
    input  wire [7:0]  d_waits_i,
    input  wire        i_rand_i,
    input  wire        d_rand_i,

    // Bus-error injection (Core Sanity TB row 17). Any access whose address
    // falls in [err_base_i, err_base_i + err_size_i) returns the two-cycle
    // ERROR response, letting a test provoke a load/store access fault at a
    // chosen address without needing a second slave or a decoder.
    input  wire        err_en_i,
    input  wire [31:0] err_base_i,
    input  wire [31:0] err_size_i,

    // ---------------- Port A : instruction side ----------------
    input  wire [31:0] i_haddr_i,
    input  wire [1:0]  i_htrans_i,
    input  wire [2:0]  i_hsize_i,
    input  wire        i_hwrite_i,
    input  wire [31:0] i_hwdata_i,
    output wire [31:0] i_hrdata_o,
    output wire        i_hready_o,
    output wire        i_hresp_o,

    // ---------------- Port B : data side ----------------
    input  wire [31:0] d_haddr_i,
    input  wire [1:0]  d_htrans_i,
    input  wire [2:0]  d_hsize_i,
    input  wire        d_hwrite_i,
    input  wire [31:0] d_hwdata_i,
    output wire [31:0] d_hrdata_o,
    output wire        d_hready_o,
    output wire        d_hresp_o
);

    localparam integer NWORDS  = SIZE_BYTES/4;
    localparam integer AW      = $clog2(NWORDS);

    // Shared memory image. Both ports index the same array; a same-cycle
    // write/read collision resolves write-first on the D port because the
    // write commit is a nonblocking assign in the same always block region.
    reg [31:0] mem [0:NWORDS-1];

    integer k;
    initial for (k = 0; k < NWORDS; k = k + 1) mem[k] = 32'h0000_0000;

    // ------------------------------------------------------------------
    // Per-port data-phase tracking
    // ------------------------------------------------------------------
    // Port A
    reg        a_dv, a_dw, a_derr;
    reg [31:0] a_da;
    reg [2:0]  a_ds;
    reg [7:0]  a_wcnt;
    reg        a_err2;      // second (dead) cycle of the ERROR response

    // Port B
    reg        b_dv, b_dw, b_derr;
    reg [31:0] b_da;
    reg [2:0]  b_ds;
    reg [7:0]  b_wcnt;
    reg        b_err2;

    wire a_in_range = (i_haddr_i >= BASE_ADDR) && (i_haddr_i < (BASE_ADDR + SIZE_BYTES));
    wire b_in_range = (d_haddr_i >= BASE_ADDR) && (d_haddr_i < (BASE_ADDR + SIZE_BYTES));

    wire a_err_win = err_en_i && (i_haddr_i >= err_base_i) &&
                                 (i_haddr_i <  (err_base_i + err_size_i));
    wire b_err_win = err_en_i && (d_haddr_i >= err_base_i) &&
                                 (d_haddr_i <  (err_base_i + err_size_i));

    // Per-access wait-state draw. $random is seeded by the testbench, so a
    // failing regression seed replays exactly.
    function [7:0] draw_waits;
        input [7:0] maxw;
        input       rand_en;
        reg [31:0]  r;
        begin
            if (!rand_en || maxw == 8'd0) draw_waits = maxw;
            else begin
                r = $random;
                draw_waits = r[7:0] % (maxw + 8'd1);
            end
        end
    endfunction

    // HREADYOUT low while wait states remain, or during the error's 1st cycle
    assign i_hready_o = (a_wcnt == 8'd0) && !(a_derr && !a_err2);
    assign d_hready_o = (b_wcnt == 8'd0) && !(b_derr && !b_err2);
    assign i_hresp_o  = a_derr;
    assign d_hresp_o  = b_derr;

    wire [AW-1:0] a_widx = a_da[AW+1:2];
    wire [AW-1:0] b_widx = b_da[AW+1:2];

    assign i_hrdata_o = (a_dv && !a_derr) ? mem[a_widx] : 32'h0;
    assign d_hrdata_o = (b_dv && !b_derr) ? mem[b_widx] : 32'h0;

    // ------------------------------------------------------------------
    // Byte-enable expansion from HSIZE/HADDR (HSIZE: 0=byte,1=half,2=word)
    // ------------------------------------------------------------------
    function [31:0] merge;
        input [31:0] old_w;
        input [31:0] new_w;
        input [2:0]  hsize;
        input [1:0]  aoff;
        begin
            merge = old_w;
            case (hsize)
                3'b000: begin
                    case (aoff)
                        2'd0: merge[ 7: 0] = new_w[ 7: 0];
                        2'd1: merge[15: 8] = new_w[15: 8];
                        2'd2: merge[23:16] = new_w[23:16];
                        2'd3: merge[31:24] = new_w[31:24];
                    endcase
                end
                3'b001: begin
                    if (aoff[1]) merge[31:16] = new_w[31:16];
                    else         merge[15: 0] = new_w[15: 0];
                end
                default: merge = new_w;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // Port A sequencer
    // ------------------------------------------------------------------
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            a_dv <= 1'b0; a_dw <= 1'b0; a_da <= 32'h0; a_ds <= 3'b010;
            a_wcnt <= 8'd0; a_derr <= 1'b0; a_err2 <= 1'b0;
        end else if (a_derr && !a_err2) begin
            a_err2 <= 1'b1;                       // drive 2nd ERROR cycle
        end else if (a_derr && a_err2) begin
            a_derr <= 1'b0; a_err2 <= 1'b0; a_dv <= 1'b0;
        end else if (i_hready_o) begin
            // commit a completing write before latching the next address
            if (a_dv && a_dw)
                mem[a_widx] <= merge(mem[a_widx], i_hwdata_i, a_ds, a_da[1:0]);
            a_dv   <= i_htrans_i[1];
            a_dw   <= i_hwrite_i;
            a_da   <= i_haddr_i;
            a_ds   <= i_hsize_i;
            a_wcnt <= i_htrans_i[1] ? draw_waits(i_waits_i, i_rand_i) : 8'd0;
            a_derr <= i_htrans_i[1] && (!a_in_range || a_err_win);
        end else begin
            if (a_wcnt != 8'd0) a_wcnt <= a_wcnt - 8'd1;
        end
    end

    // ------------------------------------------------------------------
    // Port B sequencer
    // ------------------------------------------------------------------
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            b_dv <= 1'b0; b_dw <= 1'b0; b_da <= 32'h0; b_ds <= 3'b010;
            b_wcnt <= 8'd0; b_derr <= 1'b0; b_err2 <= 1'b0;
        end else if (b_derr && !b_err2) begin
            b_err2 <= 1'b1;
        end else if (b_derr && b_err2) begin
            b_derr <= 1'b0; b_err2 <= 1'b0; b_dv <= 1'b0;
        end else if (d_hready_o) begin
            if (b_dv && b_dw)
                mem[b_widx] <= merge(mem[b_widx], d_hwdata_i, b_ds, b_da[1:0]);
            b_dv   <= d_htrans_i[1];
            b_dw   <= d_hwrite_i;
            b_da   <= d_haddr_i;
            b_ds   <= d_hsize_i;
            b_wcnt <= d_htrans_i[1] ? draw_waits(d_waits_i, d_rand_i) : 8'd0;
            b_derr <= d_htrans_i[1] && (!b_in_range || b_err_win);
        end else begin
            if (b_wcnt != 8'd0) b_wcnt <= b_wcnt - 8'd1;
        end
    end

    // ------------------------------------------------------------------
    // Backdoor access for the testbench (preload / tohost polling)
    // ------------------------------------------------------------------
    task bd_load_hex;
        input [1023:0] path;
        begin
            $readmemh(path, mem);
        end
    endtask

    function [31:0] bd_read;
        input [31:0] byte_addr;
        begin
            bd_read = mem[(byte_addr - BASE_ADDR) >> 2];
        end
    endfunction

endmodule

`default_nettype wire
