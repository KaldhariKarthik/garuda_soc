// dma_seq_lib.svh - sequences for the DMA environment (included in dma_env_pkg).

// One peripheral's request pattern (see req_item).
class dma_req_seq extends uvm_sequence #(req_item);
    `uvm_object_utils(dma_req_seq)
    int unsigned ch, n = 1, width = 0, gap = 1, max_wait_pclk = 4000;
    function new(string name = "dma_req_seq"); super.new(name); endfunction
    task body();
        req = req_item::type_id::create("req");
        start_item(req);
        req.ch = ch; req.n = n; req.width = width; req.gap = gap; req.max_wait_pclk = max_wait_pclk;
        finish_item(req);
    endtask
endclass

// Random register reads: status, global status and the control registers of
// every channel, while transfers run (sb_stat "including reads in every cycle
// of a transfer", sb_gstat, sb_reg).
class dma_poll_seq extends uvm_sequence #(apb_item);
    `uvm_object_utils(dma_poll_seq)
    int unsigned n = 100;
    function new(string name = "dma_poll_seq"); super.new(name); endfunction
    task body();
        repeat (n) begin
            req = apb_item::type_id::create("req");
            start_item(req);
            if (!req.randomize()) `uvm_fatal("RAND", "apb_item")
            req.write = 0;
            case ($urandom_range(0, 9))
                0, 1, 2, 3: req.addr = 12'h010 + 12'h020 * $urandom_range(0, 5);    // STAT
                4, 5:       req.addr = 12'h100;                                        // GSTAT
                6:          req.addr = 12'h000 + 12'h020 * $urandom_range(0, 5);    // CR
                7:          req.addr = 12'h004 + 12'h020 * $urandom_range(0, 5);    // SAR
                8:          req.addr = 12'h008 + 12'h020 * $urandom_range(0, 5);    // DAR
                default:    req.addr = 12'h00C + 12'h020 * $urandom_range(0, 5);    // CNT
            endcase
            finish_item(req);
        end
    endtask
endclass
