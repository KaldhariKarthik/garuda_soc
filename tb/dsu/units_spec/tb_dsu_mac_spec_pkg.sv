// tb_dsu_mac_spec_pkg.sv -- sequential reference for the MAC benches (Track A
// wrap-up 2026-10-12), written from GARUDA-DSU-SPEC-001 section 6 / 7: each op
// takes effect instantly, in program order; products are 16x16 signed (Q1.15);
// MACABS uses |x| with 0x8000 -> 0x7FFF; MACDOT adds lo*lo + hi*hi; MACLOAD loads
// sign_extend(rs1); the accumulator is 48-bit and an add leaving the signed 48-bit
// range raises overflow and wraps (the RTL behaviour; saturate vs wrap is ruling D0).
package tb_dsu_mac_spec_pkg;
    typedef enum int {OP_MAC, OP_SUB, OP_ABS, OP_DOT, OP_LOAD, OP_CLEAR, OP_SAT, OP_IDLE} op_t;
    function automatic longint s16(input logic [15:0] v); return longint'($signed(v)); endfunction
    function automatic longint abs16(input logic [15:0] v);
        return (v == 16'h8000) ? 32767 : (v[15] ? -s16(v) : s16(v));
    endfunction
    function automatic logic [47:0] wrap48(input longint v); return v[47:0]; endfunction
    function automatic longint sx48(input logic [47:0] v); return longint'($signed(v)); endfunction
    // apply one op; returns the new accumulator, sets ovf when an add left the range
    function automatic logic [47:0] apply(input op_t op, input logic [47:0] acc, input logic [31:0] rs1,
                                          input logic [31:0] rs2, input logic [47:0] satv, output bit ovf);
        longint add = 0, raw;
        ovf = 0;
        case (op)
            OP_LOAD:  return {{16{rs1[31]}}, rs1};
            OP_CLEAR: return 48'd0;
            OP_SAT:   return satv;
            OP_IDLE:  return acc;
            OP_MAC:   add = s16(rs1[15:0]) * s16(rs2[15:0]);
            OP_SUB:   add = -(s16(rs1[15:0]) * s16(rs2[15:0]));
            OP_ABS:   add = abs16(rs1[15:0]) * abs16(rs2[15:0]);
            OP_DOT:   add = s16(rs1[15:0]) * s16(rs2[15:0]) + s16(rs1[31:16]) * s16(rs2[31:16]);
        endcase
        raw = sx48(acc) + add;
        ovf = (raw > 64'sh7FFF_FFFF_FFFF) || (raw < -64'sh8000_0000_0000);
        return wrap48(raw);
    endfunction
endpackage
