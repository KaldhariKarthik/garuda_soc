// timers_seq_lib.svh - sequences for the timers environment (included in timers_env_pkg).

// Random register traffic, biased so that things happen in a short run: the
// compare value is placed near the counter, the counter near a carry, the
// watchdog is given short timeouts and is kicked with the magic value and with
// near misses. A watchdog expiry resets the block; the traffic carries on.
class tmr_rand_seq extends uvm_sequence #(apb_item);
    `uvm_object_utils(tmr_rand_seq)
    int unsigned n = 600;
    bit [31:0] last_lo, last_hi, last_load = 32'hFFFF_FFFF;
    function new(string name = "tmr_rand_seq"); super.new(name); endfunction

    task acc(bit wr, bit [11:0] a, bit [31:0] d, int unsigned idle, output bit [31:0] r);
        req = apb_item::type_id::create("req");
        start_item(req);
        req.write = wr; req.addr = a; req.wdata = d; req.idle = idle;
        finish_item(req);
        r = req.rdata;
    endtask

    task body();
        bit [31:0] r; int k, idle;
        repeat (n) begin
            k = $urandom_range(0, 99); idle = $urandom_range(0, 3);
            if (k < 12) begin                                   // deadline near the counter
                acc(0, 12'h000, 0, 0, last_lo); acc(0, 12'h004, 0, 0, last_hi);
                acc(1, 12'h00C, last_hi, 0, r);
                acc(1, 12'h008, last_lo + $urandom_range(0, 300) - 40, idle, r);
            end else if (k < 16) begin
                case ($urandom_range(0, 3))
                    0: acc(1, 12'h00C, 32'd0, idle, r);
                    1: acc(1, 12'h00C, 32'hFFFF_FFFF, idle, r);
                    2: acc(1, 12'h008, ($urandom_range(0, 1)) ? 32'd0 : 32'hFFFF_FFFF, idle, r);
                    default: acc(1, 12'h00C, $urandom_range(0, 2), idle, r);
                endcase
            end else if (k < 20) begin                          // counter near a carry
                case ($urandom_range(0, 2))
                    0: acc(1, 12'h000, 32'hFFFF_FF00 + $urandom_range(0, 255), idle, r);
                    1: acc(1, 12'h000, $urandom(), idle, r);
                    default: begin acc(1, 12'h000, 32'hFFFF_FFE0, 0, r); acc(1, 12'h004, 32'hFFFF_FFFF, idle, r); end
                endcase
            end else if (k < 22) acc(1, 12'h004, $urandom_range(0, 3), idle, r);
            else if (k < 34) begin acc(0, 12'h000, 0, $urandom_range(0, 2), last_lo); acc(0, 12'h004, 0, idle, last_hi); end
            else if (k < 37) acc(0, 12'h004, 0, idle, r);                      // high word alone
            else if (k < 44) acc(0, 4 * $urandom_range(2, 8), 0, idle, r);
            else if (k < 52) begin                                             // reload value
                case ($urandom_range(0, 4))
                    0: last_load = 0; 1: last_load = 1; 2: last_load = 2;
                    default: last_load = $urandom_range(3, 400);
                endcase
                acc(1, 12'h014, last_load, idle, r);
            end else if (k < 58) acc(1, 12'h010, {$urandom_range(0, 1) ? 30'd0 : $urandom(), 2'($urandom_range(0, 3))}, idle, r);
            else if (k < 70) begin                                             // kick
                case ($urandom_range(0, 9))
                    0, 1, 2, 3, 4: acc(1, 12'h01C, KICK_MAGIC, idle, r);
                    5, 6, 7:       acc(1, 12'h01C, KICK_MAGIC ^ (32'd1 << $urandom_range(0, 31)), idle, r);
                    8:             acc(1, 12'h01C, $urandom_range(0, 1) ? 32'd0 : 32'hFFFF_FFFF, idle, r);
                    default:       acc(1, 12'h01C, $urandom(), idle, r);
                endcase
            end else if (k < 78) begin                                         // warning threshold
                case ($urandom_range(0, 5))
                    0: acc(1, 12'h020, 32'd0, idle, r);
                    1: acc(1, 12'h020, 32'd1, idle, r);
                    2: acc(1, 12'h020, last_load - 1, idle, r);
                    3: acc(1, 12'h020, last_load, idle, r);
                    4: acc(1, 12'h020, last_load + 5, idle, r);
                    default: acc(1, 12'h020, $urandom_range(2, 300), idle, r);
                endcase
            end else if (k < 84) acc(0, 12'h018, 0, idle, r);
            else if (k < 86) acc($urandom_range(0, 1), 12'h024 + 4 * $urandom_range(0, 1014), $urandom(), idle, r);   // unmapped
            else if (k < 87) acc($urandom_range(0, 1), 12'h024, $urandom(), idle, r);                                // first past the map
            else if (k < 88) begin                                                                                   // alias of a register
                int rg = $urandom_range(0, 8);
                acc($urandom_range(0, 1), (4 * rg) | (12'h100 << $urandom_range(0, 3)), (rg == 7) ? KICK_MAGIC : $urandom(), idle, r);
            end
            else if (k < 90) acc($urandom_range(0, 1), $urandom_range(1, 35), $urandom(), idle, r);                  // mostly unaligned
            else if (k < 93) acc(1, 12'h018, $urandom(), idle, r);                                                   // write to read-only
            else begin acc(1, 4 * $urandom_range(0, 8), $urandom(), 0, r); acc(1, 4 * $urandom_range(0, 8), $urandom(), idle, r); end
        end
    endtask
endclass
