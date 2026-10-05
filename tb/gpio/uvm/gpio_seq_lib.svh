// gpio_seq_lib.svh - sequences for the GPIO environment (included in gpio_env_pkg).

// The outside world: random levels on the two pads, held for 1, 2, 3 or more
// cycles; now and then a level that overpowers the pin's own driver.
class gpio_pad_rand_seq extends uvm_sequence #(gpio_pad_item);
    `uvm_object_utils(gpio_pad_rand_seq)
    function new(string name = "gpio_pad_rand_seq"); super.new(name); endfunction
    task body();
        forever begin
            req = gpio_pad_item::type_id::create("req");
            start_item(req);
            if (!req.randomize() with { hold dist {1 := 3, 2 := 3, 3 := 3, [4:12] :/ 4, [13:40] :/ 3};
                                        force_pad dist {2'b00 := 12, 2'b01 := 1, 2'b10 := 1, 2'b11 := 1}; })
                `uvm_error("RAND", "pad item")
            finish_item(req);
        end
    endtask
endclass

// Random register traffic. Offsets inside the vendored register file are word
// aligned: the bridge issues no other (AHB2APB 7.4).
class gpio_apb_rand_seq extends uvm_sequence #(apb_item);
    `uvm_object_utils(gpio_apb_rand_seq)
    int unsigned n = 1500;
    function new(string name = "gpio_apb_rand_seq"); super.new(name); endfunction

    task acc(bit wr, bit [11:0] a, bit [31:0] d, int unsigned idle);
        req = apb_item::type_id::create("req");
        start_item(req);
        req.write = wr; req.addr = a; req.wdata = d; req.idle = idle;
        finish_item(req);
    endtask

    task body();
        int k, idle; bit [31:0] hi;
        repeat (n) begin
            k = $urandom_range(0, 99); idle = $urandom_range(0, 10);
            hi = ($urandom_range(0, 3) == 0) ? ($urandom() & 32'hFFFF_FF00) : 32'd0;      // bits with no pin behind them
            if      (k < 6)  acc(1, 12'h000, hi | $urandom_range(0, 3), idle);                                   // PADDIR
            else if (k < 14) acc(1, 12'h004, hi | (($urandom_range(0, 3) == 0) ? $urandom_range(0, 3) : 3), idle);   // GPIOEN, mostly both
            else if (k < 20) acc(1, 12'h00C, hi | $urandom_range(0, 3), idle);                                   // PADOUT
            else if (k < 28) acc(1, ($urandom_range(0, 1)) ? 12'h010 : 12'h014, hi | $urandom_range(0, 3), idle); // set / clear
            else if (k < 36) acc(1, 12'h018, hi | (($urandom_range(0, 3) == 0) ? $urandom_range(0, 3) : 3), idle);   // INTEN
            else if (k < 44) acc(1, 12'h01C, hi | $urandom_range(0, 15), idle);                                  // INTTYPE
            else if (k < 46) acc(1, 12'h028, $urandom(), idle);                                                  // PADCFG0
            else if (k < 58) acc(0, 12'h008, 0, idle);                                                           // PADIN
            else if (k < 68) acc(0, 12'h024, 0, idle);                                                           // INTSTATUS
            else if (k < 73) acc(0, 4 * $urandom_range(0, 10), 0, idle);
            else if (k < 80) acc(1, 12'hFE0, hi | $urandom_range(0, 1), idle);                                   // clear the event
            else if (k < 85) acc(1, 12'hFE4, hi | (($urandom_range(0, 3) == 0) ? 0 : 1), idle);
            else if (k < 87) acc(1, 12'hFE8, hi | $urandom_range(0, 3), idle);
            else if (k < 91) acc(0, 12'hFE0 + 4 * $urandom_range(0, 3), 0, idle);
            else if (k < 93) acc(1, ($urandom_range(0, 2) == 0) ? 12'h008 : ($urandom_range(0, 1) ? 12'h024 : 12'hFEC), $urandom(), idle);   // read-only registers written
            else if (k < 95) acc($urandom_range(0, 1), ($urandom_range(0, 3) == 0) ? 12'h020 : 12'h02C + 4 * $urandom_range(0, 20), $urandom(), idle);   // inside the register file, not a register
            else begin
                case ($urandom_range(0, 5))
                    0: acc($urandom_range(0, 1), 12'h080, $urandom(), idle);
                    1: acc($urandom_range(0, 1), 12'hFDC, $urandom(), idle);
                    2: acc($urandom_range(0, 1), 12'hFF0 + 4 * $urandom_range(0, 3), $urandom(), idle);
                    3: acc($urandom_range(0, 1), 12'hFE0 + $urandom_range(1, 3) + 4 * $urandom_range(0, 3), $urandom(), idle);
                    4: acc($urandom_range(0, 1), (12'hFE0 + 4 * $urandom_range(0, 3)) & ~(12'h020 << $urandom_range(0, 6)), $urandom(), idle);
                    default: acc($urandom_range(0, 1), 12'h084 + 4 * $urandom_range(0, 980), $urandom(), idle);
                endcase
            end
        end
    endtask
endclass
