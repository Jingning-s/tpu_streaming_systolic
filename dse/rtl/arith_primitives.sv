`default_nettype none
`timescale 1ns/1ps

// Arithmetic-only DSE primitives.  These modules are deliberately isolated
// from production pe.sv so synthesis experiments cannot perturb the frozen
// full-array checkpoint before a winner is selected.

module dse_csa3 #(
    parameter integer W = 16
) (
    input  wire [W-1:0] x,
    input  wire [W-1:0] y,
    input  wire [W-1:0] z,
    output wire [W-1:0] sum,
    output wire [W-1:0] carry_shifted
);
    assign sum = x ^ y ^ z;
    assign carry_shifted = ((x & y) | (x & z) | (y & z)) << 1;
endmodule

module dse_ripple_adder #(
    parameter integer W = 8
) (
    input  wire [W-1:0] a,
    input  wire [W-1:0] b,
    input  wire         cin,
    output wire [W-1:0] sum,
    output wire         cout
);
    wire [W:0] carry;
    assign carry[0] = cin;
    generate
        genvar bit_index;
        for (bit_index = 0; bit_index < W; bit_index = bit_index + 1) begin : bits
            assign sum[bit_index] = a[bit_index] ^ b[bit_index] ^ carry[bit_index];
            assign carry[bit_index+1] =
                (a[bit_index] & b[bit_index]) |
                (a[bit_index] & carry[bit_index]) |
                (b[bit_index] & carry[bit_index]);
        end
    endgenerate
    assign cout = carry[W];
endmodule

module dse_inferred_adder #(
    parameter integer W = 16
) (
    input  wire [W-1:0] a,
    input  wire [W-1:0] b,
    input  wire         cin,
    output wire [W-1:0] sum,
    output wire         cout
);
    assign {cout, sum} = {1'b0, a} + {1'b0, b} + cin;
endmodule

// Carry-select with fixed-width segments.  Every segment computes cin=0 and
// cin=1 in parallel; only a mux chain propagates between segments.
module dse_segmented_csel_adder #(
    parameter integer W   = 32,
    parameter integer SEG = 8
) (
    input  wire [W-1:0] a,
    input  wire [W-1:0] b,
    input  wire         cin,
    output wire [W-1:0] sum,
    output wire         cout
);
    localparam integer NSEG = W / SEG;
    wire [NSEG:0] selected_carry;
    assign selected_carry[0] = cin;

    generate
        genvar segment;
        for (segment = 0; segment < NSEG; segment = segment + 1) begin : segments
            wire [SEG-1:0] sum_c0;
            wire [SEG-1:0] sum_c1;
            wire carry_c0;
            wire carry_c1;

            dse_ripple_adder #(.W(SEG)) u_c0 (
                .a(a[segment*SEG +: SEG]),
                .b(b[segment*SEG +: SEG]),
                .cin(1'b0),
                .sum(sum_c0),
                .cout(carry_c0)
            );
            dse_ripple_adder #(.W(SEG)) u_c1 (
                .a(a[segment*SEG +: SEG]),
                .b(b[segment*SEG +: SEG]),
                .cin(1'b1),
                .sum(sum_c1),
                .cout(carry_c1)
            );

            assign sum[segment*SEG +: SEG] = selected_carry[segment] ?
                sum_c1 : sum_c0;
            assign selected_carry[segment+1] = selected_carry[segment] ?
                carry_c1 : carry_c0;
        end
        if ((W % SEG) != 0) begin : invalid_segmentation
            initial $error("dse_segmented_csel_adder requires W divisible by SEG");
        end
    endgenerate
    assign cout = selected_carry[NSEG];
endmodule

// Power-of-two Brent-Kung prefix tree: reduction followed by distribution.
module dse_brent_kung_adder #(
    parameter integer W = 32,
    parameter integer LG = $clog2(W)
) (
    input  wire [W-1:0] a,
    input  wire [W-1:0] b,
    input  wire         cin,
    output wire [W-1:0] sum,
    output wire         cout
);
    wire [W-1:0] bit_p = a ^ b;
    wire [W-1:0] prefix_g [0:(2*LG)-1];
    wire [W-1:0] prefix_p [0:(2*LG)-1];
    wire [W:0] carry;

    assign prefix_g[0] = a & b;
    assign prefix_p[0] = bit_p;

    generate
        genvar up_level, up_bit;
        for (up_level = 0; up_level < LG; up_level = up_level + 1) begin : upsweep
            localparam integer DIST = 1 << up_level;
            for (up_bit = 0; up_bit < W; up_bit = up_bit + 1) begin : nodes
                if (((up_bit + 1) % (2*DIST)) == 0) begin : combine
                    assign prefix_g[up_level+1][up_bit] =
                        prefix_g[up_level][up_bit] |
                        (prefix_p[up_level][up_bit] &
                         prefix_g[up_level][up_bit-DIST]);
                    assign prefix_p[up_level+1][up_bit] =
                        prefix_p[up_level][up_bit] &
                        prefix_p[up_level][up_bit-DIST];
                end else begin : pass
                    assign prefix_g[up_level+1][up_bit] = prefix_g[up_level][up_bit];
                    assign prefix_p[up_level+1][up_bit] = prefix_p[up_level][up_bit];
                end
            end
        end

        genvar down_level, down_bit;
        for (down_level = 0; down_level < LG-1; down_level = down_level + 1) begin : downsweep
            localparam integer DIST = 1 << (LG-2-down_level);
            localparam integer IN_STAGE = LG + down_level;
            localparam integer OUT_STAGE = IN_STAGE + 1;
            for (down_bit = 0; down_bit < W; down_bit = down_bit + 1) begin : nodes
                if ((down_bit >= (3*DIST-1)) &&
                    (((down_bit-(3*DIST-1)) % (2*DIST)) == 0)) begin : combine
                    assign prefix_g[OUT_STAGE][down_bit] =
                        prefix_g[IN_STAGE][down_bit] |
                        (prefix_p[IN_STAGE][down_bit] &
                         prefix_g[IN_STAGE][down_bit-DIST]);
                    assign prefix_p[OUT_STAGE][down_bit] =
                        prefix_p[IN_STAGE][down_bit] &
                        prefix_p[IN_STAGE][down_bit-DIST];
                end else begin : pass
                    assign prefix_g[OUT_STAGE][down_bit] = prefix_g[IN_STAGE][down_bit];
                    assign prefix_p[OUT_STAGE][down_bit] = prefix_p[IN_STAGE][down_bit];
                end
            end
        end

        if ((1 << LG) != W) begin : invalid_width
            initial $error("dse_brent_kung_adder requires power-of-two W");
        end
    endgenerate

    assign carry[0] = cin;
    generate
        genvar carry_bit;
        for (carry_bit = 0; carry_bit < W; carry_bit = carry_bit + 1) begin : carries
            assign carry[carry_bit+1] =
                prefix_g[(2*LG)-1][carry_bit] |
                (prefix_p[(2*LG)-1][carry_bit] & cin);
            assign sum[carry_bit] = bit_p[carry_bit] ^ carry[carry_bit];
        end
    endgenerate
    assign cout = carry[W];
endmodule

// Han-Carlson-style sparse prefix: adjacent-bit preprocessing, a prefix tree
// on odd endpoints, and one final grey-cell fill for even endpoints.
module dse_han_carlson_adder #(
    parameter integer W = 32,
    parameter integer LG = $clog2(W)
) (
    input  wire [W-1:0] a,
    input  wire [W-1:0] b,
    input  wire         cin,
    output wire [W-1:0] sum,
    output wire         cout
);
    wire [W-1:0] bit_p = a ^ b;
    wire [W-1:0] bit_g = a & b;
    wire [W-1:0] sparse_g [0:LG-1];
    wire [W-1:0] sparse_p [0:LG-1];
    wire [W-1:0] final_g;
    wire [W-1:0] final_p;
    wire [W:0] carry;

    generate
        genvar pair_bit;
        for (pair_bit = 0; pair_bit < W; pair_bit = pair_bit + 1) begin : pairs
            if ((pair_bit % 2) == 1) begin : combine
                assign sparse_g[0][pair_bit] = bit_g[pair_bit] |
                    (bit_p[pair_bit] & bit_g[pair_bit-1]);
                assign sparse_p[0][pair_bit] = bit_p[pair_bit] & bit_p[pair_bit-1];
            end else begin : pass
                assign sparse_g[0][pair_bit] = bit_g[pair_bit];
                assign sparse_p[0][pair_bit] = bit_p[pair_bit];
            end
        end

        genvar sparse_level, sparse_bit;
        for (sparse_level = 0; sparse_level < LG-1;
             sparse_level = sparse_level + 1) begin : sparse_tree
            localparam integer DIST = 1 << (sparse_level+1);
            for (sparse_bit = 0; sparse_bit < W; sparse_bit = sparse_bit + 1) begin : nodes
                if (((sparse_bit % 2) == 1) && (sparse_bit >= DIST)) begin : combine
                    assign sparse_g[sparse_level+1][sparse_bit] =
                        sparse_g[sparse_level][sparse_bit] |
                        (sparse_p[sparse_level][sparse_bit] &
                         sparse_g[sparse_level][sparse_bit-DIST]);
                    assign sparse_p[sparse_level+1][sparse_bit] =
                        sparse_p[sparse_level][sparse_bit] &
                        sparse_p[sparse_level][sparse_bit-DIST];
                end else begin : pass
                    assign sparse_g[sparse_level+1][sparse_bit] =
                        sparse_g[sparse_level][sparse_bit];
                    assign sparse_p[sparse_level+1][sparse_bit] =
                        sparse_p[sparse_level][sparse_bit];
                end
            end
        end

        genvar fill_bit;
        for (fill_bit = 0; fill_bit < W; fill_bit = fill_bit + 1) begin : fill
            if ((fill_bit > 0) && ((fill_bit % 2) == 0)) begin : combine
                assign final_g[fill_bit] = bit_g[fill_bit] |
                    (bit_p[fill_bit] & sparse_g[LG-1][fill_bit-1]);
                assign final_p[fill_bit] = bit_p[fill_bit] &
                    sparse_p[LG-1][fill_bit-1];
            end else begin : pass
                assign final_g[fill_bit] = sparse_g[LG-1][fill_bit];
                assign final_p[fill_bit] = sparse_p[LG-1][fill_bit];
            end
        end

        if ((1 << LG) != W) begin : invalid_width
            initial $error("dse_han_carlson_adder requires power-of-two W");
        end
    endgenerate

    assign carry[0] = cin;
    generate
        genvar carry_bit;
        for (carry_bit = 0; carry_bit < W; carry_bit = carry_bit + 1) begin : carries
            assign carry[carry_bit+1] = final_g[carry_bit] |
                (final_p[carry_bit] & cin);
            assign sum[carry_bit] = bit_p[carry_bit] ^ carry[carry_bit];
        end
    endgenerate
    assign cout = carry[W];
endmodule

// Common selector used by the CPA-only and integrated-PE experiments.
// IMPL 0: inferred; 1: segmented carry-select; 2: Brent-Kung; 3: Han-Carlson.
module dse_adder_select #(
    parameter integer W    = 32,
    parameter integer SEG  = 8,
    parameter integer IMPL = 0
) (
    input  wire [W-1:0] a,
    input  wire [W-1:0] b,
    input  wire         cin,
    output wire [W-1:0] sum,
    output wire         cout
);
    generate
        if (IMPL == 0) begin : inferred
            dse_inferred_adder #(.W(W)) u_adder(.*);
        end else if (IMPL == 1) begin : carry_select
            dse_segmented_csel_adder #(.W(W), .SEG(SEG)) u_adder(.*);
        end else if (IMPL == 2) begin : brent_kung
            dse_brent_kung_adder #(.W(W)) u_adder(.*);
        end else if (IMPL == 3) begin : han_carlson
            dse_han_carlson_adder #(.W(W)) u_adder(.*);
        end else begin : invalid_impl
            assign sum = {W{1'bx}};
            assign cout = 1'bx;
            initial $error("unsupported dse_adder_select IMPL");
        end
    endgenerate
endmodule

module dse_int4_inferred_rows (
    input  wire signed [3:0] a,
    input  wire signed [3:0] b,
    output wire        [7:0] product_sum,
    output wire        [7:0] product_carry_shifted
);
    wire signed [7:0] product = a * b;
    assign product_sum = product;
    assign product_carry_shifted = 8'b0;
endmodule

// Four-by-four Baugh-Wooley matrix.  The six sign-crossing partial products
// are complemented and correction bits are added at weights 4 and 7.  A
// balanced CSA tree produces exactly two modulo-2^8 rows; there is no CPA in
// this module.
module dse_int4_baugh_wooley_rows (
    input  wire signed [3:0] a,
    input  wire signed [3:0] b,
    output wire        [7:0] product_sum,
    output wire        [7:0] product_carry_shifted
);
    wire [7:0] row0 = {4'b0, ~(a[0]&b[3]), a[0]&b[2], a[0]&b[1], a[0]&b[0]};
    wire [7:0] row1 = {3'b0, ~(a[1]&b[3]), a[1]&b[2], a[1]&b[1], a[1]&b[0], 1'b0};
    wire [7:0] row2 = {2'b0, ~(a[2]&b[3]), a[2]&b[2], a[2]&b[1], a[2]&b[0], 2'b0};
    wire [7:0] row3 = {1'b0, a[3]&b[3], ~(a[3]&b[2]), ~(a[3]&b[1]),
                       ~(a[3]&b[0]), 3'b0};
    wire [7:0] correction = 8'b1001_0000;
    wire [7:0] s0, c0, s1, c1, s2, c2;

    dse_csa3 #(.W(8)) u_csa0(.x(row0), .y(row1), .z(row2),
        .sum(s0), .carry_shifted(c0));
    dse_csa3 #(.W(8)) u_csa1(.x(row3), .y(correction), .z(8'b0),
        .sum(s1), .carry_shifted(c1));
    dse_csa3 #(.W(8)) u_csa2(.x(s0), .y(c0), .z(s1),
        .sum(s2), .carry_shifted(c2));
    dse_csa3 #(.W(8)) u_csa3(.x(s2), .y(c2), .z(c1),
        .sum(product_sum), .carry_shifted(product_carry_shifted));
endmodule

module dse_int4_booth_rows (
    input  wire signed [3:0] a,
    input  wire signed [3:0] b,
    output wire        [7:0] product_sum,
    output wire        [7:0] product_carry_shifted
);
    function automatic signed [7:0] booth_term;
        input signed [3:0] multiplicand;
        input        [2:0] code;
        input              shift_two;
        reg signed [7:0] extended_value;
        reg signed [7:0] selected_value;
        begin
            extended_value = {{4{multiplicand[3]}}, multiplicand};
            case (code)
                3'b001, 3'b010: selected_value = extended_value;
                3'b011:         selected_value = extended_value <<< 1;
                3'b100:         selected_value = -(extended_value <<< 1);
                3'b101, 3'b110: selected_value = -extended_value;
                default:        selected_value = 8'sd0;
            endcase
            booth_term = shift_two ? (selected_value <<< 2) : selected_value;
        end
    endfunction

    assign product_sum = booth_term(b, {a[1:0], 1'b0}, 1'b0);
    assign product_carry_shifted = booth_term(b, a[3:1], 1'b1);
endmodule

module dse_int8_inferred_rows (
    input  wire signed [7:0]  a,
    input  wire signed [7:0]  b,
    output wire        [17:0] product_sum,
    output wire        [17:0] product_carry_shifted
);
    wire signed [15:0] product = a * b;
    assign product_sum = {{2{product[15]}}, product};
    assign product_carry_shifted = 18'b0;
endmodule

// Radix-4 INT8 Booth generation with every PP, correction, and sign bit
// consumed before M1.  The only M1 outputs are sum and shifted carry rows.
module dse_int8_booth_two_row (
    input  wire signed [7:0]  a,
    input  wire signed [7:0]  b,
    output wire        [17:0] product_sum,
    output wire        [17:0] product_carry_shifted
);
    function automatic signed [17:0] booth_term;
        input signed [7:0] multiplicand;
        input        [2:0] code;
        input        [2:0] shift_amount;
        reg signed [17:0] extended_value;
        reg signed [17:0] selected_value;
        begin
            extended_value = {{10{multiplicand[7]}}, multiplicand};
            case (code)
                3'b001, 3'b010: selected_value = extended_value;
                3'b011:         selected_value = extended_value <<< 1;
                3'b100:         selected_value = -(extended_value <<< 1);
                3'b101, 3'b110: selected_value = -extended_value;
                default:        selected_value = 18'sd0;
            endcase
            booth_term = selected_value <<< shift_amount;
        end
    endfunction

    wire [17:0] pp0 = booth_term(b, {a[1:0], 1'b0}, 3'd0);
    wire [17:0] pp1 = booth_term(b, a[3:1], 3'd2);
    wire [17:0] pp2 = booth_term(b, a[5:3], 3'd4);
    wire [17:0] pp3 = booth_term(b, a[7:5], 3'd6);
    wire [17:0] first_sum, first_carry;

    dse_csa3 #(.W(18)) u_first_compressor(
        .x(pp0), .y(pp1), .z(pp2),
        .sum(first_sum), .carry_shifted(first_carry));
    dse_csa3 #(.W(18)) u_final_compressor(
        .x(first_sum), .y(first_carry), .z(pp3),
        .sum(product_sum), .carry_shifted(product_carry_shifted));
endmodule

`default_nettype wire
