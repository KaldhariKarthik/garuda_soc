//dsu_stall.v

`timescale 1ns / 1ps
`include "dsu_defs.vh"

module dsu_stall (
    input wire clk,
    input wire rst_n,
    input wire flush,
    
    input wire [4:0] funct5,
    input wire [2:0] funct3,
    input wire       is_custom0,
    input wire [1:0] acc_sel,
    
    output wire dsu_busy
);

    wire cur_is_rtype = is_custom0 & (funct3 == 3'b000);
    wire cur_is_itype = is_custom0 & (funct3 == 3'b001);
    
    // -----------------------------------------------------------------------
    // ERRATUM DSU-3 (FLAG-C / FLAG-2) -- compute -> readback was not interlocked
    // -----------------------------------------------------------------------
    // cur_is_2cycle previously listed only the readback ops (MACRD_LO/HI,
    // MACSAT), so readback-after-readback stalled but readback-after-COMPUTE
    // did not. Given mac_unit's structure that is the hazard that actually
    // loses data: a multiply issued in cycle K lands in sum_reg/carry_reg on
    // that edge and only reaches `acc` on the NEXT cycle that accumulates, so
    // a readback issued immediately behind a compute observes the accumulator
    // before the product has arrived.
    //
    // sw/tests/dsu_flag2.S demonstrated it end to end: MACCLEAR, MAC_SEL(3,5),
    // MACRD_LO returned 0 instead of 15, and the value was not merely late -
    // with nothing else touching that accumulator the product stayed stranded
    // indefinitely.
    //
    // Resolved as an RTL interlock rather than a software ordering contract.
    // The contract would have been free today and permanent afterwards: nothing
    // in the assembler, the compiler or the ISA encoding could enforce "do not
    // read an accumulator in the cycle after you write it", so every future DSU
    // programmer would have had to know it. One cycle on a readback - which is
    // not in the MAC inner loop - is the cheaper side of that trade.
    //
    // The compute ops now also count as 2-cycle producers for interlock
    // purposes. The one-shot guard from ERRATUM DSU-1 still applies, so this
    // still inserts exactly one bubble and cannot re-deadlock.
    // -----------------------------------------------------------------------
    wire cur_is_compute = cur_is_rtype & ((funct5 == `FUNCT5_MAC_SEL) |
                                          (funct5 == `FUNCT5_MACSUB)  |
                                          (funct5 == `FUNCT5_MACABS)  |
                                          (funct5 == `FUNCT5_MACDOT));

    wire cur_is_2cycle = (cur_is_rtype & ((funct5 == `FUNCT5_MACRD_LO) |
                                          (funct5 == `FUNCT5_MACRD_HI) |
                                          (funct5 == `FUNCT5_MACSAT)))
                       | cur_is_compute;
    wire cur_reads_acc = (cur_is_rtype & ((funct5 == `FUNCT5_MACRD_LO) | (funct5 == `FUNCT5_MACRD_HI) | (funct5 == `FUNCT5_MACSAT))) | cur_is_itype;
    
    reg       prev_was_2cycle;
    reg [1:0] prev_acc_sel;
    reg       stalled_once;

    wire stall_now;

    // ERRATUM DSU-1 (found by Core Sanity row 13: t_dsu)
    // --------------------------------------------------
    // The interlock deadlocked on back-to-back readbacks of one accumulator.
    // stall_now compares the CURRENT EX instruction against prev_was_2cycle,
    // but asserting dsu_busy holds ID/EX - so on the next cycle the "current"
    // instruction is the SAME one, still a 2-cycle readback, still the same
    // acc_sel. Meanwhile prev_was_2cycle only updates when ~stall_now, so it
    // never clears. The condition sustains itself and dsu_busy stays high
    // forever: t_dsu spun on one PC until the testbench timed out.
    //
    // The interlock is meant to insert exactly ONE bubble, so it is now a
    // one-shot: stalled_once records that this instruction has already been
    // held and suppresses any further stall for it, letting prev_* advance.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            prev_was_2cycle <= 1'b0;
            prev_acc_sel <= 2'b00;
            stalled_once <= 1'b0;
        end
        else if (flush) begin
            prev_was_2cycle <= 1'b0;
            prev_acc_sel <= 2'b00;
            stalled_once <= 1'b0;
        end
        else begin
            stalled_once <= stall_now;
            if (~stall_now) begin
                prev_was_2cycle <= cur_is_2cycle;
                prev_acc_sel <= acc_sel;
            end
        end
    end

    assign stall_now = prev_was_2cycle & cur_reads_acc &
                       (acc_sel == prev_acc_sel) & ~stalled_once;
    
    assign dsu_busy = stall_now;
         
endmodule        
