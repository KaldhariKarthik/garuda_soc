// garuda_pkg.sv - constants of the former garuda_defs.vh
// (zero-waiver F4, 2026-11-16: compiler directives leave the RTL, HAL CDNOTE;
// only the constants the chip uses are here, HAL USEPAR).
package garuda_pkg;
    localparam ALU_ADD = 4'h0;
    localparam ALU_SUB = 4'h1;
    localparam ALU_AND = 4'h2;
    localparam ALU_OR = 4'h3;
    localparam ALU_XOR = 4'h4;
    localparam ALU_SLL = 4'h5;
    localparam ALU_SRL = 4'h6;
    localparam ALU_SRA = 4'h7;
    localparam ALU_SLT = 4'h8;
    localparam ALU_SLTU = 4'h9;
    localparam ALU_PASSB = 4'hA;  // LUI: result = operand B (immediate)
    localparam IMM_I = 3'h0;
    localparam IMM_S = 3'h1;
    localparam IMM_B = 3'h2;
    localparam IMM_U = 3'h3;
    localparam IMM_J = 3'h4;
    // 5-bit zero-extended rs1, CSRRWI/SI/CI (Sec. 13.3)
    localparam IMM_CSR = 3'h5;
    localparam IMM_NONE = 3'h6;
    // ---- widths (HAL STYVAL: no bare numbers in declared ranges) ----
    localparam int unsigned PADDR_W = 32'd12;
    localparam int unsigned CSR_ADDR_W = 32'd12;
    localparam int unsigned HTRANS_W = 32'd2;
    localparam int unsigned HSIZE_W = 32'd3;
    localparam int unsigned HBURST_W = 32'd3;
    localparam int unsigned HPROT_W = 32'd4;
    localparam int unsigned REG_IDX_W = 32'd5;
    localparam int unsigned FUNCT3_W = 32'd3;
    localparam int unsigned FUNCT5_W = 32'd5;
    localparam int unsigned FUNCT7_W = 32'd7;
    localparam int unsigned OPCODE_W = 32'd7;
    localparam int unsigned ALU_OP_W = 32'd4;
    localparam int unsigned CSR_OP_W = 32'd2;
    localparam int unsigned ACC_SEL_W = 32'd2;
    localparam int unsigned DMA_NCH = 32'd6;
    localparam int unsigned AHB_MID_W = 32'd2;
    localparam int unsigned APB_NWIN = 32'd12;
    localparam int unsigned APB_WIN_W = 32'd4;
    localparam int unsigned CLIC_ID_W = 32'd5;
    localparam int unsigned CLIC_LVL_W = 32'd8;
    localparam int unsigned DIV_SEL_W = 32'd2;
    localparam int unsigned DMACTL_W = 32'd2;
    localparam int unsigned GCTL_W = 32'd4;
    localparam int unsigned CSR_FN_W = 32'd3;
    localparam int unsigned IMM_SEL_W = 32'd3;
    localparam int unsigned FWD_SEL_W = 32'd2;
    localparam int unsigned PFB_OCC_W = 32'd3;
    localparam int unsigned BYTE_OFF_W = 32'd2;
    localparam int unsigned EXC_CAUSE_W = 32'd4;
    // a trap's mcause code: exceptions < 16, CLIC IDs < 32, the timer 7
    localparam int unsigned TRAP_CODE_W = 32'd5;
    localparam int unsigned JTAG_IR_W = 32'd5;
    localparam int unsigned DMI_ADDR_W = 32'd7;
    localparam int unsigned DMI_OP_W = 32'd2;
    localparam int unsigned DMA_CH_W = 32'd3;
    localparam int unsigned DMA_SIZE_W = 32'd2;
    // a load/store's size: funct3[1:0]
    // addi x0, x0, 0: the canonical NOP a bubble or an empty slot carries
    localparam logic [31:0] NOP_INSTR = 32'h0000_0013;
    localparam int unsigned MEM_SIZE_W = 32'd2;
    // DMA: ERRPHASE is 1 (read) or 2 (write); the 3-bit register field is
    // padded where it is read (F4)
    localparam int unsigned ERR_PHASE_W = 32'd2;
    localparam int unsigned DMA_CR_W = 32'd9;
    localparam int unsigned WDT_CTL_W = 32'd2;  // WDTCTL: {WARNEN, EN}     // CR [8:0]
    localparam int unsigned DMA_STAT_W = 32'd21;  // STAT [20:0] as held
                                                  // (ERRPHASE bit 21 is 0)
    localparam int unsigned SHAMT_W = 32'd6;
    localparam int unsigned RES_SRC_W = 32'd2;
    localparam int unsigned NUM_ACC = 32'd3;
    localparam int unsigned BE_W = 32'd4;
    localparam int unsigned DUTY_W = 32'd16;
    localparam int unsigned RST_CAUSE_W = 32'd5;
    localparam int unsigned GPIO_W = 32'd2;
    localparam int unsigned PERIPH_IRQ_W = 32'd7;
    localparam int unsigned WORD_W = 32'd32;
    localparam int unsigned BYTE_W = 32'd8;
    localparam int unsigned HALF_W = 32'd16;
    localparam int unsigned ACC_W = 32'd48;
    localparam int unsigned DWORD_W = 32'd64;
endpackage
