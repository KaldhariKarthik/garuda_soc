`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Blocks 3/4/5: Memory Subsystem
// ahb_mem_slave_if.v - shared AHB-Lite slave wrapper for all three memories
//
// Spec reference: GARUDA-MEM-SPEC-001 Rev 2.0, Sec. 3.3, Sec. 5.2, Sec. 6.4,
//                 Sec. 8.1-8.6
//
// =============================================================================
// ONE WRAPPER, THREE MEMORIES
// =============================================================================
// Sec. 3.3 recommends this sharing and Sec. 13.1 gives the reason: the AHB
// behaviour of the ISRAM, the DSRAM and the Boot ROM is identical, and the only
// differences are depth, address width and whether writes are accepted. Three
// copies of this file would be three copies of the accept condition, the byte
// lane decode and the depth check - and the copies drift. They are parameters
// here instead.
//
// This module owns the PROTOCOL. It does not own any array: it emits a
// registered word address, a byte-write-enable vector and write data, and
// consumes a combinational read word. Blocks 3 and 5 wire that to one array;
// Block 4 wires it to a bank decoder in front of four (dsram_top.v).
//
// =============================================================================
// THE ACCEPT CONDITION - hready_i IS THE GLOBAL HREADY, NOT OURS
// =============================================================================
//     accept = hsel_i & hready_i & htrans_i[1]
//
// hready_i is the interconnect's shared HREADY, which is some OTHER slave's
// HREADYOUT whenever that slave owns the data phase (AHB Sec. 7.4). A slave
// that qualified on its own HREADYOUT instead would latch transfers that were
// never accepted, and the bug is invisible until two slaves are used back to
// back - which is the steady-state traffic pattern of a CPU fetching from ROM
// while the DMA moves data in DSRAM. The stand-in model this replaces carries
// the same warning in its own header; it is repeated because it is the single
// easiest thing to get wrong here.
//
// htrans_i[1] is the test for NONSEQ/SEQ. BUSY and IDLE are not transfers and
// must not be answered: a BUSY that started an array access would commit a
// write the master never issued.
//
// =============================================================================
// ZERO WAIT STATES, UNCONDITIONALLY (Sec. 8.4)
// =============================================================================
// hreadyout_o is tied high. Not "high in the common case" - high always, on all
// three memories, under every traffic pattern, and Sec. 12 has a test that
// asserts exactly that. The array answers inside its own cycle (Sec. 9.1) and
// there is no memory-side arbitration to wait for, so there is no condition
// under which this block needs to stall the bus. A master waiting on the Data
// SRAM is waiting for the Block 6 arbiter to grant it the bus, never for us.
//
// Tying it high rather than computing it is deliberate: a computed HREADYOUT
// is a latent wait state waiting for a future edit to enable it, and every
// timing argument in the core and the DMA assumes memory never stalls.
//
// =============================================================================
// NO ERROR RESPONSE (Sec. 8.6)
// =============================================================================
// hresp_o is tied OKAY. Two upstream guarantees make an error path unreachable:
// an unmapped region is answered by the interconnect's default slave and never
// reaches a memory, and a misaligned access is trapped by the core before the
// address phase commits (Core Sec. 12). The one fault that CAN arrive - an
// in-region, out-of-depth address - is handled by returning zero, not by
// erroring (Sec. 6.4), which keeps the policy uniform across all three blocks.
//
// =============================================================================
// DEPTH RANGE CHECKING - WHY A MEMORY MUST CHECK ITS OWN SIZE (Sec. 6.4)
// =============================================================================
// The interconnect decodes HADDR[31:28] only, so it selects a memory for a
// whole 256 MB region, not for the memory's actual size. Without a local check
// every region address folds onto the implemented depth: HADDR[15:2] is
// identical for 0x0000_0000 and 0x0001_0000, so both would read ISRAM word 0.
// That aliasing is real and is not acceptable - a runaway pointer would return
// a valid-looking word from the wrong place.
//
// So each memory checks the bits between the region nibble and its own
// addressing range. An access that fails is completed normally on the bus
// (HREADYOUT high, HRESP OKAY) but reads zero and discards writes. Zero rather
// than an alias is what makes a stray access obvious in simulation instead of
// plausible.
//
// The check is a constant mask rather than a comparator so it costs a dozen
// gates: ABITS says how many byte-address bits this memory implements, and
// every bit from ABITS up to 27 must be zero.
// =============================================================================

`include "mem_defs.vh"

module ahb_mem_slave_if #(
    parameter integer ABITS    = 16,   // implemented BYTE-address bits
    parameter integer AW       = 14,   // word-index width handed to the array
    parameter integer WRITABLE = 1     // 0 = ROM: writes accepted, discarded
)(
    input  wire        hclk_i,
    input  wire        hreset_n_i,

    // ---- AHB-Lite slave port (frozen bundle, AHB Sec. 5.3 / MEM Sec. 5.2) ----
    input  wire        hsel_i,
    input  wire [31:0] haddr_i,
    input  wire [1:0]  htrans_i,
    input  wire        hwrite_i,
    input  wire [2:0]  hsize_i,
    input  wire [31:0] hwdata_i,
    input  wire        hready_i,        // GLOBAL HREADY - see header
    output wire [31:0] hrdata_o,
    output wire        hreadyout_o,
    output wire        hresp_o,

    // ---- array-side interface (see header: this block owns no array) -------
    output wire [AW-1:0] arr_addr_o,    // registered word index
    output wire [3:0]    arr_we_o,      // per-byte write enable, data phase
    output wire [31:0]   arr_wdata_o,
    input  wire [31:0]   arr_rdata_i,   // combinational, same-cycle

    // Bank select for Block 4, taken from the SAME registered address so the
    // bank index and the word index can never disagree (Sec. 7.4).
    output wire [1:0]    arr_bank_o,

    // Out-of-depth flag for the data phase, exported so the block top can
    // force the read mux to zero without re-deriving the condition.
    output wire          dp_oor_o
);

    // -----------------------------------------------------------------------
    // Address-phase qualification
    // -----------------------------------------------------------------------
    wire accept = hsel_i && hready_i && htrans_i[1];

    // Depth check: any address bit at or above ABITS (up to the region nibble
    // at 27) being set means the access is in-region but out of depth.
    localparam [31:0] OOR_MASK = ~((32'h1 << ABITS) - 32'h1);
    wire ap_oor = |(haddr_i[27:0] & OOR_MASK[27:0]);

    // -----------------------------------------------------------------------
    // Data-phase registers.
    //
    // Updated only while hready_i is high. When another slave stretches the
    // bus these hold, which is what keeps read data stable across an extended
    // data phase instead of sliding to a new address mid-transfer.
    // -----------------------------------------------------------------------
    reg        dp_valid;
    reg        dp_write;
    reg [31:0] dp_addr;
    reg [2:0]  dp_size;
    reg        dp_oor;

    always @(posedge hclk_i or negedge hreset_n_i) begin
        if (!hreset_n_i) begin
            dp_valid <= 1'b0;
            dp_write <= 1'b0;
            dp_addr  <= 32'b0;
            dp_size  <= `MEM_SIZE_WORD;
            dp_oor   <= 1'b0;
        end else if (hready_i) begin
            dp_valid <= accept;
            if (accept) begin
                dp_write <= hwrite_i;
                dp_addr  <= haddr_i;
                dp_size  <= hsize_i;
                dp_oor   <= ap_oor;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Byte-lane decode (Sec. 8.3)
    //
    // HSIZE and HADDR[1:0] together say which lanes participate. Alignment is
    // guaranteed upstream by the core's misalignment trap, so the half-word
    // case only has to look at bit 1 and the word case takes all four lanes.
    // -----------------------------------------------------------------------
    reg [3:0] lane_en;
    always @(*) begin
        case (dp_size)
            `MEM_SIZE_BYTE: case (dp_addr[1:0])
                                2'd0: lane_en = 4'b0001;
                                2'd1: lane_en = 4'b0010;
                                2'd2: lane_en = 4'b0100;
                                default: lane_en = 4'b1000;
                            endcase
            `MEM_SIZE_HALF: lane_en = dp_addr[1] ? 4'b1100 : 4'b0011;
            default:        lane_en = 4'b1111;
        endcase
    end

    // -----------------------------------------------------------------------
    // Write commit.
    //
    // Gated on hready_i so the write lands exactly once, on the edge that ends
    // its data phase. WRITABLE=0 kills the enable entirely: the Boot ROM
    // accepts a write on the bus and silently discards it (Sec. 8.6), which is
    // why this is an enable term and not an error response.
    // -----------------------------------------------------------------------
    wire do_write = dp_valid && dp_write && !dp_oor && hready_i && (WRITABLE != 0);

    assign arr_we_o    = do_write ? lane_en : 4'b0000;
    assign arr_wdata_o = hwdata_i;

    // The array address is the REGISTERED address for both reads and writes -
    // one port, one access per cycle. See mem_array_sp.v's header for why the
    // read must be combinational off this register rather than off haddr_i.
    assign arr_addr_o = dp_addr[AW+1:2];
    assign arr_bank_o = dp_addr[`MEM_DSRAM_BANK_SEL_HI:`MEM_DSRAM_BANK_SEL_LO];

    assign dp_oor_o = dp_oor;

    // -----------------------------------------------------------------------
    // Returns
    // -----------------------------------------------------------------------
    // An out-of-depth read returns zero and selects no array location. Driving
    // a constant rather than leaving the array output through keeps a stray
    // access from returning a plausible aliased word (Sec. 6.4).
    assign hrdata_o    = (dp_valid && !dp_write && !dp_oor) ? arr_rdata_i
                                                            : 32'h0000_0000;
    assign hreadyout_o = 1'b1;                 // Sec. 8.4 - unconditional
    assign hresp_o     = `MEM_RESP_OKAY;       // Sec. 8.6 - no error path

    // -----------------------------------------------------------------------
    // Simulation-only assertions.
    //
    // Sec. 6.4, 8.3 and 8.6 each say "RTL must assert on this" - the conditions
    // are ones correct upstream logic cannot produce, so they are checks
    // against a FUTURE master violating the contract, not against today's.
    // Catching them here is the difference between a loud testbench failure and
    // a silently corrupted word.
    // -----------------------------------------------------------------------
`ifndef SYNTHESIS
    always @(posedge hclk_i) begin
        if (hreset_n_i && accept) begin
            if ((hsize_i == `MEM_SIZE_HALF) && haddr_i[0])
                $display("[MEM-ASSERT] misaligned half-word @0x%08h t=%0t",
                         haddr_i, $time);
            if ((hsize_i == `MEM_SIZE_WORD) && (|haddr_i[1:0]))
                $display("[MEM-ASSERT] misaligned word @0x%08h t=%0t",
                         haddr_i, $time);
            if (hsize_i > `MEM_SIZE_WORD)
                $display("[MEM-ASSERT] HSIZE=%0d exceeds word @0x%08h t=%0t",
                         hsize_i, haddr_i, $time);
            if (ap_oor)
                $display("[MEM-ASSERT] out-of-depth access @0x%08h (ABITS=%0d) t=%0t",
                         haddr_i, ABITS, $time);
            if (hwrite_i && (WRITABLE == 0))
                $display("[MEM-ASSERT] write to read-only memory @0x%08h t=%0t",
                         haddr_i, $time);
        end
    end
`endif

endmodule

`default_nettype wire
