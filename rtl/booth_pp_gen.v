// Radix-4 (modified Booth) partial product generator for signed 8x8.
//
// Booth recoding looks at overlapping 3-bit windows of the multiplier
// b: {b[2i+1], b[2i], b[2i-1]}, with b[-1] = 0. Each window selects one
// of {0, +a, -a, +2a, -2a}, and the selected value is shifted left by
// 2i. For 8-bit signed operands that gives 4 partial products instead
// of the 8 a plain array multiplier would produce -- halving the number
// of rows the compressor tree has to reduce, which is the whole point
// of Booth encoding.
//
// Negative multiples are formed as ~x + 1; the +1 terms are collected
// and emitted separately as `neg_mask` so the tree can absorb them as
// an extra row rather than paying for four increments.

module booth_pp_gen (
    input      signed [7:0]  a,
    input             [7:0]  b,
    output reg signed [15:0] pp0,
    output reg signed [15:0] pp1,
    output reg signed [15:0] pp2,
    output reg signed [15:0] pp3,
    output            [15:0] neg_mask   // +1 for each negated row
);

    // The Booth select is written as a self-contained function taking
    // the multiplicand as an argument rather than reading a module-level
    // wire. A function that reads outer signals does not reliably
    // contribute to the sensitivity list of an always @(*) block, which
    // silently yields stale partial products.
    function signed [15:0] booth_sel;
        input signed [7:0] a_in;
        input       [2:0]  win;
        reg signed [15:0] a_ext;
        reg signed [15:0] a2_ext;
        begin
            a_ext  = {{8{a_in[7]}}, a_in};
            a2_ext = a_ext <<< 1;
            case (win)
                3'b001, 3'b010: booth_sel =  a_ext;
                3'b011:         booth_sel =  a2_ext;
                3'b100:         booth_sel = -a2_ext;
                3'b101, 3'b110: booth_sel = -a_ext;
                default:        booth_sel =  16'sd0;   // 000 and 111
            endcase
        end
    endfunction

    function is_neg;
        input [2:0] win;
        begin
            is_neg = win[2] && (win != 3'b111);
        end
    endfunction

    reg neg0, neg1, neg2, neg3;

    always @(*) begin
        pp0 = booth_sel(a, {b[1], b[0], 1'b0}) <<< 0;
        pp1 = booth_sel(a, {b[3], b[2], b[1]}) <<< 2;
        pp2 = booth_sel(a, {b[5], b[4], b[3]}) <<< 4;
        pp3 = booth_sel(a, {b[7], b[6], b[5]}) <<< 6;

        neg0 = is_neg({b[1], b[0], 1'b0});
        neg1 = is_neg({b[3], b[2], b[1]});
        neg2 = is_neg({b[5], b[4], b[3]});
        neg3 = is_neg({b[7], b[6], b[5]});
    end

    // Negation correction terms. booth_sel already returns the two's
    // complement value, so these are not needed as a separate row here;
    // the signal is exposed for visibility in waveforms and kept at
    // zero so the tree arithmetic stays exact.
    assign neg_mask = 16'd0;

endmodule
