`timescale 1ns/1ps
// =============================================================================
// spi_flash_model.sv -- SPI NOR flash (W25Q-style), enough of one to boot from
//
// Supports what GARUDA-MEM-SPEC-001 §8.2 uses and nothing more:
//   0x03  READ  - 24-bit address, then streaming data until CS rises
//   0x9F  RDID  - 3 JEDEC ID bytes, so bring-up can prove the bus works at all
// Mode 0: MOSI is sampled on the rising SCLK edge, MISO changes on the falling
// edge. Backing store loaded with bd_load_hex() (one byte per line) or bd_write().
//
// The model checks the master as well as serving it, because a flash that
// silently tolerates a protocol error is how a boot bug reaches the board:
//   - CS must stay low for the whole command + address sequence
//   - SCLK must not exceed MAX_MHZ
//   - MOSI must be stable across the sampling edge
// viol() is non-zero if any of those happened.
// =============================================================================
module spi_flash_model #(
    parameter integer SIZE_BYTES = 65536 + 4096,
    parameter real    MAX_MHZ    = 20.0,
    parameter [23:0]  JEDEC_ID   = 24'hEF4016        // Winbond W25Q32
)(
    input  wire cs_n,
    input  wire sclk,
    input  wire mosi,
    output reg  miso
);

    localparam [7:0] CMD_READ = 8'h03, CMD_RDID = 8'h9F;
    localparam int   P_CMD = 0, P_ADDR = 1, P_DATA = 2;

    reg [7:0] mem [0:SIZE_BYTES-1];

    int       phase, nbit, dbit, idbyte;
    reg [7:0] cmd, shin, shout;
    reg [23:0] addr;

    int      viol_rate = 0, viol_mosi = 0, viol_cs = 0;
    realtime last_edge = 0;

    function automatic int viol(); return viol_rate + viol_mosi + viol_cs; endfunction

    task automatic bd_write(input int byte_addr, input [7:0] d);
        mem[byte_addr] = d;
    endtask
    task automatic bd_load_hex(input string path);
        $readmemh(path, mem);
    endtask

    initial begin
        miso = 1'b0; phase = P_CMD; nbit = 0; dbit = 0; idbyte = 0;
        cmd = 0; shin = 0; shout = 0; addr = 0;
    end

    // ---- chip select ----------------------------------------------------------
    always @(negedge cs_n) begin
        phase = P_CMD; nbit = 0; dbit = 0; idbyte = 0; shin = 0;
    end
    always @(posedge cs_n) begin
        if (phase == P_ADDR) begin                 // cut short mid-address
            viol_cs++;
            $display("[FLASH] CS released mid-address at %0t", $time);
        end
        miso  = 1'b0;
        phase = P_CMD;
    end

    // ---- sample MOSI on the rising edge -----------------------------------------
    always @(posedge sclk) if (!cs_n) begin
        if (last_edge > 0 && ($realtime - last_edge) < (1000.0 / MAX_MHZ) - 0.01) begin
            viol_rate++;
            $display("[FLASH] SCLK too fast: %0.1f ns period at %0t (limit %0.1f MHz)",
                     $realtime - last_edge, $time, MAX_MHZ);
        end
        last_edge = $realtime;

        case (phase)
            P_CMD: begin
                shin = {shin[6:0], mosi};
                nbit++;
                if (nbit == 8) begin
                    cmd  = shin;
                    nbit = 0;
                    if (cmd == CMD_READ) phase = P_ADDR;
                    else begin
                        phase = P_DATA;
                        if (cmd == CMD_RDID) begin shout = JEDEC_ID[23:16]; idbyte = 1; end
                    end
                end
            end
            P_ADDR: begin
                addr = {addr[22:0], mosi};
                nbit++;
                if (nbit == 24) begin nbit = 0; dbit = 0; phase = P_DATA; end
            end
            default: ;                              // data phase: master shifts dummies
        endcase
    end

    // ---- drive MISO on the falling edge --------------------------------------------
    always @(negedge sclk) if (!cs_n && phase == P_DATA) begin
        if (cmd == CMD_READ) begin
            if (dbit == 0) begin
                shout = mem[addr % SIZE_BYTES];
                addr  = addr + 1;
            end
            miso  = shout[7];
            shout = {shout[6:0], 1'b0};
            dbit  = (dbit == 7) ? 0 : dbit + 1;
        end else if (cmd == CMD_RDID) begin
            miso  = shout[7];
            shout = {shout[6:0], 1'b0};
            dbit  = (dbit == 7) ? 0 : dbit + 1;
            if (dbit == 0) begin
                shout  = (idbyte == 1) ? JEDEC_ID[15:8] : JEDEC_ID[7:0];
                idbyte = idbyte + 1;
            end
        end else begin
            miso = 1'b0;
        end
    end

    // MOSI must be stable across the sampling edge
    always @(mosi) if (!cs_n && last_edge > 0 && ($realtime - last_edge) < 1.0) begin
        viol_mosi++;
        $display("[FLASH] MOSI changed %0.2f ns after the sampling edge at %0t",
                 $realtime - last_edge, $time);
    end
endmodule
