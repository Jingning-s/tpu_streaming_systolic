`default_nettype none
`timescale 1ns/1ps

// Four timing-isolated INT8 compression candidates.  All variants represent
// the exact signed 8x8 product as four modulo-2^18 rows at the M1 boundary.
// B0: current asymmetric radix-4 Booth (3 compressed rows + zero).
// B1: balanced radix-4 Booth pair compression (4 rows).
// B2: radix-2 signed partial products with a balanced CSA tree (no recoder).
// B3: behavioral signed multiply baseline (product row + zeros).
// IMPL4/5/6 are B2 mapping refinements.  IMPL7/8/9 are exact-16 B2
// refinements; see the generate branches below.
module dse_b_m1_rows #(
    parameter integer IMPL = 0
) (
    input  wire signed [7:0] a,
    input  wire signed [7:0] b,
    output wire        [17:0] row0,
    output wire        [17:0] row1,
    output wire        [17:0] row2,
    output wire        [17:0] row3
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

    wire [17:0] booth_pp0 = booth_term(b, {a[1:0], 1'b0}, 3'd0);
    wire [17:0] booth_pp1 = booth_term(b, a[3:1], 3'd2);
    wire [17:0] booth_pp2 = booth_term(b, a[5:3], 3'd4);
    wire [17:0] booth_pp3 = booth_term(b, a[7:5], 3'd6);

    generate
        if (IMPL == 0) begin : b0_current_booth
            dse_csa3 #(.W(18)) u_first(
                .x(booth_pp0), .y(booth_pp1), .z(booth_pp2),
                .sum(row0), .carry_shifted(row1));
            assign row2 = booth_pp3;
            assign row3 = 18'b0;
        end else if (IMPL == 1) begin : b1_balanced_booth
            dse_csa3 #(.W(18)) u_pair01(
                .x(booth_pp0), .y(booth_pp1), .z(18'b0),
                .sum(row0), .carry_shifted(row1));
            dse_csa3 #(.W(18)) u_pair23(
                .x(booth_pp2), .y(booth_pp3), .z(18'b0),
                .sum(row2), .carry_shifted(row3));
        end else if ((IMPL == 2) || (IMPL == 5)) begin : b2_radix2_mux_pp
            wire signed [17:0] b_ext = {{10{b[7]}}, b};
            wire [17:0] pp0 = a[0] ? (b_ext <<< 0) : 18'b0;
            wire [17:0] pp1 = a[1] ? (b_ext <<< 1) : 18'b0;
            wire [17:0] pp2 = a[2] ? (b_ext <<< 2) : 18'b0;
            wire [17:0] pp3 = a[3] ? (b_ext <<< 3) : 18'b0;
            wire [17:0] pp4 = a[4] ? (b_ext <<< 4) : 18'b0;
            wire [17:0] pp5 = a[5] ? (b_ext <<< 5) : 18'b0;
            wire [17:0] pp6 = a[6] ? (b_ext <<< 6) : 18'b0;
            wire [17:0] pp7 = a[7] ? -(b_ext <<< 7) : 18'b0;
            wire [17:0] l0s, l0c, l1s, l1c;

            dse_csa3 #(.W(18)) u_l0a(
                .x(pp0), .y(pp1), .z(pp2),
                .sum(l0s), .carry_shifted(l0c));
            dse_csa3 #(.W(18)) u_l0b(
                .x(pp3), .y(pp4), .z(pp5),
                .sum(l1s), .carry_shifted(l1c));
            dse_csa3 #(.W(18)) u_l1a(
                .x(l0s), .y(l0c), .z(l1s),
                .sum(row0), .carry_shifted(row1));
            dse_csa3 #(.W(18)) u_l1b(
                .x(l1c), .y(pp6), .z(pp7),
                .sum(row2), .carry_shifted(row3));
        end else if ((IMPL == 4) || (IMPL == 6)) begin : b2_radix2_mask_pp
            wire signed [17:0] b_ext = {{10{b[7]}}, b};
            wire [17:0] pp0 = {18{a[0]}} & (b_ext <<< 0);
            wire [17:0] pp1 = {18{a[1]}} & (b_ext <<< 1);
            wire [17:0] pp2 = {18{a[2]}} & (b_ext <<< 2);
            wire [17:0] pp3 = {18{a[3]}} & (b_ext <<< 3);
            wire [17:0] pp4 = {18{a[4]}} & (b_ext <<< 4);
            wire [17:0] pp5 = {18{a[5]}} & (b_ext <<< 5);
            wire [17:0] pp6 = {18{a[6]}} & (b_ext <<< 6);
            wire [17:0] pp7 = {18{a[7]}} & (-(b_ext <<< 7));
            wire [17:0] l0s, l0c, l1s, l1c;

            dse_csa3 #(.W(18)) u_l0a(
                .x(pp0), .y(pp1), .z(pp2),
                .sum(l0s), .carry_shifted(l0c));
            dse_csa3 #(.W(18)) u_l0b(
                .x(pp3), .y(pp4), .z(pp5),
                .sum(l1s), .carry_shifted(l1c));
            dse_csa3 #(.W(18)) u_l1a(
                .x(l0s), .y(l0c), .z(l1s),
                .sum(row0), .carry_shifted(row1));
            dse_csa3 #(.W(18)) u_l1b(
                .x(l1c), .y(pp6), .z(pp7),
                .sum(row2), .carry_shifted(row3));
        end else if (IMPL == 7) begin : b2_exact16_radix2
            wire signed [15:0] b_ext = {{8{b[7]}}, b};
            wire [15:0] pp0 = a[0] ? (b_ext <<< 0) : 16'b0;
            wire [15:0] pp1 = a[1] ? (b_ext <<< 1) : 16'b0;
            wire [15:0] pp2 = a[2] ? (b_ext <<< 2) : 16'b0;
            wire [15:0] pp3 = a[3] ? (b_ext <<< 3) : 16'b0;
            wire [15:0] pp4 = a[4] ? (b_ext <<< 4) : 16'b0;
            wire [15:0] pp5 = a[5] ? (b_ext <<< 5) : 16'b0;
            wire [15:0] pp6 = a[6] ? (b_ext <<< 6) : 16'b0;
            wire [15:0] pp7 = a[7] ? -(b_ext <<< 7) : 16'b0;
            wire [15:0] l0s, l0c, l1s, l1c;
            wire [15:0] out0, out1, out2, out3;

            dse_csa3 #(.W(16)) u_l0a(.x(pp0), .y(pp1), .z(pp2),
                .sum(l0s), .carry_shifted(l0c));
            dse_csa3 #(.W(16)) u_l0b(.x(pp3), .y(pp4), .z(pp5),
                .sum(l1s), .carry_shifted(l1c));
            dse_csa3 #(.W(16)) u_l1a(.x(l0s), .y(l0c), .z(l1s),
                .sum(out0), .carry_shifted(out1));
            dse_csa3 #(.W(16)) u_l1b(.x(l1c), .y(pp6), .z(pp7),
                .sum(out2), .carry_shifted(out3));
            assign row0 = {2'b0, out0};
            assign row1 = {2'b0, out1};
            assign row2 = {2'b0, out2};
            assign row3 = {2'b0, out3};
        end else if ((IMPL == 8) || (IMPL == 9)) begin : b2_exact16_bw
            // Baugh-Wooley matrix.  Sign-crossing terms are complemented.
            // The modulo-2^16 correction is 16'h8100 (bits 15 and 8), both
            // placed in otherwise empty columns of pp0.
            wire [15:0] pp0 = {1'b1, 6'b0, 1'b1,
                ~(a[0]&b[7]), a[0]&b[6], a[0]&b[5], a[0]&b[4],
                a[0]&b[3], a[0]&b[2], a[0]&b[1], a[0]&b[0]};
            wire [15:0] pp1 = {7'b0, ~(a[1]&b[7]),
                a[1]&b[6], a[1]&b[5], a[1]&b[4], a[1]&b[3],
                a[1]&b[2], a[1]&b[1], a[1]&b[0], 1'b0};
            wire [15:0] pp2 = {6'b0, ~(a[2]&b[7]),
                a[2]&b[6], a[2]&b[5], a[2]&b[4], a[2]&b[3],
                a[2]&b[2], a[2]&b[1], a[2]&b[0], 2'b0};
            wire [15:0] pp3 = {5'b0, ~(a[3]&b[7]),
                a[3]&b[6], a[3]&b[5], a[3]&b[4], a[3]&b[3],
                a[3]&b[2], a[3]&b[1], a[3]&b[0], 3'b0};
            wire [15:0] pp4 = {4'b0, ~(a[4]&b[7]),
                a[4]&b[6], a[4]&b[5], a[4]&b[4], a[4]&b[3],
                a[4]&b[2], a[4]&b[1], a[4]&b[0], 4'b0};
            wire [15:0] pp5 = {3'b0, ~(a[5]&b[7]),
                a[5]&b[6], a[5]&b[5], a[5]&b[4], a[5]&b[3],
                a[5]&b[2], a[5]&b[1], a[5]&b[0], 5'b0};
            wire [15:0] pp6 = {2'b0, ~(a[6]&b[7]),
                a[6]&b[6], a[6]&b[5], a[6]&b[4], a[6]&b[3],
                a[6]&b[2], a[6]&b[1], a[6]&b[0], 6'b0};
            wire [15:0] pp7 = {1'b0, a[7]&b[7],
                ~(a[7]&b[6]), ~(a[7]&b[5]), ~(a[7]&b[4]),
                ~(a[7]&b[3]), ~(a[7]&b[2]), ~(a[7]&b[1]),
                ~(a[7]&b[0]), 7'b0};
            wire [15:0] out0, out1, out2, out3;

            if (IMPL == 8) begin : wallace_schedule
                wire [15:0] l0s, l0c, l1s, l1c;
                dse_csa3 #(.W(16)) u_l0a(.x(pp0), .y(pp1), .z(pp2),
                    .sum(l0s), .carry_shifted(l0c));
                dse_csa3 #(.W(16)) u_l0b(.x(pp3), .y(pp4), .z(pp5),
                    .sum(l1s), .carry_shifted(l1c));
                dse_csa3 #(.W(16)) u_l1a(.x(l0s), .y(l0c), .z(l1s),
                    .sum(out0), .carry_shifted(out1));
                dse_csa3 #(.W(16)) u_l1b(.x(l1c), .y(pp6), .z(pp7),
                    .sum(out2), .carry_shifted(out3));
            end else begin : paired_4to2_schedule
                dse_csa4_direct #(.W(16)) u_lower_group(
                    .x(pp0), .y(pp1), .z(pp2), .w(pp3),
                    .sum(out0), .carry_shifted(out1));
                dse_csa4_direct #(.W(16)) u_upper_group(
                    .x(pp4), .y(pp5), .z(pp6), .w(pp7),
                    .sum(out2), .carry_shifted(out3));
            end
            assign row0 = {2'b0, out0};
            assign row1 = {2'b0, out1};
            assign row2 = {2'b0, out2};
            assign row3 = {2'b0, out3};
        end else if (IMPL == 3) begin : b3_inferred
            wire signed [15:0] product = a * b;
            assign row0 = {{2{product[15]}}, product};
            assign row1 = 18'b0;
            assign row2 = 18'b0;
            assign row3 = 18'b0;
        end else begin : invalid
            assign row0 = 18'bx;
            assign row1 = 18'bx;
            assign row2 = 18'bx;
            assign row3 = 18'bx;
            initial $error("unsupported B candidate");
        end
    endgenerate
endmodule

// Direct four-row carry-save reduction.  This is mathematically identical to
// two cascaded dse_csa3 instances, but exposes the complete bit equations in
// one module so Genus can choose AOI/OAI/XOR structures across the boundary.
// There is still no horizontal carry propagation.
module dse_csa4_direct #(
    parameter integer W = 18
) (
    input  wire [W-1:0] x,
    input  wire [W-1:0] y,
    input  wire [W-1:0] z,
    input  wire [W-1:0] w,
    output wire [W-1:0] sum,
    output wire [W-1:0] carry_shifted
);
    wire [W-1:0] first_sum = x ^ y ^ z;
    wire [W-1:0] first_carry =
        ((x & y) | (x & z) | (y & z)) << 1;
    assign sum = first_sum ^ first_carry ^ w;
    assign carry_shifted =
        ((first_sum & first_carry) |
         (first_sum & w) | (first_carry & w)) << 1;
endmodule

// M2 reduces the registered M1 representation to exactly two rows.  B0 needs
// one 3:2 compressor, B1/B2 need a balanced 4:2 reduction, and B3 is a pass.
module dse_b_m2_rows #(
    parameter integer IMPL = 0
) (
    input  wire [17:0] row0,
    input  wire [17:0] row1,
    input  wire [17:0] row2,
    input  wire [17:0] row3,
    output wire [17:0] product_sum,
    output wire [17:0] product_carry
);
    generate
        if (IMPL == 0) begin : b0_reduce
            dse_csa3 #(.W(18)) u_reduce(
                .x(row0), .y(row1), .z(row2),
                .sum(product_sum), .carry_shifted(product_carry));
        end else if ((IMPL == 1) || (IMPL == 2) ||
                     (IMPL == 4)) begin : cascaded_reduce
            wire [17:0] tmp_sum, tmp_carry;
            dse_csa3 #(.W(18)) u_reduce0(
                .x(row0), .y(row1), .z(row2),
                .sum(tmp_sum), .carry_shifted(tmp_carry));
            dse_csa3 #(.W(18)) u_reduce1(
                .x(tmp_sum), .y(tmp_carry), .z(row3),
                .sum(product_sum), .carry_shifted(product_carry));
        end else if ((IMPL == 5) || (IMPL == 6)) begin : direct_reduce
            dse_csa4_direct #(.W(18)) u_reduce(
                .x(row0), .y(row1), .z(row2), .w(row3),
                .sum(product_sum), .carry_shifted(product_carry));
        end else if ((IMPL == 7) || (IMPL == 8) ||
                     (IMPL == 9)) begin : exact16_reduce
            wire [15:0] tmp_sum, tmp_carry;
            wire [15:0] final_sum, final_carry;
            dse_csa3 #(.W(16)) u_reduce0(
                .x(row0[15:0]), .y(row1[15:0]), .z(row2[15:0]),
                .sum(tmp_sum), .carry_shifted(tmp_carry));
            dse_csa3 #(.W(16)) u_reduce1(
                .x(tmp_sum), .y(tmp_carry), .z(row3[15:0]),
                .sum(final_sum), .carry_shifted(final_carry));
            assign product_sum = {2'b0, final_sum};
            assign product_carry = {2'b0, final_carry};
        end else if (IMPL == 3) begin : b3_pass
            assign product_sum = row0;
            assign product_carry = 18'b0;
        end else begin : invalid
            assign product_sum = 18'bx;
            assign product_carry = 18'bx;
        end
    endgenerate
endmodule

// One legal mesh PE boundary.  M0 is both the local operand/token register and
// the neighbor hop: A and its valid move east; B and its valid move south.
// Arithmetic consumes those same M0 registers.  A/B valid remain independent
// through the hop and are paired locally for result validity.
module dse_b_mesh_node #(
    parameter integer IMPL = 0
) (
    input  wire        clk,
    input  wire        reset,
    input  wire [7:0]  a_west,
    input  wire [7:0]  b_north,
    input  wire        a_valid_west,
    input  wire        b_valid_north,
    output wire [7:0]  a_east,
    output wire [7:0]  b_south,
    output wire        a_valid_east,
    output wire        b_valid_south,
    output wire [17:0] product_sum,
    output wire [17:0] product_carry,
    output wire        product_valid
);
    reg [7:0] m0_a, m0_b;
    reg m0_a_valid, m0_b_valid;
    wire [17:0] m1_row0_next, m1_row1_next, m1_row2_next, m1_row3_next;
    reg [17:0] m1_row0, m1_row1, m1_row2, m1_row3;
    reg m1_valid;
    wire [17:0] m2_sum_next, m2_carry_next;
    reg [17:0] m2_sum, m2_carry;
    reg m2_valid;

    dse_b_m1_rows #(.IMPL(IMPL)) u_m1(
        .a(m0_a), .b(m0_b), .row0(m1_row0_next), .row1(m1_row1_next),
        .row2(m1_row2_next), .row3(m1_row3_next));
    dse_b_m2_rows #(.IMPL(IMPL)) u_m2(
        .row0(m1_row0), .row1(m1_row1), .row2(m1_row2), .row3(m1_row3),
        .product_sum(m2_sum_next), .product_carry(m2_carry_next));

    always_ff @(posedge clk) begin
        m0_a <= a_west;
        m0_b <= b_north;
        m1_row0 <= m1_row0_next;
        m1_row1 <= m1_row1_next;
        m1_row2 <= m1_row2_next;
        m1_row3 <= m1_row3_next;
        m2_sum <= m2_sum_next;
        m2_carry <= m2_carry_next;
        if (reset) begin
            m0_a_valid <= 1'b0;
            m0_b_valid <= 1'b0;
            m1_valid <= 1'b0;
            m2_valid <= 1'b0;
        end else begin
            m0_a_valid <= a_valid_west;
            m0_b_valid <= b_valid_north;
            m1_valid <= m0_a_valid & m0_b_valid;
            m2_valid <= m1_valid;
        end
    end

    assign a_east = m0_a;
    assign b_south = m0_b;
    assign a_valid_east = m0_a_valid;
    assign b_valid_south = m0_b_valid;
    assign product_sum = m2_sum;
    assign product_carry = m2_carry;
    assign product_valid = m2_valid;
endmodule

// Four independent replicas expose unique operand and valid ports.  Unlike
// the old 2x2 harness, no two replicas are functionally equivalent, so Genus
// cannot legally merge their M0/token/state registers across instances.
module dse_b_replica_top #(
    parameter integer IMPL = 0
) (
    input  wire         clk,
    input  wire         reset,
    input  wire [31:0]  a_in,
    input  wire [31:0]  b_in,
    input  wire [3:0]   a_valid_in,
    input  wire [3:0]   b_valid_in,
    output wire [71:0]  product_sum,
    output wire [71:0]  product_carry,
    output wire [3:0]   product_valid,
    output wire [31:0]  a_hop_observe,
    output wire [31:0]  b_hop_observe
);
    generate
        genvar replica;
        for (replica = 0; replica < 4; replica = replica + 1) begin : reps
            wire a_valid_hop, b_valid_hop;
            dse_b_mesh_node #(.IMPL(IMPL)) u_node(
                .clk(clk), .reset(reset),
                .a_west(a_in[replica*8 +: 8]),
                .b_north(b_in[replica*8 +: 8]),
                .a_valid_west(a_valid_in[replica]),
                .b_valid_north(b_valid_in[replica]),
                .a_east(a_hop_observe[replica*8 +: 8]),
                .b_south(b_hop_observe[replica*8 +: 8]),
                .a_valid_east(a_valid_hop), .b_valid_south(b_valid_hop),
                .product_sum(product_sum[replica*18 +: 18]),
                .product_carry(product_carry[replica*18 +: 18]),
                .product_valid(product_valid[replica]));
        end
    endgenerate
endmodule

// Real 2x2 mesh.  Only winners from the Replica screen should be elaborated.
// The four boundary operands and valid streams are independent.  PE01 must
// receive A exclusively through PE00; PE10 must receive B through PE00, etc.
module dse_b_mesh2x2_top #(
    parameter integer IMPL = 0
) (
    input  wire         clk,
    input  wire         reset,
    input  wire [15:0]  a_left,
    input  wire [15:0]  b_top,
    input  wire [1:0]   a_valid_left,
    input  wire [1:0]   b_valid_top,
    output wire [71:0]  product_sum,
    output wire [71:0]  product_carry,
    output wire [3:0]   product_valid,
    output wire [15:0]  a_right,
    output wire [15:0]  b_bottom
);
    wire [7:0] a_00_e, a_01_e, a_10_e, a_11_e;
    wire [7:0] b_00_s, b_01_s, b_10_s, b_11_s;
    wire av_00_e, av_01_e, av_10_e, av_11_e;
    wire bv_00_s, bv_01_s, bv_10_s, bv_11_s;

    dse_b_mesh_node #(.IMPL(IMPL)) u_pe00(
        .clk(clk), .reset(reset), .a_west(a_left[7:0]),
        .b_north(b_top[7:0]), .a_valid_west(a_valid_left[0]),
        .b_valid_north(b_valid_top[0]), .a_east(a_00_e),
        .b_south(b_00_s), .a_valid_east(av_00_e),
        .b_valid_south(bv_00_s), .product_sum(product_sum[17:0]),
        .product_carry(product_carry[17:0]), .product_valid(product_valid[0]));
    dse_b_mesh_node #(.IMPL(IMPL)) u_pe01(
        .clk(clk), .reset(reset), .a_west(a_00_e),
        .b_north(b_top[15:8]), .a_valid_west(av_00_e),
        .b_valid_north(b_valid_top[1]), .a_east(a_01_e),
        .b_south(b_01_s), .a_valid_east(av_01_e),
        .b_valid_south(bv_01_s), .product_sum(product_sum[35:18]),
        .product_carry(product_carry[35:18]), .product_valid(product_valid[1]));
    dse_b_mesh_node #(.IMPL(IMPL)) u_pe10(
        .clk(clk), .reset(reset), .a_west(a_left[15:8]),
        .b_north(b_00_s), .a_valid_west(a_valid_left[1]),
        .b_valid_north(bv_00_s), .a_east(a_10_e),
        .b_south(b_10_s), .a_valid_east(av_10_e),
        .b_valid_south(bv_10_s), .product_sum(product_sum[53:36]),
        .product_carry(product_carry[53:36]), .product_valid(product_valid[2]));
    dse_b_mesh_node #(.IMPL(IMPL)) u_pe11(
        .clk(clk), .reset(reset), .a_west(a_10_e),
        .b_north(b_01_s), .a_valid_west(av_10_e),
        .b_valid_north(bv_01_s), .a_east(a_11_e),
        .b_south(b_11_s), .a_valid_east(av_11_e),
        .b_valid_south(bv_11_s), .product_sum(product_sum[71:54]),
        .product_carry(product_carry[71:54]), .product_valid(product_valid[3]));

    assign a_right = {a_11_e, a_01_e};
    assign b_bottom = {b_11_s, b_10_s};
endmodule

`default_nettype wire
