`default_nettype none
`timescale 1ns/1ps

// First half of the pipelined INT8 radix-4 Booth tree.  M1a registers these
// three rows; the final 3:2 compression is deliberately a separate stage.
module dse_int8_booth_first_compress (
    input  wire signed [7:0]  a,
    input  wire signed [7:0]  b,
    output wire        [17:0] first_sum,
    output wire        [17:0] first_carry_shifted,
    output wire        [17:0] tail
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
    assign tail = booth_term(b, a[7:5], 3'd6);

    dse_csa3 #(.W(18)) u_first_compressor(
        .x(pp0), .y(pp1), .z(pp2),
        .sum(first_sum), .carry_shifted(first_carry_shifted));
endmodule

// PE-local output-stationary state.  No carry-propagate adder and no final
// result register are instantiated here.  state_done is asserted only after
// the last delta has entered the two state rows.
module dse_acc32_csa_state_core (
    input  wire               clk,
    input  wire               reset,
    input  wire signed [15:0] delta,
    input  wire               valid,
    input  wire               first,
    input  wire               last,
    output wire        [31:0] sum_state_out,
    output wire        [31:0] carry_state_out,
    output wire               state_done
);
    reg [31:0] sum_state;
    reg [31:0] carry_state;
    reg done_reg;
    wire [31:0] delta_extended = {{16{delta[15]}}, delta};
    wire [31:0] accumulated_sum;
    wire [31:0] accumulated_carry;

    dse_csa3 #(.W(32)) u_recurrence_csa(
        .x(sum_state), .y(carry_state), .z(delta_extended),
        .sum(accumulated_sum), .carry_shifted(accumulated_carry));

    always_ff @(posedge clk) begin
        if (valid) begin
            if (first) begin
                sum_state <= delta_extended;
                carry_state <= 32'b0;
            end else begin
                sum_state <= accumulated_sum;
                carry_state <= accumulated_carry;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (reset)
            done_reg <= 1'b0;
        else
            done_reg <= valid && last;
    end

    assign sum_state_out = sum_state;
    assign carry_state_out = carry_state;
    assign state_done = done_reg;
endmodule

// Registered wrapper for an isolated recurrence timing/area experiment.
module dse_acc32_csa_state_top (
    input  wire               clk,
    input  wire               reset,
    input  wire signed [15:0] delta_in,
    input  wire               valid_in,
    input  wire               first_in,
    input  wire               last_in,
    output wire        [31:0] sum_state,
    output wire        [31:0] carry_state,
    output wire               state_done
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

    dse_acc32_csa_state_core u_state(
        .clk(clk), .reset(reset), .delta(delta_reg), .valid(valid_reg),
        .first(first_reg), .last(last_reg),
        .sum_state_out(sum_state), .carry_state_out(carry_state),
        .state_done(state_done));
endmodule

// A row-shared finalizer.  Sixteen instances are sufficient for a 16-column
// array because capture already advances by one PE row per cycle.  F0 adds
// bits 15:0 and registers upper operands/carry; F1 adds bits 31:16.  The
// pipeline accepts a new result row every cycle.
module dse_result_row_finalizer_top #(
    parameter integer LANES = 16,
    parameter integer CPA_IMPL = 1
) (
    input  wire                       clk,
    input  wire                       reset,
    input  wire [LANES*32-1:0]        capture_sum,
    input  wire [LANES*32-1:0]        capture_carry,
    input  wire                       capture_valid,
    input  wire [3:0]                 capture_row,
    output wire [LANES*32-1:0]        result_data,
    output wire                       result_valid,
    output wire [3:0]                 result_row
);
    reg stage0_valid, result_valid_reg;
    reg [3:0] stage0_row, result_row_reg;

    always_ff @(posedge clk) begin
        if (reset) begin
            stage0_valid <= 1'b0;
            result_valid_reg <= 1'b0;
            stage0_row <= 4'b0;
            result_row_reg <= 4'b0;
        end else begin
            stage0_valid <= capture_valid;
            result_valid_reg <= stage0_valid;
            stage0_row <= capture_row;
            result_row_reg <= stage0_row;
        end
    end

    generate
        genvar lane;
        for (lane = 0; lane < LANES; lane = lane + 1) begin : lanes
            wire [31:0] lane_sum = capture_sum[lane*32 +: 32];
            wire [31:0] lane_carry = capture_carry[lane*32 +: 32];
            wire [15:0] low_sum_next;
            wire low_carry_next;
            reg [15:0] low_sum_reg;
            reg [15:0] upper_sum_reg;
            reg [15:0] upper_carry_reg;
            reg low_carry_reg;
            wire [15:0] high_sum_next;
            wire high_carry_unused;
            reg [31:0] result_reg;

            dse_adder_select #(.W(16), .SEG(4), .IMPL(CPA_IMPL)) u_low_cpa(
                .a(lane_sum[15:0]), .b(lane_carry[15:0]), .cin(1'b0),
                .sum(low_sum_next), .cout(low_carry_next));
            dse_adder_select #(.W(16), .SEG(4), .IMPL(CPA_IMPL)) u_high_cpa(
                .a(upper_sum_reg), .b(upper_carry_reg),
                .cin(low_carry_reg), .sum(high_sum_next),
                .cout(high_carry_unused));

            always_ff @(posedge clk) begin
                low_sum_reg <= low_sum_next;
                upper_sum_reg <= lane_sum[31:16];
                upper_carry_reg <= lane_carry[31:16];
                low_carry_reg <= low_carry_next;
                if (stage0_valid)
                    result_reg <= {high_sum_next, low_sum_reg};
            end

            assign result_data[lane*32 +: 32] = result_reg;
        end
    endgenerate

    assign result_valid = result_valid_reg;
    assign result_row = result_row_reg;
endmodule

// Selected arithmetic PE with one extra INT8 compression stage and external
// carry-save result state.  INT4 is delayed through M1b to preserve the common
// M2/D/state latency contract.
module dse_pe_state_candidate (
    input  wire               clk,
    input  wire               reset,
    input  wire               precision_mode,
    input  wire [7:0]         activation,
    input  wire [7:0]         weight,
    input  wire [1:0]         valid_in,
    input  wire               first_in,
    input  wire               last_in,
    output wire        [31:0] sum_state,
    output wire        [31:0] carry_state,
    output wire               state_done
);
    reg [7:0] m0_activation, m0_weight;
    reg m0_mode;
    reg [1:0] m0_valid;
    reg m0_first, m0_last;

    wire [17:0] int8_l1_sum_next, int8_l1_carry_next, int8_tail_next;
    wire [7:0] int4_lo_sum_next, int4_lo_carry_next;
    wire [7:0] int4_hi_sum_next, int4_hi_carry_next;
    reg [17:0] m1a_int8_sum, m1a_int8_carry, m1a_int8_tail;
    reg [7:0] m1a_int4_lo_sum, m1a_int4_lo_carry;
    reg [7:0] m1a_int4_hi_sum, m1a_int4_hi_carry;
    reg m1a_mode;
    reg [1:0] m1a_valid;
    reg m1a_first, m1a_last;

    wire [17:0] int8_final_sum_next, int8_final_carry_next;
    reg [17:0] m1b_int8_sum, m1b_int8_carry;
    reg [7:0] m1b_int4_lo_sum, m1b_int4_lo_carry;
    reg [7:0] m1b_int4_hi_sum, m1b_int4_hi_carry;
    reg m1b_mode;
    reg [1:0] m1b_valid;
    reg m1b_first, m1b_last;

    wire [15:0] int8_product_next;
    wire int8_product_cout;
    wire [7:0] int4_product0_next =
        m1b_int4_lo_sum + m1b_int4_lo_carry;
    wire [7:0] int4_product1_next =
        m1b_int4_hi_sum + m1b_int4_hi_carry;
    reg signed [15:0] m2_product8;
    reg signed [7:0] m2_product4_0, m2_product4_1;
    reg m2_mode;
    reg [1:0] m2_valid;
    reg m2_first, m2_last;

    wire signed [8:0] int4_lane0 = m2_valid[0] ?
        {m2_product4_0[7], m2_product4_0} : 9'sd0;
    wire signed [8:0] int4_lane1 = m2_valid[1] ?
        {m2_product4_1[7], m2_product4_1} : 9'sd0;
    wire signed [8:0] int4_delta = int4_lane0 + int4_lane1;
    reg signed [15:0] delta_reg;
    reg delta_valid, delta_first, delta_last;

    dse_int8_booth_first_compress u_int8_first(
        .a(m0_activation), .b(m0_weight),
        .first_sum(int8_l1_sum_next),
        .first_carry_shifted(int8_l1_carry_next),
        .tail(int8_tail_next));
    dse_csa3 #(.W(18)) u_int8_final_compressor(
        .x(m1a_int8_sum), .y(m1a_int8_carry), .z(m1a_int8_tail),
        .sum(int8_final_sum_next),
        .carry_shifted(int8_final_carry_next));

    dse_int4_booth_rows u_int4_lo(
        .a(m0_activation[3:0]), .b(m0_weight[3:0]),
        .product_sum(int4_lo_sum_next),
        .product_carry_shifted(int4_lo_carry_next));
    dse_int4_booth_rows u_int4_hi(
        .a(m0_activation[7:4]), .b(m0_weight[7:4]),
        .product_sum(int4_hi_sum_next),
        .product_carry_shifted(int4_hi_carry_next));

    dse_adder_select #(.W(16), .SEG(4), .IMPL(1)) u_product_cpa(
        .a(m1b_int8_sum[15:0]), .b(m1b_int8_carry[15:0]),
        .cin(1'b0), .sum(int8_product_next), .cout(int8_product_cout));

    dse_acc32_csa_state_core u_accumulator_state(
        .clk(clk), .reset(reset), .delta(delta_reg), .valid(delta_valid),
        .first(delta_first), .last(delta_last),
        .sum_state_out(sum_state), .carry_state_out(carry_state),
        .state_done(state_done));

    always_ff @(posedge clk) begin
        m0_activation <= activation;
        m0_weight <= weight;
        m0_mode <= precision_mode;

        m1a_int8_sum <= int8_l1_sum_next;
        m1a_int8_carry <= int8_l1_carry_next;
        m1a_int8_tail <= int8_tail_next;
        m1a_int4_lo_sum <= int4_lo_sum_next;
        m1a_int4_lo_carry <= int4_lo_carry_next;
        m1a_int4_hi_sum <= int4_hi_sum_next;
        m1a_int4_hi_carry <= int4_hi_carry_next;
        m1a_mode <= m0_mode;

        m1b_int8_sum <= int8_final_sum_next;
        m1b_int8_carry <= int8_final_carry_next;
        m1b_int4_lo_sum <= m1a_int4_lo_sum;
        m1b_int4_lo_carry <= m1a_int4_lo_carry;
        m1b_int4_hi_sum <= m1a_int4_hi_sum;
        m1b_int4_hi_carry <= m1a_int4_hi_carry;
        m1b_mode <= m1a_mode;

        m2_product8 <= int8_product_next;
        m2_product4_0 <= int4_product0_next;
        m2_product4_1 <= int4_product1_next;
        m2_mode <= m1b_mode;

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
            m1a_valid <= 2'b0;
            m1a_first <= 1'b0;
            m1a_last <= 1'b0;
            m1b_valid <= 2'b0;
            m1b_first <= 1'b0;
            m1b_last <= 1'b0;
            m2_valid <= 2'b0;
            m2_first <= 1'b0;
            m2_last <= 1'b0;
            delta_valid <= 1'b0;
            delta_first <= 1'b0;
            delta_last <= 1'b0;
        end else begin
            m0_valid <= valid_in;
            m0_first <= first_in;
            m0_last <= last_in;
            m1a_valid <= m0_valid;
            m1a_first <= m0_first;
            m1a_last <= m0_last;
            m1b_valid <= m1a_valid;
            m1b_first <= m1a_first;
            m1b_last <= m1a_last;
            m2_valid <= m1b_valid;
            m2_first <= m1b_first;
            m2_last <= m1b_last;
            delta_valid <= m2_mode ? (m2_valid[0] | m2_valid[1]) :
                m2_valid[0];
            delta_first <= m2_first;
            delta_last <= m2_last;
        end
    end
endmodule

// Mux-light PE experiment.  Precision is decoded once at the array boundary;
// only mutually-exclusive local work tokens enter the PE.  This removes the
// job-wide mode signal from the arithmetic pipeline and collapses the old
// mode-select plus INT8-valid-select at D into one one-hot data merge.
module dse_pe_local_token_candidate (
    input  wire               clk,
    input  wire               reset,
    input  wire               int8_token_in,
    input  wire [1:0]         int4_token_in,
    input  wire [7:0]         activation,
    input  wire [7:0]         weight,
    input  wire               first_in,
    input  wire               last_in,
    output wire        [31:0] sum_state,
    output wire        [31:0] carry_state,
    output wire               state_done
);
    reg [7:0] m0_activation, m0_weight;
    reg m0_int8_token;
    reg [1:0] m0_int4_token;
    reg m0_first, m0_last;

    wire [17:0] int8_l1_sum_next, int8_l1_carry_next, int8_tail_next;
    wire [7:0] int4_lo_sum_next, int4_lo_carry_next;
    wire [7:0] int4_hi_sum_next, int4_hi_carry_next;
    reg [17:0] m1a_int8_sum, m1a_int8_carry, m1a_int8_tail;
    reg [7:0] m1a_int4_lo_sum, m1a_int4_lo_carry;
    reg [7:0] m1a_int4_hi_sum, m1a_int4_hi_carry;
    reg m1a_int8_token;
    reg [1:0] m1a_int4_token;
    reg m1a_first, m1a_last;

    wire [17:0] int8_final_sum_next, int8_final_carry_next;
    reg [17:0] m1b_int8_sum, m1b_int8_carry;
    reg [7:0] m1b_int4_lo_sum, m1b_int4_lo_carry;
    reg [7:0] m1b_int4_hi_sum, m1b_int4_hi_carry;
    reg m1b_int8_token;
    reg [1:0] m1b_int4_token;
    reg m1b_first, m1b_last;

    wire [15:0] int8_product_next;
    wire int8_product_cout;
    wire [7:0] int4_product0_next =
        m1b_int4_lo_sum + m1b_int4_lo_carry;
    wire [7:0] int4_product1_next =
        m1b_int4_hi_sum + m1b_int4_hi_carry;
    reg signed [15:0] m2_product8;
    reg signed [7:0] m2_product4_0, m2_product4_1;
    reg m2_int8_token;
    reg [1:0] m2_int4_token;
    reg m2_first, m2_last;

    wire signed [8:0] int4_lane0 = m2_int4_token[0] ?
        {m2_product4_0[7], m2_product4_0} : 9'sd0;
    wire signed [8:0] int4_lane1 = m2_int4_token[1] ?
        {m2_product4_1[7], m2_product4_1} : 9'sd0;
    wire signed [8:0] int4_delta = int4_lane0 + int4_lane1;
    wire m2_int4_any = |m2_int4_token;
    wire [15:0] int4_delta_extended = {{7{int4_delta[8]}}, int4_delta};
    wire [15:0] delta_onehot =
        ({16{m2_int8_token}} & m2_product8) |
        ({16{m2_int4_any}} & int4_delta_extended);
    reg signed [15:0] delta_reg;
    reg delta_valid, delta_first, delta_last;

    dse_int8_booth_first_compress u_int8_first(
        .a(m0_activation), .b(m0_weight),
        .first_sum(int8_l1_sum_next),
        .first_carry_shifted(int8_l1_carry_next),
        .tail(int8_tail_next));
    dse_csa3 #(.W(18)) u_int8_final_compressor(
        .x(m1a_int8_sum), .y(m1a_int8_carry), .z(m1a_int8_tail),
        .sum(int8_final_sum_next),
        .carry_shifted(int8_final_carry_next));

    dse_int4_booth_rows u_int4_lo(
        .a(m0_activation[3:0]), .b(m0_weight[3:0]),
        .product_sum(int4_lo_sum_next),
        .product_carry_shifted(int4_lo_carry_next));
    dse_int4_booth_rows u_int4_hi(
        .a(m0_activation[7:4]), .b(m0_weight[7:4]),
        .product_sum(int4_hi_sum_next),
        .product_carry_shifted(int4_hi_carry_next));

    dse_adder_select #(.W(16), .SEG(4), .IMPL(1)) u_product_cpa(
        .a(m1b_int8_sum[15:0]), .b(m1b_int8_carry[15:0]),
        .cin(1'b0), .sum(int8_product_next), .cout(int8_product_cout));

    dse_acc32_csa_state_core u_accumulator_state(
        .clk(clk), .reset(reset), .delta(delta_reg), .valid(delta_valid),
        .first(delta_first), .last(delta_last),
        .sum_state_out(sum_state), .carry_state_out(carry_state),
        .state_done(state_done));

    always_ff @(posedge clk) begin
        m0_activation <= activation;
        m0_weight <= weight;

        m1a_int8_sum <= int8_l1_sum_next;
        m1a_int8_carry <= int8_l1_carry_next;
        m1a_int8_tail <= int8_tail_next;
        m1a_int4_lo_sum <= int4_lo_sum_next;
        m1a_int4_lo_carry <= int4_lo_carry_next;
        m1a_int4_hi_sum <= int4_hi_sum_next;
        m1a_int4_hi_carry <= int4_hi_carry_next;

        m1b_int8_sum <= int8_final_sum_next;
        m1b_int8_carry <= int8_final_carry_next;
        m1b_int4_lo_sum <= m1a_int4_lo_sum;
        m1b_int4_lo_carry <= m1a_int4_lo_carry;
        m1b_int4_hi_sum <= m1a_int4_hi_sum;
        m1b_int4_hi_carry <= m1a_int4_hi_carry;

        m2_product8 <= int8_product_next;
        m2_product4_0 <= int4_product0_next;
        m2_product4_1 <= int4_product1_next;
        delta_reg <= delta_onehot;
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            m0_int8_token <= 1'b0;
            m0_int4_token <= 2'b0;
            m0_first <= 1'b0;
            m0_last <= 1'b0;
            m1a_int8_token <= 1'b0;
            m1a_int4_token <= 2'b0;
            m1a_first <= 1'b0;
            m1a_last <= 1'b0;
            m1b_int8_token <= 1'b0;
            m1b_int4_token <= 2'b0;
            m1b_first <= 1'b0;
            m1b_last <= 1'b0;
            m2_int8_token <= 1'b0;
            m2_int4_token <= 2'b0;
            m2_first <= 1'b0;
            m2_last <= 1'b0;
            delta_valid <= 1'b0;
            delta_first <= 1'b0;
            delta_last <= 1'b0;
        end else begin
            m0_int8_token <= int8_token_in;
            m0_int4_token <= int4_token_in;
            m0_first <= first_in;
            m0_last <= last_in;
            m1a_int8_token <= m0_int8_token;
            m1a_int4_token <= m0_int4_token;
            m1a_first <= m0_first;
            m1a_last <= m0_last;
            m1b_int8_token <= m1a_int8_token;
            m1b_int4_token <= m1a_int4_token;
            m1b_first <= m1a_first;
            m1b_last <= m1a_last;
            m2_int8_token <= m1b_int8_token;
            m2_int4_token <= m1b_int4_token;
            m2_first <= m1b_first;
            m2_last <= m1b_last;
            delta_valid <= m2_int8_token | m2_int4_any;
            delta_first <= m2_first;
            delta_last <= m2_last;
        end
    end
endmodule

module dse_pe_token_single_top (
    input wire clk, reset, precision_mode,
    input wire [7:0] activation, weight,
    input wire [1:0] valid_in,
    input wire first_in, last_in,
    output wire [31:0] sum_state, carry_state,
    output wire state_done
);
    wire int8_token = valid_in[0] & ~precision_mode;
    wire [1:0] int4_token = valid_in & {2{precision_mode}};

    dse_pe_local_token_candidate u_pe(
        .clk(clk), .reset(reset), .int8_token_in(int8_token),
        .int4_token_in(int4_token), .activation(activation), .weight(weight),
        .first_in(first_in), .last_in(last_in), .sum_state(sum_state),
        .carry_state(carry_state), .state_done(state_done));
endmodule

module dse_pe_token_array2x2_top (
    input wire clk, reset, precision_mode,
    input wire [7:0] activation0, activation1, weight0, weight1,
    input wire [1:0] valid_in,
    input wire first_in, last_in,
    output wire [127:0] sum_state,
    output wire [127:0] carry_state,
    output wire [3:0] state_done
);
    wire int8_token = valid_in[0] & ~precision_mode;
    wire [1:0] int4_token = valid_in & {2{precision_mode}};

    dse_pe_local_token_candidate u_pe00(
        .clk(clk), .reset(reset), .int8_token_in(int8_token),
        .int4_token_in(int4_token), .activation(activation0), .weight(weight0),
        .first_in(first_in), .last_in(last_in),
        .sum_state(sum_state[31:0]), .carry_state(carry_state[31:0]),
        .state_done(state_done[0]));
    dse_pe_local_token_candidate u_pe01(
        .clk(clk), .reset(reset), .int8_token_in(int8_token),
        .int4_token_in(int4_token), .activation(activation0), .weight(weight1),
        .first_in(first_in), .last_in(last_in),
        .sum_state(sum_state[63:32]), .carry_state(carry_state[63:32]),
        .state_done(state_done[1]));
    dse_pe_local_token_candidate u_pe10(
        .clk(clk), .reset(reset), .int8_token_in(int8_token),
        .int4_token_in(int4_token), .activation(activation1), .weight(weight0),
        .first_in(first_in), .last_in(last_in),
        .sum_state(sum_state[95:64]), .carry_state(carry_state[95:64]),
        .state_done(state_done[2]));
    dse_pe_local_token_candidate u_pe11(
        .clk(clk), .reset(reset), .int8_token_in(int8_token),
        .int4_token_in(int4_token), .activation(activation1), .weight(weight1),
        .first_in(first_in), .last_in(last_in),
        .sum_state(sum_state[127:96]), .carry_state(carry_state[127:96]),
        .state_done(state_done[3]));
endmodule

module dse_pe_state_single_top (
    input wire clk, reset, precision_mode,
    input wire [7:0] activation, weight,
    input wire [1:0] valid_in,
    input wire first_in, last_in,
    output wire [31:0] sum_state, carry_state,
    output wire state_done
);
    dse_pe_state_candidate u_pe(.*);
endmodule

module dse_pe_state_array2x2_top (
    input wire clk, reset, precision_mode,
    input wire [7:0] activation0, activation1, weight0, weight1,
    input wire [1:0] valid_in,
    input wire first_in, last_in,
    output wire [127:0] sum_state,
    output wire [127:0] carry_state,
    output wire [3:0] state_done
);
    dse_pe_state_candidate u_pe00(
        .clk(clk), .reset(reset), .precision_mode(precision_mode),
        .activation(activation0), .weight(weight0), .valid_in(valid_in),
        .first_in(first_in), .last_in(last_in),
        .sum_state(sum_state[31:0]), .carry_state(carry_state[31:0]),
        .state_done(state_done[0]));
    dse_pe_state_candidate u_pe01(
        .clk(clk), .reset(reset), .precision_mode(precision_mode),
        .activation(activation0), .weight(weight1), .valid_in(valid_in),
        .first_in(first_in), .last_in(last_in),
        .sum_state(sum_state[63:32]), .carry_state(carry_state[63:32]),
        .state_done(state_done[1]));
    dse_pe_state_candidate u_pe10(
        .clk(clk), .reset(reset), .precision_mode(precision_mode),
        .activation(activation1), .weight(weight0), .valid_in(valid_in),
        .first_in(first_in), .last_in(last_in),
        .sum_state(sum_state[95:64]), .carry_state(carry_state[95:64]),
        .state_done(state_done[2]));
    dse_pe_state_candidate u_pe11(
        .clk(clk), .reset(reset), .precision_mode(precision_mode),
        .activation(activation1), .weight(weight1), .valid_in(valid_in),
        .first_in(first_in), .last_in(last_in),
        .sum_state(sum_state[127:96]), .carry_state(carry_state[127:96]),
        .state_done(state_done[3]));
endmodule

`default_nettype wire
