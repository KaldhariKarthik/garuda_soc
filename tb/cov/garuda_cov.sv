// =============================================================================
// garuda_cov.sv -- functional coverage for the GARUDA core, bound into the RTL.
//
// WHY THIS SELF-REPORTS
// ---------------------
// Coverage databases are being written correctly by `xrun -coverage all`, but
// they cannot be READ on this machine: the only IMC installed is Incisive
// 15.20, and it fails on an Xcelium 22.09 database with
//     *E,DBERR: ... serialization exception
// Xcelium 22.09 ships no IMC of its own (only launch_rmi_imc.sh, a launcher for
// a separate install). Until a matching IMC/vManager is available, code
// coverage - statement, branch, toggle - cannot be reported at all.
//
// Functional coverage does not have that dependency: a covergroup can be asked
// for its own number at runtime via get_coverage(). So these groups print a
// report at the end of every simulation and the numbers are real today. When
// IMC arrives, the same covergroups also land in the database and merge with
// the code-coverage view - nothing here has to be rewritten.
//
// BOUND, NOT INSTANTIATED
// -----------------------
// `bind` attaches this to garuda_core_top without editing the RTL, so the
// synthesised netlist is untouched and the coverage cannot drift out of sync
// with the signals it samples: if a signal is renamed, this fails to compile
// rather than silently covering nothing.
// =============================================================================
`timescale 1ns/1ps

module garuda_cov (
    input wire        clk_i,
    input wire        rst_n_i,

    // ID / EX
    input wire [31:0] xe_instr,
    input wire        xe_valid,
    input wire [3:0]  xe_alu_op,
    input wire        xe_branch, xe_jal, xe_jalr,
    input wire        xe_mem_read, xe_mem_write,
    input wire        xe_mul_en, xe_dsu_en, xe_csr_en,

    // hazards
    input wire [1:0]  fwd_a_sel, fwd_b_sel,
    input wire        load_use, mem_stall, dsu_busy,

    // traps
    input wire        trap_enter,
    input wire [31:0] trap_cause,

    // memory
    input wire [2:0]  em_funct3,
    input wire [31:0] d_haddr,
    input wire [1:0]  d_htrans, i_htrans,
    input wire [2:0]  d_hburst, i_hburst,
    input wire        d_hresp,  i_hresp,
    input wire        d_hready, i_hready
);

    // ---------------------------------------------------------------------
    // 1. Instruction decode space
    // ---------------------------------------------------------------------
    wire [6:0] opcode = xe_instr[6:0];
    wire [2:0] funct3 = xe_instr[14:12];

    covergroup cg_decode @(posedge clk_i iff (rst_n_i && xe_valid));
        option.per_instance = 1;
        cp_opcode: coverpoint opcode {
            bins lui    = {7'b0110111};  bins auipc = {7'b0010111};
            bins jal    = {7'b1101111};  bins jalr  = {7'b1100111};
            bins branch = {7'b1100011};  bins load  = {7'b0000011};
            bins store  = {7'b0100011};  bins op_imm= {7'b0010011};
            bins op_reg = {7'b0110011};  bins system= {7'b1110011};
            bins custom0= {7'b0001011};
        }
        cp_funct3: coverpoint funct3;
        // Only the combinations that actually exist are interesting; a full
        // cross would demand bins for encodings the ISA does not define.
        x_op_f3: cross cp_opcode, cp_funct3 {
            ignore_bins non_f3 = binsof(cp_opcode) intersect {7'b0110111, 7'b0010111, 7'b1101111};
        }
    endgroup

    // ---------------------------------------------------------------------
    // 2. ALU operation space
    // ---------------------------------------------------------------------
    covergroup cg_alu @(posedge clk_i iff (rst_n_i && xe_valid));
        option.per_instance = 1;
        cp_alu_op: coverpoint xe_alu_op {
            bins add = {4'h0}; bins sub = {4'h1}; bins and_ = {4'h2}; bins or_ = {4'h3};
            bins xor_ = {4'h4}; bins sll = {4'h5}; bins srl = {4'h6}; bins sra = {4'h7};
            bins slt = {4'h8}; bins sltu = {4'h9}; bins passb = {4'hA};
        }
        cp_mul: coverpoint xe_mul_en;
    endgroup

    // ---------------------------------------------------------------------
    // 3. Load / store: width x address offset. The offset is what exercises
    //    the byte-enable and lane-alignment logic, and misaligned combinations
    //    are the ones that must trap.
    // ---------------------------------------------------------------------
    wire ls_active = xe_mem_read | xe_mem_write;

    covergroup cg_ldst @(posedge clk_i iff (rst_n_i && xe_valid && ls_active));
        option.per_instance = 1;
        cp_dir:  coverpoint {xe_mem_read, xe_mem_write} {
            bins load = {2'b10}; bins store = {2'b01};
        }
        cp_size: coverpoint em_funct3 {
            bins b={3'b000}; bins h={3'b001}; bins w={3'b010};
            bins bu={3'b100}; bins hu={3'b101};
        }
        cp_off:  coverpoint d_haddr[1:0];
        x_size_off: cross cp_size, cp_off;
        x_dir_size: cross cp_dir,  cp_size;
    endgroup

    // ---------------------------------------------------------------------
    // 4. Hazards: forwarding selects and every stall source, including the
    //    overlaps that produced ERRATA F-1, P-1, P-2 and P-3.
    // ---------------------------------------------------------------------
    covergroup cg_hazard @(posedge clk_i iff rst_n_i);
        option.per_instance = 1;
        cp_fwd_a: coverpoint fwd_a_sel { bins none={2'b00}; bins exmem={2'b01}; bins memwb={2'b10}; }
        cp_fwd_b: coverpoint fwd_b_sel { bins none={2'b00}; bins exmem={2'b01}; bins memwb={2'b10}; }
        x_fwd:    cross cp_fwd_a, cp_fwd_b;
        cp_lu:    coverpoint load_use;
        cp_ms:    coverpoint mem_stall;
        cp_db:    coverpoint dsu_busy;
        // The overlaps are the bug-bearing states, not the individual stalls.
        x_stall_overlap: cross cp_lu, cp_ms {
            bins both = binsof(cp_lu) intersect {1} && binsof(cp_ms) intersect {1};
            bins lu_only = binsof(cp_lu) intersect {1} && binsof(cp_ms) intersect {0};
            bins ms_only = binsof(cp_lu) intersect {0} && binsof(cp_ms) intersect {1};
            bins neither = binsof(cp_lu) intersect {0} && binsof(cp_ms) intersect {0};
        }
        x_fwd_under_stall: cross cp_fwd_a, cp_ms;
    endgroup

    // ---------------------------------------------------------------------
    // 5. Traps: every implemented cause must be taken at least once.
    // ---------------------------------------------------------------------
    covergroup cg_trap @(posedge clk_i iff (rst_n_i && trap_enter));
        option.per_instance = 1;
        cp_cause: coverpoint trap_cause {
            bins misaligned_fetch = {32'd0};    // ERRATUM T-1
            bins instr_fault      = {32'd1};
            bins illegal          = {32'd2};
            bins breakpoint       = {32'd3};
            bins load_misalign    = {32'd4};
            bins load_fault       = {32'd5};
            bins store_misalign   = {32'd6};
            bins store_fault      = {32'd7};
            bins ecall_m          = {32'd11};
            // ONE bin, not an array. `bins interrupt[]` over the ID range
            // creates 256 separate bins that no test set will ever close
            // individually, which pins trap coverage near 0% no matter how
            // well the trap paths are actually exercised. Interrupt-ID
            // breadth is the CLIC's coverage target, not the trap unit's.
            bins interrupt        = {[32'h8000_0000:32'hFFFF_FFFF]};
        }
    endgroup

    // ---------------------------------------------------------------------
    // 6. AHB protocol buckets on BOTH ports. Wait states and the ERROR
    //    response are the buckets that matter: three errata lived there.
    // ---------------------------------------------------------------------
    covergroup cg_ahb @(posedge clk_i iff rst_n_i);
        option.per_instance = 1;
        cp_i_trans: coverpoint i_htrans { bins idle={2'b00}; bins nonseq={2'b10}; bins seq={2'b11}; }
        cp_d_trans: coverpoint d_htrans { bins idle={2'b00}; bins nonseq={2'b10}; }
        cp_i_wait:  coverpoint i_hready { bins ready={1}; bins wait_state={0}; }
        cp_d_wait:  coverpoint d_hready { bins ready={1}; bins wait_state={0}; }
        cp_i_err:   coverpoint i_hresp;
        cp_d_err:   coverpoint d_hresp;
        x_i_trans_wait: cross cp_i_trans, cp_i_wait;
        x_d_trans_wait: cross cp_d_trans, cp_d_wait;

        // ---- HBURST, and the cross that should never have been missing ----
        // Until this cross existed, cp_i_trans counted every SEQ as coverage
        // with no opinion about the burst it claimed to belong to -- so the
        // AHB functional-coverage number went UP because of ERRATUM BUS-A.
        // A coverpoint that rewards a protocol violation is worse than no
        // coverpoint: it converts a defect into evidence of thoroughness.
        //
        // PROMOTED to illegal_bins 2026-09-02, as the note above said to do
        // once BUS-A/B/C were fixed. It was ignore_bins only because an
        // illegal_bin is a runtime error and would have aborted every run
        // while the erratum was open.
        //
        // With BUS-A fixed, i_hburst_o is the constant INCR: this port issues
        // undefined-length incrementing bursts and nothing else. So `single`
        // and `other` are no longer coverage holes to be chased, they are
        // states the design must never enter -- which is what illegal_bins
        // says, and it says it at the point of sampling rather than leaving a
        // permanently-0% bin dragging the number down for a reader to
        // rediscover and waive.
        cp_i_burst: coverpoint i_hburst {
            bins incr = {3'b001};
            illegal_bins not_incr = {3'b000, [3'b010:3'b111]};
        }
        // Every surviving cross bin is reachable and meaningful; the
        // seq-inside-a-SINGLE-burst combination that BUS-A produced can no
        // longer be constructed, because its HBURST half is now illegal.
        x_i_trans_burst: cross cp_i_trans, cp_i_burst;
    endgroup

    // ---------------------------------------------------------------------
    // 7. DSU: instruction x accumulator. The plan asks for all 30 legal
    //    combinations (10 Custom-0 ops x 3 accumulators).
    // ---------------------------------------------------------------------
    wire [4:0] dsu_funct5  = xe_instr[31:27];
    wire [1:0] dsu_acc_sel = xe_instr[26:25];
    wire [2:0] dsu_funct3  = xe_instr[14:12];

    covergroup cg_dsu @(posedge clk_i iff (rst_n_i && xe_valid && xe_dsu_en));
        option.per_instance = 1;
        cp_f5: coverpoint dsu_funct5 {
            bins mac_sel={5'd0}; bins macsub={5'd1}; bins macabs={5'd2};
            bins macdot={5'd3};  bins macload={5'd4}; bins macclear={5'd5};
            bins macsat={5'd6};  bins rd_lo={5'd7};   bins rd_hi={5'd8};
            bins macshift={5'd9};
        }
        cp_acc: coverpoint dsu_acc_sel { bins fx={2'b00}; bins fy={2'b01}; bins mag={2'b10}; }
        cp_fmt: coverpoint dsu_funct3  { bins rtype={3'b000}; bins itype={3'b001}; }
        x_op_acc: cross cp_f5, cp_acc;      // the 30 legal combinations
        cp_busy:  coverpoint dsu_busy;
    endgroup

    cg_decode u_cg_decode = new();
    cg_alu     u_cg_alu    = new();
    cg_ldst    u_cg_ldst   = new();
    cg_hazard  u_cg_hazard = new();
    cg_trap    u_cg_trap   = new();
    cg_ahb     u_cg_ahb    = new();
    cg_dsu     u_cg_dsu    = new();

    // ---------------------------------------------------------------------
    // Self-report. Written to both stdout and a file so the regression runner
    // can merge numbers across tests without IMC.
    // ---------------------------------------------------------------------
    task automatic report_coverage(input [1023:0] tag);
        integer fh;
        real d, a, l, h, t, b, u, total;
        begin
            d = u_cg_decode.get_coverage();
            a = u_cg_alu.get_coverage();
            l = u_cg_ldst.get_coverage();
            h = u_cg_hazard.get_coverage();
            t = u_cg_trap.get_coverage();
            b = u_cg_ahb.get_coverage();
            u = u_cg_dsu.get_coverage();
            total = (d + a + l + h + t + b + u) / 7.0;
            $display("\n[COV] %0s decode=%0.2f alu=%0.2f ldst=%0.2f hazard=%0.2f trap=%0.2f ahb=%0.2f dsu=%0.2f overall=%0.2f",
                     tag, d, a, l, h, t, b, u, total);
            // %0s of a packed vector strips the leading NULs, so a path
            // passed via +COVTAG works verbatim.
            fh = $fopen($sformatf("%0s.txt", tag), "w");
            if (fh) begin
                $fwrite(fh, "decode %0.4f\nalu %0.4f\nldst %0.4f\nhazard %0.4f\ntrap %0.4f\nahb %0.4f\ndsu %0.4f\n",
                        d, a, l, h, t, b, u);
                $fclose(fh);
            end
        end
    endtask

endmodule

// Attach to the core without touching the RTL.
bind garuda_core_top garuda_cov u_cov (
    .clk_i(clk_i), .rst_n_i(rst_n_i),
    .xe_instr(xe_instr), .xe_valid(xe_valid), .xe_alu_op(xe_alu_op),
    .xe_branch(xe_branch), .xe_jal(xe_jal), .xe_jalr(xe_jalr),
    .xe_mem_read(xe_mem_read), .xe_mem_write(xe_mem_write),
    .xe_mul_en(xe_mul_en), .xe_dsu_en(xe_dsu_en), .xe_csr_en(xe_csr_en),
    .fwd_a_sel(fwd_a_sel), .fwd_b_sel(fwd_b_sel),
    .load_use(id_load_use), .mem_stall(mem_stall), .dsu_busy(ex_dsu_busy),
    .trap_enter(tr_enter), .trap_cause(tr_cause),
    .em_funct3(em_funct3), .d_haddr(d_haddr_o),
    .d_htrans(d_htrans_o), .i_htrans(i_htrans_o),
    .d_hburst(d_hburst_o), .i_hburst(i_hburst_o),
    .d_hresp(d_hresp_i),   .i_hresp(i_hresp_i),
    .d_hready(d_hready_i), .i_hready(i_hready_i)
);
