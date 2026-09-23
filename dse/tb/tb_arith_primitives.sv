`default_nettype none
`timescale 1ns/1ps

module tb_arith_primitives;
    reg signed [3:0] a4, b4;
    wire [7:0] i4_inf_s, i4_inf_c;
    wire [7:0] i4_bw_s, i4_bw_c;
    wire [7:0] i4_booth_s, i4_booth_c;

    reg signed [7:0] a8, b8;
    wire [17:0] i8_inf_s, i8_inf_c;
    wire [17:0] i8_booth_s, i8_booth_c;

    reg [15:0] add16_a, add16_b;
    reg add16_cin;
    wire [15:0] add16_sum [0:3];
    wire [3:0] add16_cout;

    reg [31:0] add32_a, add32_b;
    reg add32_cin;
    wire [31:0] add32_sum [0:3];
    wire [3:0] add32_cout;

    integer ai, bi, impl, trial;
    integer errors;
    reg signed [7:0] expected_i4;
    reg signed [15:0] expected_i8;
    reg [16:0] expected_add16;
    reg [32:0] expected_add32;

    dse_int4_inferred_rows u_i4_inf(.a(a4), .b(b4),
        .product_sum(i4_inf_s), .product_carry_shifted(i4_inf_c));
    dse_int4_baugh_wooley_rows u_i4_bw(.a(a4), .b(b4),
        .product_sum(i4_bw_s), .product_carry_shifted(i4_bw_c));
    dse_int4_booth_rows u_i4_booth(.a(a4), .b(b4),
        .product_sum(i4_booth_s), .product_carry_shifted(i4_booth_c));

    dse_int8_inferred_rows u_i8_inf(.a(a8), .b(b8),
        .product_sum(i8_inf_s), .product_carry_shifted(i8_inf_c));
    dse_int8_booth_two_row u_i8_booth(.a(a8), .b(b8),
        .product_sum(i8_booth_s), .product_carry_shifted(i8_booth_c));

    generate
        genvar add_impl;
        for (add_impl = 0; add_impl < 4; add_impl = add_impl + 1) begin : adders
            dse_adder_select #(.W(16), .SEG(4), .IMPL(add_impl)) u_add16(
                .a(add16_a), .b(add16_b), .cin(add16_cin),
                .sum(add16_sum[add_impl]), .cout(add16_cout[add_impl]));
            dse_adder_select #(.W(32), .SEG(8), .IMPL(add_impl)) u_add32(
                .a(add32_a), .b(add32_b), .cin(add32_cin),
                .sum(add32_sum[add_impl]), .cout(add32_cout[add_impl]));
        end
    endgenerate

    initial begin
        errors = 0;
        a4 = 0;
        b4 = 0;
        a8 = 0;
        b8 = 0;
        add16_a = 0;
        add16_b = 0;
        add16_cin = 0;
        add32_a = 0;
        add32_b = 0;
        add32_cin = 0;

        for (ai = -8; ai <= 7; ai = ai + 1) begin
            for (bi = -8; bi <= 7; bi = bi + 1) begin
                a4 = ai;
                b4 = bi;
                expected_i4 = ai * bi;
                #1;
                if ((i4_inf_s + i4_inf_c) !== expected_i4) errors = errors + 1;
                if ((i4_bw_s + i4_bw_c) !== expected_i4) errors = errors + 1;
                if ((i4_booth_s + i4_booth_c) !== expected_i4) errors = errors + 1;
            end
        end

        for (ai = -128; ai <= 127; ai = ai + 1) begin
            for (bi = -128; bi <= 127; bi = bi + 1) begin
                a8 = ai;
                b8 = bi;
                expected_i8 = ai * bi;
                #1;
                if ((i8_inf_s[15:0] + i8_inf_c[15:0]) !== expected_i8)
                    errors = errors + 1;
                if ((i8_booth_s[15:0] + i8_booth_c[15:0]) !== expected_i8)
                    errors = errors + 1;
            end
        end

        for (trial = 0; trial < 10000; trial = trial + 1) begin
            add16_a = $urandom;
            add16_b = $urandom;
            add16_cin = $urandom;
            add32_a = $urandom;
            add32_b = $urandom;
            add32_cin = $urandom;
            #1;
            expected_add16 = {1'b0, add16_a} + {1'b0, add16_b} + add16_cin;
            expected_add32 = {1'b0, add32_a} + {1'b0, add32_b} + add32_cin;
            for (impl = 0; impl < 4; impl = impl + 1) begin
                if ({add16_cout[impl], add16_sum[impl]} !== expected_add16)
                    errors = errors + 1;
                if ({add32_cout[impl], add32_sum[impl]} !== expected_add32)
                    errors = errors + 1;
            end
        end

        if (errors == 0)
            $display("PASS: arithmetic primitive equivalence");
        else
            $fatal(1, "FAIL: %0d arithmetic mismatches", errors);
        $finish;
    end
endmodule

`default_nettype wire
