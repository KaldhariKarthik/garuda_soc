// clic_seq_lib.svh - sequences for the CLIC environment (included in clic_env_pkg).

// One source pattern, held for a number of hclk cycles.
class clic_src_one_seq extends uvm_sequence #(clic_src_item);
    `uvm_object_utils(clic_src_one_seq)
    bit [31:0] src; int unsigned hold = 1; bit do_reset = 0;
    function new(string name = "clic_src_one_seq"); super.new(name); endfunction
    task body();
        req = clic_src_item::type_id::create("req");
        start_item(req);
        req.src = src; req.hold = hold; req.do_reset = do_reset;
        finish_item(req);
    endtask
endclass

// Random source patterns: empty, one line, sparse, dense, everything, and
// patterns that include the lines with no ID.
class clic_src_rand_seq extends uvm_sequence #(clic_src_item);
    `uvm_object_utils(clic_src_rand_seq)
    int unsigned n = 1000;
    function new(string name = "clic_src_rand_seq"); super.new(name); endfunction
    task body();
        int kind; bit [31:0] r;
        repeat (n) begin
            req = clic_src_item::type_id::create("req");
            start_item(req);
            if (!req.randomize()) `uvm_fatal("RAND", "clic_src_item")
            kind = $urandom_range(0, 99);
            r = $urandom();
            if      (kind < 10) req.src = 32'd0;
            else if (kind < 30) req.src = 32'd1 << $urandom_range(0, 31);
            else if (kind < 60) req.src = r & $urandom() & ID_MASK;
            else if (kind < 80) req.src = (r | $urandom()) & ID_MASK;
            else if (kind < 85) req.src = 32'hFFFF_FFFF;
            else                req.src = r;
            finish_item(req);
        end
    endtask
endclass

// Random register traffic: enables, levels drawn from a small palette so that
// ties are common, reads of everything, and accesses to offsets that do not exist.
class clic_apb_rand_seq extends uvm_sequence #(apb_item);
    `uvm_object_utils(clic_apb_rand_seq)
    int unsigned n = 500;
    function new(string name = "clic_apb_rand_seq"); super.new(name); endfunction
    function bit [7:0] pick_level();
        case ($urandom_range(0, 9))
            0: return 8'd0;
            1: return 8'd1;
            2: return 8'd254;
            3: return 8'd255;
            4, 5, 6: return 8'd100;
            default: return $urandom();
        endcase
    endfunction
    task body();
        int kind;
        repeat (n) begin
            req = apb_item::type_id::create("req");
            start_item(req);
            if (!req.randomize()) `uvm_fatal("RAND", "apb_item")
            kind = $urandom_range(0, 99);
            if (kind < 35) begin                                   // a level
                req.write = 1; req.addr = 12'h100 + 4 * $urandom_range(0, 31); req.wdata = {$urandom(), pick_level()};
            end else if (kind < 55) begin                          // the enables
                req.write = 1; req.addr = 12'h004;
                case ($urandom_range(0, 4))
                    0: req.wdata = 32'hFFFF_FFFF;
                    1: req.wdata = 32'd0;
                    2: req.wdata = 32'd1 << $urandom_range(0, 31);
                    default: req.wdata = $urandom();
                endcase
            end else if (kind < 80) begin                          // a read of something mapped
                req.write = 0;
                case ($urandom_range(0, 3))
                    0: req.addr = 12'h000;
                    1: req.addr = 12'h004;
                    2: req.addr = 12'h008;
                    default: req.addr = 12'h100 + 4 * $urandom_range(0, 31);
                endcase
            end else if (kind < 90) begin                          // an offset that does not exist
                case ($urandom_range(0, 2))
                    0: req.addr = 12'h00C + 4 * $urandom_range(0, 60);
                    1: req.addr = 12'h180 + 4 * $urandom_range(0, 927);
                    default: req.addr = 12'h100 + $urandom_range(0, 127);
                endcase
            end else begin                                         // a write to a read-only register
                req.write = 1; req.addr = ($urandom_range(0, 1)) ? 12'h000 : 12'h008; req.wdata = $urandom();
            end
            finish_item(req);
        end
    endtask
endclass
