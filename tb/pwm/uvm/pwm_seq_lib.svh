// pwm_seq_lib.svh - sequences for the PWM environment (included in pwm_env_pkg).

// Random register traffic with short frames, so that many frames, boundaries,
// clamps and stops fit in a short run. Offsets inside the register range are
// word aligned: the bridge issues no other (AHB2APB 7.4).
class pwm_rand_seq extends uvm_sequence #(apb_item);
    `uvm_object_utils(pwm_rand_seq)
    int unsigned n = 800;
    bit [15:0] per = 0;
    function new(string name = "pwm_rand_seq"); super.new(name); endfunction

    task acc(bit wr, bit [11:0] a, bit [31:0] d, int unsigned idle);
        req = apb_item::type_id::create("req");
        start_item(req);
        req.write = wr; req.addr = a; req.wdata = d; req.idle = idle;
        finish_item(req);
    endtask

    function bit [15:0] rand_duty();
        case ($urandom_range(0, 9))
            0: return 16'd0;
            1: return 16'd1;
            2: return per;
            3: return per - 1;
            4: return per + 1;                       // clamps
            5: return 16'hFFFF;                      // clamps
            default: return $urandom_range(0, per + 2);
        endcase
    endfunction

    task body();
        int k, idle; bit [31:0] hi;
        repeat (n) begin
            k = $urandom_range(0, 99); idle = $urandom_range(0, 12);
            hi = ($urandom_range(0, 3) == 0) ? ($urandom() & 32'hFFFF_0000) : 32'd0;      // upper bits are ignored
            if (k < 6) begin                                                               // a fresh configuration, then enable
                per = ($urandom_range(0, 7) == 0) ? $urandom_range(0, 2) : $urandom_range(3, 24);
                acc(1, 12'h008, 32'h0, 0);
                acc(1, 12'h000, hi | $urandom_range(0, 3), 0);
                acc(1, 12'h004, hi | per, 0);
                for (int c = 0; c < 4; c++) acc(1, 12'h010 + 4 * c, hi | rand_duty(), 0);
                acc(1, 12'h008, hi | {24'd0, 4'($urandom_range(0, 7) == 0 ? $urandom_range(0, 15) : 15), 3'd0, 1'b1}, idle);
            end else if (k < 40) acc(1, 12'h010 + 4 * $urandom_range(0, 3), hi | rand_duty(), idle);             // one duty
            else if (k < 50) for (int c = 0; c < 4; c++) acc(1, 12'h010 + 4 * c, hi | rand_duty(), (c == 3) ? idle : $urandom_range(0, 2));
            else if (k < 56) acc(1, 12'h008, hi | {24'd0, 4'($urandom_range(0, 15)), 3'($urandom_range(0, 7)), 1'($urandom_range(0, 3) != 0)}, idle);
            else if (k < 59) begin per = $urandom_range(0, 30); acc(1, 12'h004, hi | per, idle); end              // PERIOD while running
            else if (k < 61) acc(1, 12'h000, hi | $urandom_range(0, 4), idle);                                   // PRESCALE while running
            else if (k < 72) acc(0, 12'h00C, 0, idle);                                                           // STATUS
            else if (k < 78) acc(0, 4 * $urandom_range(0, 7), 0, idle);
            else if (k < 83) acc(1, 12'hFE0, hi | $urandom_range(0, 3), idle);                                   // clear events
            else if (k < 86) acc(1, 12'hFE4, hi | $urandom_range(0, 3), idle);
            else if (k < 88) acc(1, 12'hFE8, hi | $urandom_range(0, 3), idle);
            else if (k < 92) acc(0, 12'hFE0 + 4 * $urandom_range(0, 3), 0, idle);
            else if (k < 93) acc(1, ($urandom_range(0, 1)) ? 12'h00C : 12'hFEC, $urandom(), idle);               // write to a read-only register
            else if (k < 96) begin                                                                               // unmapped
                case ($urandom_range(0, 6))
                    0: acc($urandom_range(0, 1), 12'h020, $urandom(), idle);
                    1: acc($urandom_range(0, 1), 12'hFDC, $urandom(), idle);
                    2: acc($urandom_range(0, 1), 12'hFF0 + 4 * $urandom_range(0, 3), $urandom(), idle);
                    3: acc($urandom_range(0, 1), 12'hFE0 + $urandom_range(1, 3) + 4 * $urandom_range(0, 3), $urandom(), idle);
                    4: acc($urandom_range(0, 1), (4 * $urandom_range(0, 7)) | (12'h020 << $urandom_range(0, 6)), $urandom(), idle);          // alias
                    5: acc($urandom_range(0, 1), (12'hFE0 + 4 * $urandom_range(0, 3)) & ~(12'h020 << $urandom_range(0, 6)), $urandom(), idle);
                    default: acc($urandom_range(0, 1), 12'h024 + 4 * $urandom_range(0, 1005), $urandom(), idle);
                endcase
            end else acc(0, 12'h00C, 0, $urandom_range(20, 120));                                                // let it run
        end
    endtask
endclass
