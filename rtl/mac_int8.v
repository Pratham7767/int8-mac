// Pipelined signed INT8 multiply-accumulate.
//
//   acc <= acc + (a * b)      a, b signed 8-bit; acc signed ACC_W-bit
//
// PIPE_STAGES selects where registers are placed, so the same datapath
// can be built at four different depths and compared for area and
// logic depth (see syn/compare.sh):
//
//   0 : purely combinational multiply, one register on the accumulator
//       -> shortest latency, longest critical path
//   1 : register after the Booth partial-product generation
//   2 : register after Booth and after the Wallace tree
//   3 : register after Booth, after the tree, and after the final
//       carry-propagate adder
//       -> longest latency, shortest critical path
//
// Valid flows down the pipeline alongside the data, so the accumulator
// only updates on cycles where a real product arrives. Latency from
// `in_valid` to the accumulator update is PIPE_STAGES + 1 cycles.

// The default depth can be overridden at compile time with
// -DPIPE_STAGES=<n> (the testbench does this), or per-instance with the
// usual parameter override when this module is instantiated.
`ifndef PIPE_STAGES
  `define PIPE_STAGES 3
`endif

module mac_int8 #(
    parameter PIPE_STAGES = `PIPE_STAGES,   // 0..3
    parameter ACC_W       = 32
) (
    input                        clk,
    input                        rst_n,

    input                        in_valid,
    input  signed [7:0]          a,
    input  signed [7:0]          b,
    input                        acc_clear,   // clear accumulator with this product

    output signed [15:0]         product,     // registered, aligned with out_valid
    output signed [ACC_W-1:0]    acc,
    output                       out_valid
);

    // ---------------- stage A: Booth partial products ----------------
    wire signed [15:0] pp0_c, pp1_c, pp2_c, pp3_c;
    wire        [15:0] neg_mask_unused;

    booth_pp_gen u_booth (
        .a        (a),
        .b        (b),
        .pp0      (pp0_c),
        .pp1      (pp1_c),
        .pp2      (pp2_c),
        .pp3      (pp3_c),
        .neg_mask (neg_mask_unused)
    );

    wire signed [15:0] pp0_s, pp1_s, pp2_s, pp3_s;
    wire               validA, clearA;

    generate
        if (PIPE_STAGES >= 1) begin : g_regA
            reg signed [15:0] pp0_r, pp1_r, pp2_r, pp3_r;
            reg               v_r, clr_r;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    pp0_r <= 16'sd0; pp1_r <= 16'sd0;
                    pp2_r <= 16'sd0; pp3_r <= 16'sd0;
                    v_r   <= 1'b0;   clr_r <= 1'b0;
                end else begin
                    pp0_r <= pp0_c; pp1_r <= pp1_c;
                    pp2_r <= pp2_c; pp3_r <= pp3_c;
                    v_r   <= in_valid;
                    clr_r <= acc_clear;
                end
            end
            assign pp0_s = pp0_r; assign pp1_s = pp1_r;
            assign pp2_s = pp2_r; assign pp3_s = pp3_r;
            assign validA = v_r;  assign clearA = clr_r;
        end else begin : g_combA
            assign pp0_s = pp0_c; assign pp1_s = pp1_c;
            assign pp2_s = pp2_c; assign pp3_s = pp3_c;
            assign validA = in_valid; assign clearA = acc_clear;
        end
    endgenerate

    // ---------------- stage B: Wallace compression ----------------
    wire [15:0] tree_sum_c, tree_carry_c;

    wallace_tree u_tree (
        .pp0   (pp0_s),
        .pp1   (pp1_s),
        .pp2   (pp2_s),
        .pp3   (pp3_s),
        .sum   (tree_sum_c),
        .carry (tree_carry_c)
    );

    wire [15:0] tree_sum_s, tree_carry_s;
    wire        validB, clearB;

    generate
        if (PIPE_STAGES >= 2) begin : g_regB
            reg [15:0] sum_r, carry_r;
            reg        v_r, clr_r;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    sum_r <= 16'd0; carry_r <= 16'd0;
                    v_r   <= 1'b0;  clr_r   <= 1'b0;
                end else begin
                    sum_r <= tree_sum_c; carry_r <= tree_carry_c;
                    v_r   <= validA;     clr_r   <= clearA;
                end
            end
            assign tree_sum_s = sum_r; assign tree_carry_s = carry_r;
            assign validB = v_r;       assign clearB = clr_r;
        end else begin : g_combB
            assign tree_sum_s = tree_sum_c; assign tree_carry_s = tree_carry_c;
            assign validB = validA;         assign clearB = clearA;
        end
    endgenerate

    // ---------------- stage C: final carry-propagate add ----------------
    wire signed [15:0] product_c = $signed(tree_sum_s) + $signed(tree_carry_s);

    wire signed [15:0] product_s;
    wire               validC, clearC;

    generate
        if (PIPE_STAGES >= 3) begin : g_regC
            reg signed [15:0] prod_r;
            reg               v_r, clr_r;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    prod_r <= 16'sd0; v_r <= 1'b0; clr_r <= 1'b0;
                end else begin
                    prod_r <= product_c; v_r <= validB; clr_r <= clearB;
                end
            end
            assign product_s = prod_r; assign validC = v_r; assign clearC = clr_r;
        end else begin : g_combC
            assign product_s = product_c; assign validC = validB; assign clearC = clearB;
        end
    endgenerate

    // ---------------- accumulator ----------------
    reg signed [ACC_W-1:0] acc_r;
    reg signed [15:0]      product_r;
    reg                    out_valid_r;

    wire signed [ACC_W-1:0] product_ext = {{(ACC_W-16){product_s[15]}}, product_s};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_r       <= {ACC_W{1'b0}};
            product_r   <= 16'sd0;
            out_valid_r <= 1'b0;
        end else begin
            out_valid_r <= validC;
            if (validC) begin
                // product is registered here as well as accumulated, so
                // that it is aligned with out_valid at every pipeline
                // depth. Taking it straight off the datapath would make
                // it combinational (and stale by the time out_valid
                // rises) whenever PIPE_STAGES < 3.
                product_r <= product_s;
                acc_r     <= clearC ? product_ext : (acc_r + product_ext);
            end
        end
    end

    assign product   = product_r;
    assign acc       = acc_r;
    assign out_valid = out_valid_r;

endmodule
