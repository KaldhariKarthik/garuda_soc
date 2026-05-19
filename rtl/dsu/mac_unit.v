//mac_unit.v
//one mac : 16x16 signed multiply, 48 bit accumulator, 2-cycle pipeline.
//supports MAC_SEL, MACSUB, MACABS, MACDOT, MACCLEAR, MACLOAD, MACSAT.
//MACREAD_LO/HI/SHIFT do not engage this unit - they consume mac_out externally.

`timescale 1ns / 1ps

module mac_unit(
    input wire         clk,
    input wire         rst_n,
    
    input wire  [31:0] rs1,
    input wire  [31:0] rs2,
    
    input wire         en,
    input wire         add_sub,
    input wire         clear,
    input wire         load,
    input wire         abs_en,
    input wire         dot_en,
    input wire         flush,
    
    input wire  [47:0] sat_writeback,
    input wire         sat_writeback_en,
    
    output wire [47:0] mac_out,        
    output wire        overflow
);

    wire [15:0] a0, b0, a1, b1;
    operand_router u_router (
        .rs1 (rs1),
        .rs2 (rs2),
        .abs_en (abs_en),
        .dot_en (dot_en),
        .a0 (a0),
        .b0 (b0),
        .a1 (a1),
        .b1 (b1)        
    );       
    
    wire signed [31:0] product_a, product_b;
    mult_16x16 U_mult_a (.a ($signed(a0)),  .b ($signed(b0)), .p (product_a));
    mult_16x16 U_mult_b (.a ($signed(a1)),  .b ($signed(b1)), .p (product_b));
    
    wire [47:0] pa_ext = {{16{product_a[31]}}, product_a};
    wire [47:0] pb_ext = {{16{product_b[31]}}, product_b};
    
    wire [47:0] pa_eff = pa_ext ^ {48{add_sub}};
    wire [47:0] pb_eff = pb_ext ^ {48{add_sub}};
    wire [47:0] sub_k = {46'b0, add_sub , 1'b0};
    
    wire [47:0] csa1_sum, csa1_carry;
    csa_3to2 #(.WIDTH(48)) u_csa1 (
        .a (pa_eff),
        .b (pb_eff),
        .c (sub_k),
        .sum (csa1_sum),
        .carry (csa1_carry)
    );
    
    reg [47:0] sum_reg, carry_reg;
    always @(posedge clk or negedge rst_n) begin 
        if (!rst_n) begin
            sum_reg   <= 48'b0;
            carry_reg <= 48'b0;
        end
        else if (en & ~flush) begin
            sum_reg   <= csa1_sum;
            carry_reg <= csa1_carry;
        end
    end
    
    reg signed [47:0] acc;
    wire [47:0] csa2_sum, csa2_carry;
    csa_3to2 #(.WIDTH(48)) u_csa2(
        .a (acc),
        .b (sum_reg),
        .c (carry_reg),
        .sum (csa2_sum),
        .carry (csa2_carry)
    );
    
    wire [48:0] s_ext = {csa2_sum[47], csa2_sum};
    wire [48:0] c_ext = {csa2_carry[47], csa2_carry}; 
    wire [48:0] result_ext;
    kogge_stone_49 u_ks (
        .a (s_ext),
        .b (c_ext),
        .cin (1'b0),
        .sum (result_ext)
    );
    
    wire [47:0] adder_result = result_ext[47:0];
    wire        accum_ovf    = result_ext[48] ^ result_ext[47]; 
    
    wire signed [47:0] rs1_sext = {{16{rs1[31]}}, rs1};
    reg  signed [47:0] acc_next;
    always @(*) begin
        if      (sat_writeback_en) acc_next = sat_writeback;
        else if (load)             acc_next = rs1_sext;
        else if (clear)            acc_next = 48'b0;
        else                       acc_next = adder_result;    
    end
    
    always @(posedge clk or negedge rst_n) begin
        if      (!rst_n)      acc <= 48'b0;
        else if (en & ~flush) acc <= acc_next;
    end
    assign mac_out = acc;
    
    wire is_accum = ~(load | clear | sat_writeback_en);
    assign overflow = accum_ovf & en & ~flush & is_accum;
    
endmodule
