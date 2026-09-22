// Carry-save adder: a 3:2 compressor built from independent full adders,
// one per bit position. Reduces three rows to two in constant time,
// because there is no carry propagation along the word -- that is what
// makes a Wallace tree's depth grow logarithmically with the number of
// partial products instead of linearly.

module csa #(
    parameter WIDTH = 16
) (
    input  [WIDTH-1:0] x,
    input  [WIDTH-1:0] y,
    input  [WIDTH-1:0] z,
    output [WIDTH-1:0] sum,
    output [WIDTH-1:0] carry
);
    assign sum   = x ^ y ^ z;
    assign carry = ((x & y) | (y & z) | (x & z)) << 1;
endmodule
