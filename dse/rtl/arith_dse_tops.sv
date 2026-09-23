`default_nettype none
`timescale 1ns/1ps

// IMPL: 0=inferred signed multiply, 1=Baugh-Wooley, 2=current radix-4 Booth.
module dse_int4_mul_top #(
    parameter integer IMPL = 0
) (
    input  wire              clk,
    input  wire              reset,
    input  wire signed [3:0] a,
    input  wire signed [3:0] b,
    input  wire              valid_in,
    output wire signed [7:0] product,
    output wire              valid_out
);
    reg signed [3:0] a_m0, b_m0;
    reg [7:0] sum_m1, carry_m1;
    reg signed [7:0] product_m2;
    reg valid_m0, valid_m1, valid_m2;
    wire [7:0] next_sum, next_carry;
    wire [8:0] final_product = {1'b0, sum_m1} + {1'b0, carry_m1};

    generate
        if (IMPL == 0) begin : inferred
            dse_int4_inferred_rows u_mul(.a(a_m0), .b(b_m0),
                .product_sum(next_sum), .product_carry_shifted(next_carry));
        end else if (IMPL == 1) begin : baugh_wooley
            dse_int4_baugh_wooley_rows u_mul(.a(a_m0), .b(b_m0),
                .product_sum(next_sum), .product_carry_shifted(next_carry));
        end else if (IMPL == 2) begin : booth
            dse_int4_booth_rows u_mul(.a(a_m0), .b(b_m0),
                .product_sum(next_sum), .product_carry_shifted(next_carry));
        end else begin : invalid_impl
            assign next_sum = 8'hxx;
            assign next_carry = 8'hxx;
            initial $error("dse_int4_mul_top IMPL must be 0..2");
        end
    endgenerate

    always_ff @(posedge clk) begin
        a_m0 <= a;
        b_m0 <= b;
        sum_m1 <= next_sum;
        carry_m1 <= next_carry;
        product_m2 <= final_product[7:0];
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            valid_m0 <= 1'b0;
            valid_m1 <= 1'b0;
            valid_m2 <= 1'b0;
        end else begin
            valid_m0 <= valid_in;
            valid_m1 <= valid_m0;
            valid_m2 <= valid_m1;
        end
    end

    assign product = product_m2;
    assign valid_out = valid_m2;
endmodule

// IMPL: 0=inferred signed multiply, 1=strict two-row radix-4 Booth.
// CPA_IMPL: 0=inferred, 1=4-bit carry-select, 2=Brent-Kung, 3=Han-Carlson.
module dse_int8_mul_top #(
    parameter integer IMPL     = 0,
    parameter integer CPA_IMPL = 0
) (
    input  wire               clk,
    input  wire               reset,
    input  wire signed [7:0]  a,
    input  wire signed [7:0]  b,
    input  wire               valid_in,
    output wire signed [15:0] product,
    output wire               valid_out
);
    reg signed [7:0] a_m0, b_m0;
    reg [17:0] sum_m1, carry_m1;
    reg signed [15:0] product_m2;
    reg valid_m0, valid_m1, valid_m2;
    wire [17:0] next_sum, next_carry;
    wire [15:0] final_product;
    wire final_cout;

    generate
        if (IMPL == 0) begin : inferred
            dse_int8_inferred_rows u_mul(.a(a_m0), .b(b_m0),
                .product_sum(next_sum), .product_carry_shifted(next_carry));
        end else if (IMPL == 1) begin : booth_two_row
            dse_int8_booth_two_row u_mul(.a(a_m0), .b(b_m0),
                .product_sum(next_sum), .product_carry_shifted(next_carry));
        end else begin : invalid_impl
            assign next_sum = {18{1'bx}};
            assign next_carry = {18{1'bx}};
            initial $error("dse_int8_mul_top IMPL must be 0 or 1");
        end
    endgenerate

    dse_adder_select #(.W(16), .SEG(4), .IMPL(CPA_IMPL)) u_final_cpa (
        .a(sum_m1[15:0]), .b(carry_m1[15:0]), .cin(1'b0),
        .sum(final_product), .cout(final_cout));

    always_ff @(posedge clk) begin
        a_m0 <= a;
        b_m0 <= b;
        sum_m1 <= next_sum;
        carry_m1 <= next_carry;
        product_m2 <= final_product;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            valid_m0 <= 1'b0;
            valid_m1 <= 1'b0;
            valid_m2 <= 1'b0;
        end else begin
            valid_m0 <= valid_in;
            valid_m1 <= valid_m0;
            valid_m2 <= valid_m1;
        end
    end

    assign product = product_m2;
    assign valid_out = valid_m2;
endmodule

// Isolated registered 16-bit CPA experiment.
module dse_cpa16_top #(
    parameter integer IMPL = 0
) (
    input  wire        clk,
    input  wire [15:0] a,
    input  wire [15:0] b,
    input  wire        cin,
    output wire [15:0] sum,
    output wire        cout
);
    reg [15:0] a_reg, b_reg;
    reg cin_reg;
    reg [15:0] sum_reg;
    reg cout_reg;
    wire [15:0] sum_next;
    wire cout_next;

    dse_adder_select #(.W(16), .SEG(4), .IMPL(IMPL)) u_adder(
        .a(a_reg), .b(b_reg), .cin(cin_reg), .sum(sum_next), .cout(cout_next));

    always_ff @(posedge clk) begin
        a_reg <= a;
        b_reg <= b;
        cin_reg <= cin;
        sum_reg <= sum_next;
        cout_reg <= cout_next;
    end
    assign sum = sum_reg;
    assign cout = cout_reg;
endmodule

// Isolated accumulator recurrence.  first is moved to the A input of the CPA;
// valid remains a register enable, so neither control is a mux after the CPA.
// IMPL: 0=inferred, 1=4x8 carry-select, 2=Brent-Kung, 3=Han-Carlson.
module dse_acc32_top #(
    parameter integer IMPL = 0
) (
    input  wire               clk,
    input  wire               reset,
    input  wire signed [15:0] delta_in,
    input  wire               valid_in,
    input  wire               first_in,
    output wire signed [31:0] accumulator
);
    reg signed [15:0] delta_reg;
    reg valid_reg, first_reg;
    reg signed [31:0] acc_reg;
    wire [31:0] delta_extended = {{16{delta_reg[15]}}, delta_reg};
    wire [31:0] accumulator_operand = first_reg ? 32'b0 : acc_reg;
    wire [31:0] acc_next;
    wire acc_cout;

    dse_adder_select #(.W(32), .SEG(8), .IMPL(IMPL)) u_accumulator_cpa(
        .a(accumulator_operand), .b(delta_extended), .cin(1'b0),
        .sum(acc_next), .cout(acc_cout));

    always_ff @(posedge clk) begin
        delta_reg <= delta_in;
        if (valid_reg)
            acc_reg <= acc_next;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            valid_reg <= 1'b0;
            first_reg <= 1'b0;
        end else begin
            valid_reg <= valid_in;
            first_reg <= first_in;
        end
    end
    assign accumulator = acc_reg;
endmodule

// Lean fused-CSA accumulator.  The recurrence stores two carry-save rows, so
// every ordinary accumulation cycle contains only one 3:2 compressor.  A
// final CPA runs once, in the cycle after a valid last token.  Data state is
// intentionally not reset; reset only invalidates pending/output control.
module dse_acc32_fused_core (
    input  wire               clk,
    input  wire               reset,
    input  wire signed [15:0] delta,
    input  wire               valid,
    input  wire               first,
    input  wire               last,
    output wire signed [31:0] accumulator,
    output wire               done
);
    wire [31:0] delta_extended = {{16{delta[15]}}, delta};
    reg [31:0] sum_state;
    reg [31:0] carry_state;
    wire [31:0] accumulated_sum;
    wire [31:0] accumulated_carry;
    wire [31:0] state_sum_next = first ?
        delta_extended : accumulated_sum;
    wire [31:0] state_carry_next = first ?
        32'b0 : accumulated_carry;

    reg finalize_pending;
    reg signed [31:0] result_reg;
    reg done_reg;
    wire [31:0] final_sum;
    wire final_cout;

    dse_csa3 #(.W(32)) u_recurrence_csa(
        .x(sum_state), .y(carry_state), .z(delta_extended),
        .sum(accumulated_sum), .carry_shifted(accumulated_carry));

    // The inferred CPA is kept out of the recurrence and is paid only once
    // per output tile.  Its result is captured one cycle after last_reg.
    dse_inferred_adder #(.W(32)) u_final_cpa(
        .a(sum_state), .b(carry_state), .cin(1'b0),
        .sum(final_sum), .cout(final_cout));

    always_ff @(posedge clk) begin
        if (valid) begin
            sum_state <= state_sum_next;
            carry_state <= state_carry_next;
        end
        if (finalize_pending)
            result_reg <= final_sum;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            finalize_pending <= 1'b0;
            done_reg <= 1'b0;
        end else begin
            finalize_pending <= valid && last;
            done_reg <= finalize_pending;
        end
    end

    assign accumulator = result_reg;
    assign done = done_reg;
endmodule

// Registered standalone wrapper gives the isolated experiment the same
// launch boundary as the conventional dse_acc32_top.
module dse_acc32_fused_top (
    input  wire               clk,
    input  wire               reset,
    input  wire signed [15:0] delta_in,
    input  wire               valid_in,
    input  wire               first_in,
    input  wire               last_in,
    output wire signed [31:0] accumulator,
    output wire               done
);
    reg signed [15:0] delta_reg;
    reg valid_reg, first_reg, last_reg;

    always_ff @(posedge clk) begin
        delta_reg <= delta_in;
        if (reset) begin
            valid_reg <= 1'b0;
            first_reg <= 1'b0;
            last_reg <= 1'b0;
        end else begin
            valid_reg <= valid_in;
            first_reg <= first_in;
            last_reg <= last_in;
        end
    end

    dse_acc32_fused_core u_core(
        .clk(clk), .reset(reset), .delta(delta_reg), .valid(valid_reg),
        .first(first_reg), .last(last_reg),
        .accumulator(accumulator), .done(done));
endmodule

// Arithmetic-only PE candidate used after the four isolated sweeps.  It keeps
// the production M0/M1/M2/D/A timing boundaries without systolic forwarding.
module dse_pe_candidate #(
    parameter integer INT4_IMPL = 0,
    parameter integer INT8_IMPL = 0,
    parameter integer CPA16_IMPL = 0,
    parameter integer ACC32_IMPL = 0
) (
    input  wire               clk,
    input  wire               reset,
    input  wire               precision_mode,
    input  wire [7:0]         activation,
    input  wire [7:0]         weight,
    input  wire [1:0]         valid_in,
    input  wire               first_in,
    input  wire               last_in,
    output wire signed [31:0] accumulator,
    output wire               done
);
    reg [7:0] m0_activation, m0_weight;
    reg m0_mode;
    reg [1:0] m0_valid;
    reg m0_first, m0_last;

    wire [17:0] int8_sum_next, int8_carry_next;
    wire [7:0] int4_lo_sum_next, int4_lo_carry_next;
    wire [7:0] int4_hi_sum_next, int4_hi_carry_next;
    reg [17:0] m1_int8_sum, m1_int8_carry;
    reg [7:0] m1_int4_lo_sum, m1_int4_lo_carry;
    reg [7:0] m1_int4_hi_sum, m1_int4_hi_carry;
    reg m1_mode;
    reg [1:0] m1_valid;
    reg m1_first, m1_last;

    wire [15:0] int8_product_next;
    wire int8_product_cout;
    wire [7:0] int4_product0_next =
        m1_int4_lo_sum + m1_int4_lo_carry;
    wire [7:0] int4_product1_next =
        m1_int4_hi_sum + m1_int4_hi_carry;
    reg signed [15:0] m2_product8;
    reg signed [7:0] m2_product4_0, m2_product4_1;
    reg m2_mode;
    reg [1:0] m2_valid;
    reg m2_first, m2_last;

    wire signed [8:0] lane0 = m2_valid[0] ?
        {m2_product4_0[7], m2_product4_0} : 9'sd0;
    wire signed [8:0] lane1 = m2_valid[1] ?
        {m2_product4_1[7], m2_product4_1} : 9'sd0;
    wire signed [8:0] int4_delta = lane0 + lane1;
    reg signed [15:0] delta_reg;
    reg delta_valid, delta_first, delta_last;
    wire [31:0] delta_extended = {{16{delta_reg[15]}}, delta_reg};
    reg signed [31:0] acc_reg;
    reg done_reg;
    wire signed [31:0] conventional_accumulator;
    wire signed [31:0] fused_accumulator;
    wire fused_done;

    generate
        if (INT8_IMPL == 0) begin : int8_inferred
            dse_int8_inferred_rows u_int8(.a(m0_activation), .b(m0_weight),
                .product_sum(int8_sum_next),
                .product_carry_shifted(int8_carry_next));
        end else begin : int8_booth
            dse_int8_booth_two_row u_int8(.a(m0_activation), .b(m0_weight),
                .product_sum(int8_sum_next),
                .product_carry_shifted(int8_carry_next));
        end

        if (INT4_IMPL == 0) begin : int4_inferred
            dse_int4_inferred_rows u_lo(.a(m0_activation[3:0]), .b(m0_weight[3:0]),
                .product_sum(int4_lo_sum_next),
                .product_carry_shifted(int4_lo_carry_next));
            dse_int4_inferred_rows u_hi(.a(m0_activation[7:4]), .b(m0_weight[7:4]),
                .product_sum(int4_hi_sum_next),
                .product_carry_shifted(int4_hi_carry_next));
        end else if (INT4_IMPL == 1) begin : int4_baugh_wooley
            dse_int4_baugh_wooley_rows u_lo(.a(m0_activation[3:0]), .b(m0_weight[3:0]),
                .product_sum(int4_lo_sum_next),
                .product_carry_shifted(int4_lo_carry_next));
            dse_int4_baugh_wooley_rows u_hi(.a(m0_activation[7:4]), .b(m0_weight[7:4]),
                .product_sum(int4_hi_sum_next),
                .product_carry_shifted(int4_hi_carry_next));
        end else begin : int4_booth
            dse_int4_booth_rows u_lo(.a(m0_activation[3:0]), .b(m0_weight[3:0]),
                .product_sum(int4_lo_sum_next),
                .product_carry_shifted(int4_lo_carry_next));
            dse_int4_booth_rows u_hi(.a(m0_activation[7:4]), .b(m0_weight[7:4]),
                .product_sum(int4_hi_sum_next),
                .product_carry_shifted(int4_hi_carry_next));
        end
    endgenerate

    dse_adder_select #(.W(16), .SEG(4), .IMPL(CPA16_IMPL)) u_product_cpa(
        .a(m1_int8_sum[15:0]), .b(m1_int8_carry[15:0]), .cin(1'b0),
        .sum(int8_product_next), .cout(int8_product_cout));
    generate
        if (ACC32_IMPL < 4) begin : conventional_accumulator_impl
            wire [31:0] accumulator_operand = delta_first ? 32'b0 : acc_reg;
            wire [31:0] acc_next;
            wire acc_cout;

            dse_adder_select #(.W(32), .SEG(8), .IMPL(ACC32_IMPL))
                u_accumulator_cpa(
                    .a(accumulator_operand), .b(delta_extended), .cin(1'b0),
                    .sum(acc_next), .cout(acc_cout));

            always_ff @(posedge clk) begin
                if (delta_valid)
                    acc_reg <= acc_next;
            end

            assign conventional_accumulator = acc_reg;
            assign fused_accumulator = 32'sd0;
            assign fused_done = 1'b0;
        end else if (ACC32_IMPL == 4) begin : fused_csa_accumulator_impl
            dse_acc32_fused_core u_accumulator(
                .clk(clk), .reset(reset), .delta(delta_reg),
                .valid(delta_valid), .first(delta_first),
                .last(delta_last), .accumulator(fused_accumulator),
                .done(fused_done));

            assign conventional_accumulator = 32'sd0;
        end else begin : invalid_accumulator_impl
            assign conventional_accumulator = {32{1'bx}};
            assign fused_accumulator = {32{1'bx}};
            assign fused_done = 1'bx;
            initial $error("dse_pe_candidate ACC32_IMPL must be 0..4");
        end
    endgenerate

    always_ff @(posedge clk) begin
        m0_activation <= activation;
        m0_weight <= weight;
        m0_mode <= precision_mode;

        m1_int8_sum <= int8_sum_next;
        m1_int8_carry <= int8_carry_next;
        m1_int4_lo_sum <= int4_lo_sum_next;
        m1_int4_lo_carry <= int4_lo_carry_next;
        m1_int4_hi_sum <= int4_hi_sum_next;
        m1_int4_hi_carry <= int4_hi_carry_next;
        m1_mode <= m0_mode;

        m2_product8 <= int8_product_next;
        m2_product4_0 <= int4_product0_next;
        m2_product4_1 <= int4_product1_next;
        m2_mode <= m1_mode;

        if (m2_mode)
            delta_reg <= {{7{int4_delta[8]}}, int4_delta};
        else
            delta_reg <= m2_valid[0] ? m2_product8 : 16'sd0;

    end

    always_ff @(posedge clk) begin
        if (reset) begin
            m0_valid <= 2'b0;
            m0_first <= 1'b0;
            m0_last <= 1'b0;
            m1_valid <= 2'b0;
            m1_first <= 1'b0;
            m1_last <= 1'b0;
            m2_valid <= 2'b0;
            m2_first <= 1'b0;
            m2_last <= 1'b0;
            delta_valid <= 1'b0;
            delta_first <= 1'b0;
            delta_last <= 1'b0;
            done_reg <= 1'b0;
        end else begin
            m0_valid <= valid_in;
            m0_first <= first_in;
            m0_last <= last_in;
            m1_valid <= m0_valid;
            m1_first <= m0_first;
            m1_last <= m0_last;
            m2_valid <= m1_valid;
            m2_first <= m1_first;
            m2_last <= m1_last;
            delta_valid <= m2_mode ? (m2_valid[0] | m2_valid[1]) : m2_valid[0];
            delta_first <= m2_first;
            delta_last <= m2_last;
            done_reg <= delta_last;
        end
    end

    assign accumulator = (ACC32_IMPL == 4) ?
        fused_accumulator : conventional_accumulator;
    assign done = (ACC32_IMPL == 4) ? fused_done : done_reg;
endmodule

module dse_pe_single_top #(
    parameter integer INT4_IMPL = 0,
    parameter integer INT8_IMPL = 0,
    parameter integer CPA16_IMPL = 0,
    parameter integer ACC32_IMPL = 0
) (
    input  wire               clk,
    input  wire               reset,
    input  wire               precision_mode,
    input  wire [7:0]         activation,
    input  wire [7:0]         weight,
    input  wire [1:0]         valid_in,
    input  wire               first_in,
    input  wire               last_in,
    output wire signed [31:0] accumulator,
    output wire               done
);
    dse_pe_candidate #(
        .INT4_IMPL(INT4_IMPL), .INT8_IMPL(INT8_IMPL),
        .CPA16_IMPL(CPA16_IMPL), .ACC32_IMPL(ACC32_IMPL)
    ) u_pe(.*);
endmodule

// Four replicated candidates expose local arithmetic loading and optimizer
// behavior before paying the cost of a 256-PE full-array synthesis.
module dse_pe_array2x2_top #(
    parameter integer INT4_IMPL = 0,
    parameter integer INT8_IMPL = 0,
    parameter integer CPA16_IMPL = 0,
    parameter integer ACC32_IMPL = 0
) (
    input  wire               clk,
    input  wire               reset,
    input  wire               precision_mode,
    input  wire [7:0]         activation0,
    input  wire [7:0]         activation1,
    input  wire [7:0]         weight0,
    input  wire [7:0]         weight1,
    input  wire [1:0]         valid_in,
    input  wire               first_in,
    input  wire               last_in,
    output wire signed [31:0] accumulator00,
    output wire signed [31:0] accumulator01,
    output wire signed [31:0] accumulator10,
    output wire signed [31:0] accumulator11,
    output wire [3:0]         done
);
    dse_pe_candidate #(.INT4_IMPL(INT4_IMPL), .INT8_IMPL(INT8_IMPL),
        .CPA16_IMPL(CPA16_IMPL), .ACC32_IMPL(ACC32_IMPL)) u_pe00(
        .clk(clk), .reset(reset), .precision_mode(precision_mode),
        .activation(activation0), .weight(weight0), .valid_in(valid_in),
        .first_in(first_in), .last_in(last_in),
        .accumulator(accumulator00), .done(done[0]));
    dse_pe_candidate #(.INT4_IMPL(INT4_IMPL), .INT8_IMPL(INT8_IMPL),
        .CPA16_IMPL(CPA16_IMPL), .ACC32_IMPL(ACC32_IMPL)) u_pe01(
        .clk(clk), .reset(reset), .precision_mode(precision_mode),
        .activation(activation0), .weight(weight1), .valid_in(valid_in),
        .first_in(first_in), .last_in(last_in),
        .accumulator(accumulator01), .done(done[1]));
    dse_pe_candidate #(.INT4_IMPL(INT4_IMPL), .INT8_IMPL(INT8_IMPL),
        .CPA16_IMPL(CPA16_IMPL), .ACC32_IMPL(ACC32_IMPL)) u_pe10(
        .clk(clk), .reset(reset), .precision_mode(precision_mode),
        .activation(activation1), .weight(weight0), .valid_in(valid_in),
        .first_in(first_in), .last_in(last_in),
        .accumulator(accumulator10), .done(done[2]));
    dse_pe_candidate #(.INT4_IMPL(INT4_IMPL), .INT8_IMPL(INT8_IMPL),
        .CPA16_IMPL(CPA16_IMPL), .ACC32_IMPL(ACC32_IMPL)) u_pe11(
        .clk(clk), .reset(reset), .precision_mode(precision_mode),
        .activation(activation1), .weight(weight1), .valid_in(valid_in),
        .first_in(first_in), .last_in(last_in),
        .accumulator(accumulator11), .done(done[3]));
endmodule

`default_nettype wire
