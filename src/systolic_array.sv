`default_nettype none
`timescale 1ns/1ps

// Output-stationary SIMD systolic array. Each edge packet carries either one
// INT8 operand or two packed INT4 operands. A propagates east and B south.
module systolic_array #(
    parameter integer N             = 16,
    parameter integer ACC_WIDTH     = 32,
    parameter integer USE_CSA_ACCUM = 0
) (
    input  wire                         clk,
    input  wire                         reset,
    input  wire                         precision_load,
    input  wire                         precision_mode,
    input  wire [7:0]                   activation_in [0:N-1],
    input  wire [7:0]                   weight_in [0:N-1],
    input  wire [1:0]                   activation_valid [0:N-1],
    input  wire [1:0]                   weight_valid [0:N-1],
    input  wire                         activation_first [0:N-1],
    input  wire                         weight_first [0:N-1],
    input  wire                         activation_last [0:N-1],
    input  wire                         weight_last [0:N-1],
    output wire signed [ACC_WIDTH-1:0]  result_sum [0:N-1][0:N-1],
    output wire signed [ACC_WIDTH-1:0]  result_carry [0:N-1][0:N-1],
    output wire                         tile_done
);

    wire [7:0] activation_bus [0:N-1][0:N];
    wire [7:0] weight_bus     [0:N][0:N-1];
    wire [1:0] activation_vld [0:N-1][0:N];
    wire [1:0] weight_vld     [0:N][0:N-1];
    wire       activation_fst [0:N-1][0:N];
    wire       weight_fst     [0:N][0:N-1];
    wire       activation_lst [0:N-1][0:N];
    wire       weight_lst     [0:N][0:N-1];
    wire       precision_bus  [0:N-1][0:N];
    wire       pe_tile_done   [0:N-1][0:N-1];
    reg        row_precision  [0:N-1];

    assign tile_done = pe_tile_done[N-1][N-1];

    genvar row, col;
    generate
        for (row = 0; row < N; row = row + 1) begin : edge_rows
            always_ff @(posedge clk) begin
                // Precision is loaded before any valid job token is issued;
                // stale mode bits during reset are therefore unobservable.
                if (precision_load)
                    row_precision[row] <= precision_mode;
            end
            assign activation_bus[row][0] = activation_in[row];
            assign activation_vld[row][0] = activation_valid[row];
            assign activation_fst[row][0] = activation_first[row];
            assign activation_lst[row][0] = activation_last[row];
            assign precision_bus[row][0]  = row_precision[row];
        end
        for (col = 0; col < N; col = col + 1) begin : edge_cols
            assign weight_bus[0][col] = weight_in[col];
            assign weight_vld[0][col] = weight_valid[col];
            assign weight_fst[0][col] = weight_first[col];
            assign weight_lst[0][col] = weight_last[col];
        end
        for (row = 0; row < N; row = row + 1) begin : pe_rows
            for (col = 0; col < N; col = col + 1) begin : pe_cols
                pe #(
                    .ACC_WIDTH(ACC_WIDTH),
                    .USE_CSA_ACCUM(USE_CSA_ACCUM)
                ) u_pe (
                    .clk(clk),
                    .reset(reset),
                    .precision_mode(precision_bus[row][col]),
                    .activation_in(activation_bus[row][col]),
                    .weight_in(weight_bus[row][col]),
                    .activation_valid_in(activation_vld[row][col]),
                    .weight_valid_in(weight_vld[row][col]),
                    .activation_first_in(activation_fst[row][col]),
                    .weight_first_in(weight_fst[row][col]),
                    .activation_last_in(activation_lst[row][col]),
                    .weight_last_in(weight_lst[row][col]),
                    .activation_out(activation_bus[row][col+1]),
                    .weight_out(weight_bus[row+1][col]),
                    .activation_valid_out(activation_vld[row][col+1]),
                    .weight_valid_out(weight_vld[row+1][col]),
                    .activation_first_out(activation_fst[row][col+1]),
                    .weight_first_out(weight_fst[row+1][col]),
                    .activation_last_out(activation_lst[row][col+1]),
                    .weight_last_out(weight_lst[row+1][col]),
                    .precision_out(precision_bus[row][col+1]),
                    .accumulator_sum(result_sum[row][col]),
                    .accumulator_carry(result_carry[row][col]),
                    .tile_done(pe_tile_done[row][col])
                );
            end
        end
    endgenerate

endmodule

`default_nettype wire
