`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - VERIFICATION MODEL
// apb_slave_model.v - APB4 slave with wait states, PSLVERR injection, PSTRB
//
// STATUS: verification model. Lives in tb/ and must not migrate into rtl/.
// It stands in for the APB peripherals (Blocks 10-15, 18-21) so the bridge can
// be tested against something that exercises the parts of APB4 the DMA and the
// CLIC do not: PREADY wait states, PSLVERR, and byte-lane strobes.
//
// WHY IT COUNTS ITS OWN ACCESSES
// n_access_o is the number of completed APB transfers. That counter is the only
// way to see a transfer the BRIDGE dropped: if the bridge accepts an AHB
// address phase and never launches an APB access, the AHB side still completes
// and the master sees nothing wrong - the data is simply stale. Comparing
// "transfers the master issued" against "accesses this slave saw" is what makes
// ERRATUM BRG-1 visible at all. See tb_ahb2apb.sv T8.
//
// PSTRB IS HONOURED, NOT IGNORED. A model that wrote the full word regardless
// of PSTRB would pass a byte-write test by accident and hide a bridge that
// generated the wrong strobes.
// =============================================================================

module apb_slave_model #(
    parameter integer WORDS = 256
)(
    input  wire        pclk_i,
    input  wire        preset_n_i,

    // wait states inserted before PREADY rises (0 = zero-wait)
    input  wire [3:0]  waits_i,
    // assert PSLVERR on any access inside this offset window
    input  wire        err_en_i,
    input  wire [15:0] err_addr_i,

    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [15:0] paddr_i,
    input  wire [31:0] pwdata_i,
    input  wire [3:0]  pstrb_i,
    output wire [31:0] prdata_o,
    output wire        pready_o,
    output wire        pslverr_o,

    output reg  [31:0] n_access_o,       // completed APB transfers
    output reg  [31:0] n_proto_err_o     // APB protocol violations seen
);

    reg [31:0] mem [0:WORDS-1];
    reg [3:0]  wcnt;

    wire [15:0] word_idx = {2'b0, paddr_i[11:2]};

    integer k;
    initial begin
        for (k = 0; k < WORDS; k = k + 1) mem[k] = 32'h0;
        n_access_o    = 32'd0;
        n_proto_err_o = 32'd0;
        wcnt          = 4'd0;
    end

    // PREADY is low while wait states remain.
    assign pready_o  = (wcnt == 4'd0);
    assign pslverr_o = err_en_i && (paddr_i[11:0] == err_addr_i[11:0]) &&
                       psel_i && penable_i;
    assign prdata_o  = (psel_i && !pwrite_i) ? mem[word_idx[7:0]] : 32'h0;

    // -----------------------------------------------------------------------
    // Passive APB protocol checks. PENABLE must never be high in the first
    // cycle PSEL rises - that is the SETUP phase and it is one cycle long.
    // -----------------------------------------------------------------------
    reg psel_d, penable_d;
    always @(posedge pclk_i or negedge preset_n_i) begin
        if (!preset_n_i) begin
            psel_d    <= 1'b0;
            penable_d <= 1'b0;
        end else begin
            psel_d    <= psel_i;
            penable_d <= penable_i;

            if (psel_i && penable_i && !psel_d) begin
                n_proto_err_o <= n_proto_err_o + 1;
                $display("[APB-PROTO] PENABLE asserted in the same cycle as PSEL (t=%0t)",
                         $time);
            end

            // NOTE: there is deliberately NO "PENABLE without PSEL" check here.
            //
            // It was in an earlier revision of this model and it fired 25 times
            // in a clean run. The check is simply wrong for this topology: APB
            // fans out a SHARED PENABLE to every peripheral and distinguishes
            // them with a per-slave PSEL, so during an access to window 9 the
            // window 5 slave legitimately sees PENABLE high with its own PSEL
            // low. A real APB slave ignores PENABLE entirely unless its PSEL is
            // asserted, which is exactly what this model does.
            //
            // Worth recording rather than silently deleting: the failure looked
            // like a bridge defect and was a defect in the checker. A monitor
            // that cries wolf on legal traffic is worse than no monitor, because
            // the next real violation arrives into a log everyone has learned
            // to ignore.
        end
    end

    // -----------------------------------------------------------------------
    // Access sequencing and the byte-lane write
    // -----------------------------------------------------------------------
    always @(posedge pclk_i or negedge preset_n_i) begin
        if (!preset_n_i) begin
            wcnt       <= 4'd0;
            n_access_o <= 32'd0;
        end else if (psel_i && penable_i) begin
            if (wcnt != 4'd0) begin
                wcnt <= wcnt - 4'd1;
            end else begin
                // Completing this cycle.
                if (pwrite_i && !pslverr_o) begin
                    if (pstrb_i[0]) mem[word_idx[7:0]][ 7: 0] <= pwdata_i[ 7: 0];
                    if (pstrb_i[1]) mem[word_idx[7:0]][15: 8] <= pwdata_i[15: 8];
                    if (pstrb_i[2]) mem[word_idx[7:0]][23:16] <= pwdata_i[23:16];
                    if (pstrb_i[3]) mem[word_idx[7:0]][31:24] <= pwdata_i[31:24];
                end
                n_access_o <= n_access_o + 1;
                wcnt       <= waits_i;
            end
        end else begin
            wcnt <= waits_i;
        end
    end

    task bd_write;
        input [15:0] byte_addr;
        input [31:0] data;
        begin
            mem[byte_addr[9:2]] = data;
        end
    endtask

    function [31:0] bd_read;
        input [15:0] byte_addr;
        begin
            bd_read = mem[byte_addr[9:2]];
        end
    endfunction

    wire _unused = |{psel_d, penable_d};

endmodule

`default_nettype wire
