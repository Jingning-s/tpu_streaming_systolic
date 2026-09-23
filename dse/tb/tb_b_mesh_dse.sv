`default_nettype none
`timescale 1ns/1ps

module tb_b_mesh_dse;
    reg signed [7:0] a, b;
    wire [17:0] r0 [0:3];
    wire [17:0] r1 [0:3];
    wire [17:0] r2 [0:3];
    wire [17:0] r3 [0:3];
    wire [17:0] ps [0:3];
    wire [17:0] pc [0:3];
    reg signed [17:0] expected;
    integer ai, bi, impl, errors;

    generate
        genvar candidate;
        for (candidate = 0; candidate < 4; candidate = candidate + 1) begin : c
            dse_b_m1_rows #(.IMPL(candidate)) u_m1(
                .a(a), .b(b), .row0(r0[candidate]), .row1(r1[candidate]),
                .row2(r2[candidate]), .row3(r3[candidate]));
            dse_b_m2_rows #(.IMPL(candidate)) u_m2(
                .row0(r0[candidate]), .row1(r1[candidate]),
                .row2(r2[candidate]), .row3(r3[candidate]),
                .product_sum(ps[candidate]), .product_carry(pc[candidate]));
        end
    endgenerate

    initial begin
        errors = 0;
        a = 0;
        b = 0;
        for (ai = -128; ai <= 127; ai = ai + 1) begin
            for (bi = -128; bi <= 127; bi = bi + 1) begin
                a = ai;
                b = bi;
                expected = ai * bi;
                #1;
                for (impl = 0; impl < 4; impl = impl + 1) begin
                    if ((ps[impl] + pc[impl]) !== expected) begin
                        $error("B%0d: %0d * %0d got %0d expected %0d",
                            impl, ai, bi, $signed(ps[impl] + pc[impl]), expected);
                        errors = errors + 1;
                    end
                end
            end
        end
        if (errors == 0)
            $display("PASS: B0/B1/B2/B3 exhaustive signed 8x8 equivalence");
        else
            $fatal(1, "FAIL: %0d B-candidate mismatches", errors);
        $finish;
    end
endmodule

module tb_b_mesh_connectivity;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg [15:0] a_left, b_top;
    reg [1:0] a_valid_left, b_valid_top;
    wire [71:0] product_sum, product_carry;
    wire [3:0] product_valid;
    wire [15:0] a_right, b_bottom;
    reg [15:0] a_delay0, a_delay1, b_delay0, b_delay1;
    reg [1:0] av_delay0, av_delay1, bv_delay0, bv_delay1;
    reg [1:0] history_valid;
    integer cycle, errors;

    always #0.5 clk = ~clk;

    dse_b_mesh2x2_top #(.IMPL(0)) u_mesh(
        .clk(clk), .reset(reset), .a_left(a_left), .b_top(b_top),
        .a_valid_left(a_valid_left), .b_valid_top(b_valid_top),
        .product_sum(product_sum), .product_carry(product_carry),
        .product_valid(product_valid), .a_right(a_right),
        .b_bottom(b_bottom));

    always @(posedge clk) begin
        if (reset) begin
            a_delay0 <= 16'b0;
            a_delay1 <= 16'b0;
            b_delay0 <= 16'b0;
            b_delay1 <= 16'b0;
            av_delay0 <= 2'b0;
            av_delay1 <= 2'b0;
            bv_delay0 <= 2'b0;
            bv_delay1 <= 2'b0;
            history_valid <= 2'b0;
        end else begin
            a_delay0 <= a_left;
            a_delay1 <= a_delay0;
            b_delay0 <= b_top;
            b_delay1 <= b_delay0;
            av_delay0 <= a_valid_left;
            av_delay1 <= av_delay0;
            bv_delay0 <= b_valid_top;
            bv_delay1 <= bv_delay0;
            history_valid <= {history_valid[0], 1'b1};
        end
        #0.01;
        if (!reset && history_valid[1]) begin
            if (a_right !== a_delay1) begin
                $error("illegal/missing A east-hop at cycle %0d", cycle);
                errors = errors + 1;
            end
            if (b_bottom !== b_delay1) begin
                $error("illegal/missing B south-hop at cycle %0d", cycle);
                errors = errors + 1;
            end
            if ({u_mesh.av_11_e, u_mesh.av_01_e} !== av_delay1) begin
                $error("A valid did not follow A payload at cycle %0d", cycle);
                errors = errors + 1;
            end
            if ({u_mesh.bv_11_s, u_mesh.bv_10_s} !== bv_delay1) begin
                $error("B valid did not follow B payload at cycle %0d", cycle);
                errors = errors + 1;
            end
        end
    end

    initial begin
        errors = 0;
        cycle = 0;
        a_left = 16'b0;
        b_top = 16'b0;
        a_valid_left = 2'b0;
        b_valid_top = 2'b0;
        repeat (3) @(negedge clk);
        reset = 1'b0;
        for (cycle = 0; cycle < 24; cycle = cycle + 1) begin
            @(negedge clk);
            a_left[7:0] = cycle * 5 + 1;
            a_left[15:8] = cycle * 7 + 3;
            b_top[7:0] = cycle * 3 + 2;
            b_top[15:8] = cycle * 11 + 9;
            a_valid_left = cycle[1:0] ^ 2'b01;
            b_valid_top = cycle[1:0] ^ 2'b10;
        end
        repeat (4) begin
            @(negedge clk);
            a_left = 16'b0;
            b_top = 16'b0;
            a_valid_left = 2'b0;
            b_valid_top = 2'b0;
        end
        @(posedge clk);
        #0.02;
        if (errors == 0)
            $display("PASS: legal A-east/B-south mesh propagation");
        else
            $fatal(1, "FAIL: %0d mesh propagation mismatches", errors);
        $finish;
    end
endmodule

module tb_b2_refine;
    reg signed [7:0] a, b;
    wire [17:0] r0 [0:3];
    wire [17:0] r1 [0:3];
    wire [17:0] r2 [0:3];
    wire [17:0] r3 [0:3];
    wire [17:0] ps [0:3];
    wire [17:0] pc [0:3];
    reg signed [17:0] expected;
    integer ai, bi, candidate, errors;

    dse_b_m1_rows #(.IMPL(2)) u_c0_m1(.a(a), .b(b),
        .row0(r0[0]), .row1(r1[0]), .row2(r2[0]), .row3(r3[0]));
    dse_b_m2_rows #(.IMPL(2)) u_c0_m2(.row0(r0[0]), .row1(r1[0]),
        .row2(r2[0]), .row3(r3[0]), .product_sum(ps[0]), .product_carry(pc[0]));
    dse_b_m1_rows #(.IMPL(4)) u_c1_m1(.a(a), .b(b),
        .row0(r0[1]), .row1(r1[1]), .row2(r2[1]), .row3(r3[1]));
    dse_b_m2_rows #(.IMPL(4)) u_c1_m2(.row0(r0[1]), .row1(r1[1]),
        .row2(r2[1]), .row3(r3[1]), .product_sum(ps[1]), .product_carry(pc[1]));
    dse_b_m1_rows #(.IMPL(5)) u_c2_m1(.a(a), .b(b),
        .row0(r0[2]), .row1(r1[2]), .row2(r2[2]), .row3(r3[2]));
    dse_b_m2_rows #(.IMPL(5)) u_c2_m2(.row0(r0[2]), .row1(r1[2]),
        .row2(r2[2]), .row3(r3[2]), .product_sum(ps[2]), .product_carry(pc[2]));
    dse_b_m1_rows #(.IMPL(6)) u_c3_m1(.a(a), .b(b),
        .row0(r0[3]), .row1(r1[3]), .row2(r2[3]), .row3(r3[3]));
    dse_b_m2_rows #(.IMPL(6)) u_c3_m2(.row0(r0[3]), .row1(r1[3]),
        .row2(r2[3]), .row3(r3[3]), .product_sum(ps[3]), .product_carry(pc[3]));

    initial begin
        errors = 0;
        a = 0;
        b = 0;
        for (ai = -128; ai <= 127; ai = ai + 1) begin
            for (bi = -128; bi <= 127; bi = bi + 1) begin
                a = ai;
                b = bi;
                expected = ai * bi;
                #1;
                for (candidate = 0; candidate < 4; candidate = candidate + 1) begin
                    if ((ps[candidate] + pc[candidate]) !== expected) begin
                        $error("B2C%0d mismatch: %0d * %0d", candidate, ai, bi);
                        errors = errors + 1;
                    end
                end
            end
        end
        if (errors == 0)
            $display("PASS: B2 C0/C1/C2/C3 exhaustive equivalence");
        else
            $fatal(1, "FAIL: %0d B2 refinement mismatches", errors);
        $finish;
    end
endmodule

module tb_b2_exact;
    reg signed [7:0] a, b;
    wire [17:0] r0 [0:3];
    wire [17:0] r1 [0:3];
    wire [17:0] r2 [0:3];
    wire [17:0] r3 [0:3];
    wire [17:0] ps [0:3];
    wire [17:0] pc [0:3];
    reg signed [15:0] expected;
    integer ai, bi, candidate, errors;

    dse_b_m1_rows #(.IMPL(2)) u_e0_m1(.a(a), .b(b),
        .row0(r0[0]), .row1(r1[0]), .row2(r2[0]), .row3(r3[0]));
    dse_b_m2_rows #(.IMPL(2)) u_e0_m2(.row0(r0[0]), .row1(r1[0]),
        .row2(r2[0]), .row3(r3[0]), .product_sum(ps[0]), .product_carry(pc[0]));
    dse_b_m1_rows #(.IMPL(7)) u_e1_m1(.a(a), .b(b),
        .row0(r0[1]), .row1(r1[1]), .row2(r2[1]), .row3(r3[1]));
    dse_b_m2_rows #(.IMPL(7)) u_e1_m2(.row0(r0[1]), .row1(r1[1]),
        .row2(r2[1]), .row3(r3[1]), .product_sum(ps[1]), .product_carry(pc[1]));
    dse_b_m1_rows #(.IMPL(8)) u_e2_m1(.a(a), .b(b),
        .row0(r0[2]), .row1(r1[2]), .row2(r2[2]), .row3(r3[2]));
    dse_b_m2_rows #(.IMPL(8)) u_e2_m2(.row0(r0[2]), .row1(r1[2]),
        .row2(r2[2]), .row3(r3[2]), .product_sum(ps[2]), .product_carry(pc[2]));
    dse_b_m1_rows #(.IMPL(9)) u_e3_m1(.a(a), .b(b),
        .row0(r0[3]), .row1(r1[3]), .row2(r2[3]), .row3(r3[3]));
    dse_b_m2_rows #(.IMPL(9)) u_e3_m2(.row0(r0[3]), .row1(r1[3]),
        .row2(r2[3]), .row3(r3[3]), .product_sum(ps[3]), .product_carry(pc[3]));

    initial begin
        errors = 0;
        a = 0;
        b = 0;
        for (ai = -128; ai <= 127; ai = ai + 1) begin
            for (bi = -128; bi <= 127; bi = bi + 1) begin
                a = ai;
                b = bi;
                expected = ai * bi;
                #1;
                for (candidate = 0; candidate < 4; candidate = candidate + 1) begin
                    if ((ps[candidate][15:0] + pc[candidate][15:0]) !== expected) begin
                        $error("B2E%0d mismatch: %0d * %0d got %h expected %h",
                            candidate, ai, bi,
                            ps[candidate][15:0] + pc[candidate][15:0], expected);
                        errors = errors + 1;
                    end
                    if ((candidate != 0) &&
                        ((ps[candidate][17:16] !== 2'b0) ||
                         (pc[candidate][17:16] !== 2'b0))) begin
                        $error("B2E%0d leaked state above exact bit 15", candidate);
                        errors = errors + 1;
                    end
                end
            end
        end
        if (errors == 0)
            $display("PASS: B2 E0/E1/E2/E3 exhaustive exact-16 equivalence");
        else
            $fatal(1, "FAIL: %0d exact-width mismatches", errors);
        $finish;
    end
endmodule

`default_nettype wire
