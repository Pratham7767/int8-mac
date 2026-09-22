// Wallace tree: reduces the four Booth partial products to a single
// sum/carry pair using carry-save adders, leaving exactly one real
// carry-propagate addition for the end of the datapath.
//
//   pp0 pp1 pp2 pp3
//     \  |  /   |
//      CSA      |        layer 1: 4 rows -> 3 rows
//     /   \     |
//   s0    c0   pp3
//     \    |   /
//       CSA          layer 2: 3 rows -> 2 rows
//      /    \
//    sum    carry
//
// Depth here is 2 CSA layers, independent of word width. The final
// addition is deliberately NOT done in this module so the pipeline can
// choose where to place a register relative to the carry-propagate
// adder, which is the slowest part of the datapath.

module wallace_tree (
    input  [15:0] pp0,
    input  [15:0] pp1,
    input  [15:0] pp2,
    input  [15:0] pp3,
    output [15:0] sum,
    output [15:0] carry
);
    wire [15:0] s0, c0;

    csa #(.WIDTH(16)) u_layer1 (
        .x     (pp0),
        .y     (pp1),
        .z     (pp2),
        .sum   (s0),
        .carry (c0)
    );

    csa #(.WIDTH(16)) u_layer2 (
        .x     (s0),
        .y     (c0),
        .z     (pp3),
        .sum   (sum),
        .carry (carry)
    );
endmodule
