// spis_seq_lib.svh - sequences for the SPI slave environment (included in spis_env_pkg).

// One packet, built by the test.
class spis_one_seq extends uvm_sequence #(spis_pkt);
    `uvm_object_utils(spis_one_seq)
    spis_pkt p;
    function new(string name = "spis_one_seq"); super.new(name); endfunction
    task body(); start_item(p); finish_item(p); endtask
endclass

// Random packets, glitches and clocks while not selected: the constraints of spis_pkt.
class spis_spi_rand_seq extends uvm_sequence #(spis_pkt);
    `uvm_object_utils(spis_spi_rand_seq)
    int unsigned n = 150;
    function new(string name = "spis_spi_rand_seq"); super.new(name); endfunction
    task body();
        repeat (n) begin
            req = spis_pkt::type_id::create("req");
            start_item(req);
            if (!req.randomize()) `uvm_fatal("RAND", "spis_pkt did not randomize")
            finish_item(req);
        end
    endtask
endclass

// Random register traffic while the packets arrive. Offsets inside the register
// range are word aligned in the bridge's traffic (AHB2APB 7.4); the unaligned and
// unmapped ones are here to see the error answer.
class spis_apb_rand_seq extends uvm_sequence #(apb_item);
    `uvm_object_utils(spis_apb_rand_seq)
    bit stop;
    function new(string name = "spis_apb_rand_seq"); super.new(name); endfunction

    task acc(bit wr, bit [11:0] a, bit [31:0] d, int unsigned idle);
        req = apb_item::type_id::create("req");
        start_item(req);
        req.write = wr; req.addr = a; req.wdata = d; req.idle = idle;
        finish_item(req);
    endtask

    task body();
        int k, idle; bit [31:0] hi;
        acc(1, 12'h008, 32'h1, 0);
        while (!stop) begin
            k = $urandom_range(0, 99); idle = $urandom_range(0, 30);
            hi = ($urandom_range(0, 3) == 0) ? ($urandom() & 32'hFFFF_FF00) : 32'd0;         // upper bits are ignored
            if      (k < 30) acc(0, 12'h000, 0, idle);                                         // take a byte
            else if (k < 42) acc(0, 12'h00C, 0, idle);                                         // STATUS
            else if (k < 54) acc(1, 12'h004, hi | $urandom_range(0, 255), idle);               // TXDATA
            else if (k < 60) acc(1, 12'h008, (hi & ~32'h3) | 32'h1, idle);                     // EN
            else if (k < 61) begin acc(1, 12'h008, hi & ~32'h3, $urandom_range(0, 200)); acc(1, 12'h008, 32'h1, idle); end   // EN off for a while
            else if (k < 63) acc(1, 12'h008, 32'h3, idle);                                     // flush
            else if (k < 71) acc(1, 12'hFE0, hi | $urandom_range(0, 7), idle);                 // clear events
            else if (k < 76) acc(1, 12'hFE4, hi | $urandom_range(0, 7), idle);
            else if (k < 79) acc(1, 12'hFE8, hi | $urandom_range(0, 3), idle);
            else if (k < 85) acc(0, 12'hFE0 + 4 * $urandom_range(0, 3), 0, idle);
            else if (k < 88) acc(0, 4 * $urandom_range(1, 2), 0, idle);
            else if (k < 90) acc(1, $urandom_range(0, 1) ? ($urandom_range(0, 1) ? 12'h000 : 12'h00C) : 12'hFEC, $urandom(), idle);   // read-only
            else if (k < 95) begin                                                             // unmapped
                case ($urandom_range(0, 7))
                    0: acc($urandom_range(0, 1), 12'h010, $urandom(), idle);
                    1: acc($urandom_range(0, 1), 12'hFDC, $urandom(), idle);
                    2: acc($urandom_range(0, 1), 12'hFF0 + 4 * $urandom_range(0, 3), $urandom(), idle);
                    3: acc($urandom_range(0, 1), 12'hFE0 + $urandom_range(1, 3) + 4 * $urandom_range(0, 3), $urandom(), idle);
                    4: acc($urandom_range(0, 1), (4 * $urandom_range(0, 3)) | (12'h010 << $urandom_range(0, 7)), $urandom(), idle);       // alias
                    5: acc($urandom_range(0, 1), (12'hFE0 + 4 * $urandom_range(0, 3)) & ~(12'h020 << $urandom_range(0, 6)), $urandom(), idle);
                    6: acc($urandom_range(0, 1), 4 * $urandom_range(0, 3) + $urandom_range(1, 3), $urandom(), idle);                      // unaligned
                    default: acc($urandom_range(0, 1), 12'h014 + 4 * $urandom_range(0, 1009), $urandom(), idle);
                endcase
            end else acc(0, 12'h00C, 0, $urandom_range(40, 300));                              // let bytes pile up
        end
    endtask
endclass
