`default_nettype none
`timescale 1ns/1ps

// Runtime-configurable tiled GEMM engine.
//
// A and B use 128-bit K-slice streams. Byte i belongs to physical row/column i.
// INT8: byte i is one signed operand for one K position.
// INT4: byte i packs {operand[k+1], operand[k]} as two signed nibbles.
//
// Input tile order is (mt, nt, kt). For each output C tile, all K tiles are
// supplied before advancing nt and mt. Results are tile-major and row-major
// inside each tile.
module operand_skew_lane #(
    parameter integer DELAY = 0
) (
    input  wire       clk,
    input  wire       reset,
    input  wire [7:0] data_in,
    input  wire [1:0] valid_in,
    input  wire       first_in,
    input  wire       last_in,
    output wire [7:0] data_out,
    output wire [1:0] valid_out,
    output wire       first_out,
    output wire       last_out
);
    generate
        if (DELAY == 0) begin : no_extra_skew
            assign data_out  = data_in;
            assign valid_out = valid_in;
            assign first_out = first_in;
            assign last_out  = last_in;
        end else begin : registered_skew
            reg [7:0] data_pipe [0:DELAY-1];
            reg [1:0] valid_pipe [0:DELAY-1];
            reg       first_pipe [0:DELAY-1];
            reg       last_pipe [0:DELAY-1];

            assign data_out  = data_pipe[DELAY-1];
            assign valid_out = valid_pipe[DELAY-1];
            assign first_out = first_pipe[DELAY-1];
            assign last_out  = last_pipe[DELAY-1];

            // Packed data is don't-care whenever valid is zero, so it need not
            // be reset. Keeping reset out of this wide datapath avoids adding a
            // reset/hold mux to every skew data bit.
            always_ff @(posedge clk) begin : update_skew_data
                integer data_stage;
                if (|valid_in) data_pipe[0] <= data_in;
                for (data_stage = 1; data_stage < DELAY;
                     data_stage = data_stage + 1)
                    if (|valid_pipe[data_stage-1])
                        data_pipe[data_stage] <= data_pipe[data_stage-1];
            end

            always_ff @(posedge clk) begin : update_skew_tokens
                integer token_stage;
                if (reset) begin
                    for (token_stage = 0; token_stage < DELAY;
                         token_stage = token_stage + 1) begin
                        valid_pipe[token_stage] <= 2'b0;
                        first_pipe[token_stage] <= 1'b0;
                        last_pipe[token_stage]  <= 1'b0;
                    end
                end else begin
                    valid_pipe[0] <= valid_in;
                    first_pipe[0] <= first_in;
                    last_pipe[0]  <= last_in;
                    for (token_stage = 1; token_stage < DELAY;
                         token_stage = token_stage + 1) begin
                        valid_pipe[token_stage] <= valid_pipe[token_stage-1];
                        first_pipe[token_stage] <= first_pipe[token_stage-1];
                        last_pipe[token_stage]  <= last_pipe[token_stage-1];
                    end
                end
            end
        end
    endgenerate
endmodule

// Sixteen-bit parallel-prefix CPA. Four fixed prefix levels replace the
// former ripple-plus-select chain on the result-finalizer critical path.
module result_prefix16 (
    input  wire [15:0] a,
    input  wire [15:0] b,
    input  wire        cin,
    output wire [15:0] sum,
    output wire        cout
);
    wire [15:0] p0 = a ^ b;
    wire [15:0] g0 = a & b;
    wire [15:0] p1, g1, p2, g2, p4, g4, p8, g8;
    wire [16:0] carry;

    for (genvar bit1 = 0; bit1 < 16; bit1 = bit1 + 1) begin : prefix_1
        if (bit1 >= 1) begin : has_predecessor
            assign g1[bit1] = g0[bit1] | (p0[bit1] & g0[bit1-1]);
            assign p1[bit1] = p0[bit1] & p0[bit1-1];
        end else begin : first_bit
            assign g1[bit1] = g0[bit1];
            assign p1[bit1] = p0[bit1];
        end
    end
    for (genvar bit2 = 0; bit2 < 16; bit2 = bit2 + 1) begin : prefix_2
        if (bit2 >= 2) begin : has_predecessor
            assign g2[bit2] = g1[bit2] | (p1[bit2] & g1[bit2-2]);
            assign p2[bit2] = p1[bit2] & p1[bit2-2];
        end else begin : first_span
            assign g2[bit2] = g1[bit2];
            assign p2[bit2] = p1[bit2];
        end
    end
    for (genvar bit4 = 0; bit4 < 16; bit4 = bit4 + 1) begin : prefix_4
        if (bit4 >= 4) begin : has_predecessor
            assign g4[bit4] = g2[bit4] | (p2[bit4] & g2[bit4-4]);
            assign p4[bit4] = p2[bit4] & p2[bit4-4];
        end else begin : first_span
            assign g4[bit4] = g2[bit4];
            assign p4[bit4] = p2[bit4];
        end
    end
    for (genvar bit8 = 0; bit8 < 16; bit8 = bit8 + 1) begin : prefix_8
        if (bit8 >= 8) begin : has_predecessor
            assign g8[bit8] = g4[bit8] | (p4[bit8] & g4[bit8-8]);
            assign p8[bit8] = p4[bit8] & p4[bit8-8];
        end else begin : first_span
            assign g8[bit8] = g4[bit8];
            assign p8[bit8] = p4[bit8];
        end
    end

    assign carry[0] = cin;
    for (genvar carry_bit = 0; carry_bit < 16;
         carry_bit = carry_bit + 1) begin : prefix_carry
        assign carry[carry_bit+1] =
            g8[carry_bit] | (p8[carry_bit] & cin);
    end
    assign sum = p0 ^ carry[15:0];
    assign cout = carry[16];
endmodule

// FF-based result storage with one local registered enable per 32-bit word.
// Separate sum/carry enable replicas cap each functional enable fanout at 32.
module result_capture_word #(
    parameter integer W = 32
) (
    input  wire                clk,
    input  wire                reset,
    input  wire                capture_enable,
    input  wire signed [W-1:0] sum_in,
    input  wire signed [W-1:0] carry_in,
    output reg  signed [W-1:0] sum_out,
    output reg  signed [W-1:0] carry_out
);
    (* preserve = "true" *) reg sum_write_enable;
    (* preserve = "true" *) reg carry_write_enable;

    always_ff @(posedge clk) begin
        if (reset) begin
            sum_write_enable   <= 1'b0;
            carry_write_enable <= 1'b0;
        end else begin
            sum_write_enable   <= capture_enable;
            carry_write_enable <= capture_enable;
            if (sum_write_enable)
                sum_out <= sum_in;
            if (carry_write_enable)
                carry_out <= carry_in;
        end
    end
endmodule

// One physical 128-bit tile-buffer word.  The address/bank comparison is made
// before this boundary; four preserved local enables each drive one fixed
// 32-bit quadrant.  This prevents a loader-valid net from becoming the enable
// of every FF in the complete ping-pong buffer.
module tile_buffer_word (
    input  wire         clk,
    input  wire         reset,
    input  wire         write_match,
    input  wire [127:0] write_data,
    output reg  [127:0] read_data
);
    (* preserve = "true" *) reg [3:0] quadrant_write_enable;

    always_ff @(posedge clk) begin : update_word
        integer quadrant;
        if (reset) begin
            quadrant_write_enable <= 4'b0;
        end else begin
            quadrant_write_enable <= {4{write_match}};
            for (quadrant = 0; quadrant < 4; quadrant = quadrant + 1)
                if (quadrant_write_enable[quadrant])
                    read_data[quadrant*32 +: 32] <=
                        write_data[quadrant*32 +: 32];
        end
    end
endmodule

// Four-word slice of the row serializer. prepare_load is asserted one phase
// before the architectural COMMIT edge, so the registered local load command
// replaces a wide state-decode cone without adding an externally visible
// cycle. Shift remains qualified by the actual output handshake.
module result_serializer_group #(
    parameter integer W = 32,
    parameter integer WORDS = 4
) (
    input  wire                 clk,
    input  wire                 reset,
    input  wire                 prepare_load,
    input  wire                 shift_enable,
    input  wire [WORDS*W-1:0]   load_data,
    input  wire [W-1:0]         shift_tail_in,
    output reg  [WORDS*W-1:0]   data_out
);
    reg load_pending;

    always_ff @(posedge clk) begin : update_load_token
        if (reset)
            load_pending <= 1'b0;
        else
            load_pending <= prepare_load;
    end

    // Payload is don't-care until the reset load token has been re-established;
    // keep reset out of the wide serializer data-input mux.
    always_ff @(posedge clk) begin : update_group_payload
        integer word_index;
        if (load_pending) begin
            data_out <= load_data;
        end else if (shift_enable) begin
            for (word_index = 0; word_index < WORDS-1;
                 word_index = word_index + 1)
                data_out[word_index*W +: W] <=
                    data_out[(word_index+1)*W +: W];
            data_out[(WORDS-1)*W +: W] <= shift_tail_in;
        end
    end
endmodule

// Genus top-level parameter override creates the concrete design name
// tpu_stream_top_USE_CSA_ACCUM0/1. Synthesis scripts must select that derived
// design after elaboration; tpu_stream_top remains the RTL architecture name.
module tpu_stream_top #(
    parameter integer ARRAY_SIZE = 16,
    parameter integer ACC_WIDTH  = 32,
    parameter integer USE_CSA_ACCUM = 0,
    // Current architecture: tile descriptors and two-stage 16-bit result CPA.
    // Legacy selector modes remain available for controlled comparisons;
    // common completion, payload-enable and output-control fixes apply to all.
    parameter integer SCHED_IMPL  = 2,
    parameter integer RESULT_IMPL = 0,
    parameter integer FEEDER_IMPL = 0
) (
    input  wire                         clk,
    input  wire                         reset,

    input  wire                         cfg_valid,
    output wire                         cfg_ready,
    input  wire [15:0]                  cfg_m,
    input  wire [15:0]                  cfg_n,
    input  wire [15:0]                  cfg_k,
    input  wire                         precision_mode,

    input  wire [127:0]                 s_activation_data,
    input  wire                         s_activation_valid,
    output wire                         s_activation_ready,
    input  wire [127:0]                 s_weight_data,
    input  wire                         s_weight_valid,
    output wire                         s_weight_ready,

    output wire signed [ACC_WIDTH-1:0]  m_result_data,
    output wire                         m_result_valid,
    input  wire                         m_result_ready,
    output wire                         m_result_tile_last,
    output wire                         m_result_last,
    output wire                         busy
);

    localparam integer K_PACKET_DEPTH = 16;

    localparam [4:0] S_IDLE       = 5'd0;
    localparam [4:0] S_WAIT_BANK  = 5'd1;
    localparam [4:0] S_PREP_LEN   = 5'd2;
    localparam [4:0] S_START      = 5'd3;
    localparam [4:0] S_COMPUTE    = 5'd4;
    localparam [4:0] S_CAPTURE    = 5'd5;
    localparam [4:0] S_DRAIN      = 5'd6;
    localparam [4:0] S_DRAIN_LOAD = 5'd7;
    localparam [4:0] S_PREP_COUNT = 5'd8;
    localparam [4:0] S_PRELOAD_LEN = 5'd9;
    localparam [4:0] S_PRELOAD_COUNT = 5'd10;
    localparam [4:0] S_DRAIN_ARM  = 5'd11;
    localparam [4:0] S_DRAIN_FINALIZE_LO = 5'd12;
    localparam [4:0] S_DRAIN_FINALIZE_HI = 5'd13;
    localparam [4:0] S_CAPTURE_FLUSH = 5'd14;
    localparam [4:0] S_DRAIN_COMMIT = 5'd15;

    localparam [4:0] S_ADVANCE_TILE = 5'd16;
    localparam [4:0] S_WAIT_ROW = 5'd17;
    reg [4:0] state;
    reg [3:0] last_row_index, last_col_index, penultimate_col_index;
    reg last_m_tile, last_n_tile, row_is_last;

    reg [15:0] cfg_m_reg, cfg_n_reg, cfg_k_reg;
    reg        precision_reg;
    reg [15:0] m_base, n_base, k_base;
    reg [15:0] m_remaining, n_remaining, k_remaining;
    reg [15:0] next_k_remaining;
    reg [4:0]  m_len, n_len, k_len;
    reg [4:0]  next_k_len;
    reg [4:0]  k_steps;
    // S1 replaces the architecturally redundant k_base==0 test with this
    // one-bit token. S2 additionally turns per-compute tile facts into a
    // descriptor which is prepared before issue begins.
    reg        first_k_tile;
    reg        descriptor_last_k_tile;
    reg [3:0]  descriptor_last_packet;

    // Packed storage is retained through the tile buffer. In INT4 mode the
    // two nibbles are interpreted as independent lanes only at the PE input.
    // Split every 16-entry bank into two 8-entry sub-banks. Reads below name
    // each physical bank/half explicitly: the only dynamic memory selector is
    // therefore 8:1, followed by a small 4-way bank/half selector.
    wire [127:0] a_tile_buffer [0:1][0:1][0:7];
    wire [127:0] b_tile_buffer [0:1][0:1][0:7];
    reg [127:0] a_write_data_stage, b_write_data_stage;
    reg         a_write_last_stage, b_write_last_stage;
    reg         a_write_command_valid, b_write_command_valid;
    reg a_write_done, b_write_done;
    // A bank is readable after both loaders have completed it.  It remains
    // readable until its final packet has crossed the buffer-to-R0 boundary.
    // Array completion is a separate, later event carried by the last token;
    // do not retain the buffer merely because MACs are still in flight.
    reg [1:0] bank_readable;
    reg       compute_bank;

    // One independent loader fills the non-compute ping-pong bank. A and B
    // have separate ready/valid progress counters within the same tile.
    reg       loader_active;
    reg       loader_bank;
    reg [4:0] load_steps;
    reg [4:0] a_load_count, b_load_count;
    reg       a_load_done, b_load_done;

    reg [3:0] k_read_addr;
    reg       issue_active;

    // Two-stage tile-buffer read pipeline.
    // R0 terminates the four independent bank-local 8:1 muxes.  Its selector
    // and token metadata describe exactly the candidates captured with it.
    // F3 has eight 4:1 candidates; the other feeder variants use candidates
    // 0..3 as the existing four 8:1 local muxes.
    reg [127:0] a_r0_candidate [0:7];
    reg [127:0] b_r0_candidate [0:7];
    reg [2:0]   r0_candidate_select;
    reg [1:0]   r0_operand_valid;
    reg         r0_first;
    reg         r0_last;
    reg         r0_a_lane_active [0:ARRAY_SIZE-1];
    reg         r0_b_lane_active [0:ARRAY_SIZE-1];

    // R1 selects one registered candidate and is the single packet boundary
    // feeding lane split/skew.  The token arrays below are R1 metadata, not
    // independently generated scheduler controls.
    reg [127:0] a_read_packet_reg, b_read_packet_reg;
    reg [1:0] a_read_valid_reg [0:ARRAY_SIZE-1];
    reg [1:0] b_read_valid_reg [0:ARRAY_SIZE-1];
    reg       a_read_first_reg [0:ARRAY_SIZE-1];
    reg       b_read_first_reg [0:ARRAY_SIZE-1];
    reg       a_read_last_reg [0:ARRAY_SIZE-1];
    reg       b_read_last_reg [0:ARRAY_SIZE-1];
    reg [3:0] capture_row;
    reg [3:0] drain_row, drain_col;
    reg [3:0] prefetch_row;
    reg [2:0] prefetch_phase;
    reg prefetch_ready;
    wire [3:0] result_read_row = (prefetch_phase != 0) ? prefetch_row : drain_row;

    // Phase one uses one result bank. Capture/drain ownership is explicit so
    // a second bank and pointer toggle can be added without changing the
    // result interface or array capture protocol.
    // Four 4-row quarters keep the registered row-read fan-in at 4:1. Columns
    // remain independent banks so one complete row is available in parallel.
    wire signed [ACC_WIDTH-1:0] result_buffer_sum
        [0:3][0:3][0:ARRAY_SIZE-1];
    wire signed [ACC_WIDTH-1:0] result_buffer_carry
        [0:3][0:3][0:ARRAY_SIZE-1];
    reg result_bank_full;
    // R0 terminates four independent 4:1 row muxes. R1 sees only registered
    // candidates and a registered two-bit quarter selector.
    reg signed [ACC_WIDTH-1:0] result_sum_candidate_quarter
        [0:3][0:ARRAY_SIZE-1];
    reg signed [ACC_WIDTH-1:0] result_carry_candidate_quarter
        [0:3][0:ARRAY_SIZE-1];
    reg [1:0] result_quarter_select_r0;
    reg signed [ACC_WIDTH-1:0] result_row_sum_stage [0:ARRAY_SIZE-1];
    reg signed [ACC_WIDTH-1:0] result_row_carry_stage [0:ARRAY_SIZE-1];
    reg [15:0] result_row_low_stage [0:ARRAY_SIZE-1];
    reg [15:0] result_row_upper_sum_stage [0:ARRAY_SIZE-1];
    reg [15:0] result_row_upper_carry_stage [0:ARRAY_SIZE-1];
    reg result_row_low_carry_stage [0:ARRAY_SIZE-1];
    reg signed [ACC_WIDTH-1:0] result_row_final_stage [0:ARRAY_SIZE-1];
    // Identical command bits are intentionally replicated by column. They
    // terminate the central FSM decode before it reaches wide payload banks.
    (* preserve = "true" *) reg [ARRAY_SIZE-1:0] result_r0_load_cmd;
    (* preserve = "true" *) reg [ARRAY_SIZE-1:0] result_r1_select_cmd;
    (* preserve = "true" *) reg [ARRAY_SIZE-1:0] result_finalize_lo_cmd;
    (* preserve = "true" *) reg [ARRAY_SIZE-1:0] result_finalize_hi_cmd;
    wire [4*ACC_WIDTH-1:0] result_serializer_load [0:3];
    wire [4*ACC_WIDTH-1:0] result_serializer_data [0:3];
    reg result_valid_reg;
    reg result_tile_last_reg;
    reg result_last_reg;
    wire [ARRAY_SIZE-1:0] capture_oh;
    wire signed [ACC_WIDTH-1:0] result_sum_read_quarter
        [0:3][0:ARRAY_SIZE-1];
    wire signed [ACC_WIDTH-1:0] result_carry_read_quarter
        [0:3][0:ARRAY_SIZE-1];
    wire [15:0] result_row_upper_final [0:ARRAY_SIZE-1];
    wire        result_row_upper_cout [0:ARRAY_SIZE-1];
    wire [15:0] result_row_low_sum_comb [0:ARRAY_SIZE-1];
    wire        result_row_low_carry_comb [0:ARRAY_SIZE-1];

    wire [7:0] a_edge [0:ARRAY_SIZE-1];
    wire [7:0] b_edge [0:ARRAY_SIZE-1];
    wire [1:0] a_edge_valid [0:ARRAY_SIZE-1];
    wire [1:0] b_edge_valid [0:ARRAY_SIZE-1];
    wire       a_edge_first [0:ARRAY_SIZE-1];
    wire       b_edge_first [0:ARRAY_SIZE-1];
    wire       a_edge_last [0:ARRAY_SIZE-1];
    wire       b_edge_last [0:ARRAY_SIZE-1];
    wire signed [ACC_WIDTH-1:0] array_result_sum
        [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire signed [ACC_WIDTH-1:0] array_result_carry
        [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    wire array_tile_done;

    // Clamp an already-registered remaining dimension to the physical tile.
    // Keeping subtraction out of this function makes the clamp a constant
    // upper-bit test plus a small mux instead of a subtract/compare chain.
    function automatic [4:0] clamp_tile_len;
        input [15:0] remaining;
        begin
            if (|remaining[15:4])
                clamp_tile_len = 5'd16;
            else
                clamp_tile_len = {1'b0, remaining[3:0]};
        end
    endfunction

    function automatic [4:0] packet_count;
        input [4:0] scalar_count;
        input       int4_mode;
        begin
            if (int4_mode)
                packet_count = (scalar_count + 1'b1) >> 1;
            else
                packet_count = scalar_count;
        end
    endfunction

    // A synchronous reset must not advertise a handshake which the reset
    // branch below would discard at the same edge.
    assign cfg_ready = !reset && (state == S_IDLE);
    assign busy = !reset && (state != S_IDLE);

    wire a_load_fire = s_activation_valid && s_activation_ready;
    wire b_load_fire = s_weight_valid && s_weight_ready;
    wire a_load_last = a_load_fire && (a_load_count == load_steps-1'b1);
    wire b_load_last = b_load_fire && (b_load_count == load_steps-1'b1);
    wire a_write_last_commit = a_write_command_valid &&
                               a_write_last_stage;
    wire b_write_last_commit = b_write_command_valid &&
                               b_write_last_stage;
    wire loader_complete_now = loader_active &&
        (a_write_done || a_write_last_commit) &&
        (b_write_done || b_write_last_commit);
    wire loader_launch = (state == S_PREP_COUNT) ||
                         (state == S_PRELOAD_COUNT);

    assign s_activation_ready = !reset && loader_active && !a_load_done;
    assign s_weight_ready     = !reset && loader_active && !b_load_done;

    // issue_active is asserted only on entry to COMPUTE and cleared on the
    // final packet. The state comparison was redundant and placed the FSM
    // decode on every R0 candidate-register enable.
    wire issue_valid = issue_active;
    wire scheduler_first_k = (SCHED_IMPL == 0) ? (k_base == 0) : first_k_tile;
    wire scheduler_last_k = (SCHED_IMPL == 2) ? descriptor_last_k_tile :
                                                  (k_remaining <= 16'd16);
    wire [3:0] scheduler_last_packet = (SCHED_IMPL == 2) ?
                                      descriptor_last_packet : (k_steps[3:0] - 4'd1);
    wire issue_first = issue_valid && scheduler_first_k && (k_read_addr == 0);
    wire issue_last = issue_valid && (k_read_addr == scheduler_last_packet);
    wire [4:0] issue_scalar_base = {k_read_addr, 1'b0};
    wire issue_lane1_valid = issue_valid && precision_reg &&
                             ((issue_scalar_base + 5'd1) < k_len);

    // Buffer lifetime ends when its final packet is safely registered in R0.
    // C-tile compute ends only when its final K packet reaches the
    // far-corner PE.  Keeping these events separate avoids latency constants
    // in the scheduler when read/PE pipelines change.
    wire bank_read_done_event = issue_last;
    wire bank_compute_done_event = array_tile_done;

    wire [127:0] a_read_b0_lo = a_tile_buffer[0][0][k_read_addr[2:0]];
    wire [127:0] a_read_b0_hi = a_tile_buffer[0][1][k_read_addr[2:0]];
    wire [127:0] a_read_b1_lo = a_tile_buffer[1][0][k_read_addr[2:0]];
    wire [127:0] a_read_b1_hi = a_tile_buffer[1][1][k_read_addr[2:0]];
    wire [127:0] b_read_b0_lo = b_tile_buffer[0][0][k_read_addr[2:0]];
    wire [127:0] b_read_b0_hi = b_tile_buffer[0][1][k_read_addr[2:0]];
    wire [127:0] b_read_b1_lo = b_tile_buffer[1][0][k_read_addr[2:0]];
    wire [127:0] b_read_b1_hi = b_tile_buffer[1][1][k_read_addr[2:0]];

    // F1 evaluates the local 8-entry address as an explicit one-hot tree.
    // Its protocol timing is identical to the binary-mux baseline.
    wire [7:0] feeder_read_oh = 8'b00000001 << k_read_addr[2:0];
    function automatic [127:0] select_packet8_onehot;
        input [7:0] select;
        input [127:0] word0, word1, word2, word3;
        input [127:0] word4, word5, word6, word7;
        begin
            select_packet8_onehot =
                ({128{select[0]}} & word0) | ({128{select[1]}} & word1) |
                ({128{select[2]}} & word2) | ({128{select[3]}} & word3) |
                ({128{select[4]}} & word4) | ({128{select[5]}} & word5) |
                ({128{select[6]}} & word6) | ({128{select[7]}} & word7);
        end
    endfunction
    wire [127:0] a_read_b0_lo_f1 = select_packet8_onehot(feeder_read_oh, a_tile_buffer[0][0][0], a_tile_buffer[0][0][1], a_tile_buffer[0][0][2], a_tile_buffer[0][0][3], a_tile_buffer[0][0][4], a_tile_buffer[0][0][5], a_tile_buffer[0][0][6], a_tile_buffer[0][0][7]);
    wire [127:0] a_read_b0_hi_f1 = select_packet8_onehot(feeder_read_oh, a_tile_buffer[0][1][0], a_tile_buffer[0][1][1], a_tile_buffer[0][1][2], a_tile_buffer[0][1][3], a_tile_buffer[0][1][4], a_tile_buffer[0][1][5], a_tile_buffer[0][1][6], a_tile_buffer[0][1][7]);
    wire [127:0] a_read_b1_lo_f1 = select_packet8_onehot(feeder_read_oh, a_tile_buffer[1][0][0], a_tile_buffer[1][0][1], a_tile_buffer[1][0][2], a_tile_buffer[1][0][3], a_tile_buffer[1][0][4], a_tile_buffer[1][0][5], a_tile_buffer[1][0][6], a_tile_buffer[1][0][7]);
    wire [127:0] a_read_b1_hi_f1 = select_packet8_onehot(feeder_read_oh, a_tile_buffer[1][1][0], a_tile_buffer[1][1][1], a_tile_buffer[1][1][2], a_tile_buffer[1][1][3], a_tile_buffer[1][1][4], a_tile_buffer[1][1][5], a_tile_buffer[1][1][6], a_tile_buffer[1][1][7]);
    wire [127:0] b_read_b0_lo_f1 = select_packet8_onehot(feeder_read_oh, b_tile_buffer[0][0][0], b_tile_buffer[0][0][1], b_tile_buffer[0][0][2], b_tile_buffer[0][0][3], b_tile_buffer[0][0][4], b_tile_buffer[0][0][5], b_tile_buffer[0][0][6], b_tile_buffer[0][0][7]);
    wire [127:0] b_read_b0_hi_f1 = select_packet8_onehot(feeder_read_oh, b_tile_buffer[0][1][0], b_tile_buffer[0][1][1], b_tile_buffer[0][1][2], b_tile_buffer[0][1][3], b_tile_buffer[0][1][4], b_tile_buffer[0][1][5], b_tile_buffer[0][1][6], b_tile_buffer[0][1][7]);
    wire [127:0] b_read_b1_lo_f1 = select_packet8_onehot(feeder_read_oh, b_tile_buffer[1][0][0], b_tile_buffer[1][0][1], b_tile_buffer[1][0][2], b_tile_buffer[1][0][3], b_tile_buffer[1][0][4], b_tile_buffer[1][0][5], b_tile_buffer[1][0][6], b_tile_buffer[1][0][7]);
    wire [127:0] b_read_b1_hi_f1 = select_packet8_onehot(feeder_read_oh, b_tile_buffer[1][1][0], b_tile_buffer[1][1][1], b_tile_buffer[1][1][2], b_tile_buffer[1][1][3], b_tile_buffer[1][1][4], b_tile_buffer[1][1][5], b_tile_buffer[1][1][6], b_tile_buffer[1][1][7]);

    // F3: two 4-entry groups per bank/half. R0 sees only k[1:0]; the extra
    // group select crosses R0 and is resolved by the R1 mux.
    wire [127:0] a_read_b0_lo_g0 = a_tile_buffer[0][0][{1'b0,k_read_addr[1:0]}];
    wire [127:0] a_read_b0_lo_g1 = a_tile_buffer[0][0][{1'b1,k_read_addr[1:0]}];
    wire [127:0] a_read_b0_hi_g0 = a_tile_buffer[0][1][{1'b0,k_read_addr[1:0]}];
    wire [127:0] a_read_b0_hi_g1 = a_tile_buffer[0][1][{1'b1,k_read_addr[1:0]}];
    wire [127:0] a_read_b1_lo_g0 = a_tile_buffer[1][0][{1'b0,k_read_addr[1:0]}];
    wire [127:0] a_read_b1_lo_g1 = a_tile_buffer[1][0][{1'b1,k_read_addr[1:0]}];
    wire [127:0] a_read_b1_hi_g0 = a_tile_buffer[1][1][{1'b0,k_read_addr[1:0]}];
    wire [127:0] a_read_b1_hi_g1 = a_tile_buffer[1][1][{1'b1,k_read_addr[1:0]}];
    wire [127:0] b_read_b0_lo_g0 = b_tile_buffer[0][0][{1'b0,k_read_addr[1:0]}];
    wire [127:0] b_read_b0_lo_g1 = b_tile_buffer[0][0][{1'b1,k_read_addr[1:0]}];
    wire [127:0] b_read_b0_hi_g0 = b_tile_buffer[0][1][{1'b0,k_read_addr[1:0]}];
    wire [127:0] b_read_b0_hi_g1 = b_tile_buffer[0][1][{1'b1,k_read_addr[1:0]}];
    wire [127:0] b_read_b1_lo_g0 = b_tile_buffer[1][0][{1'b0,k_read_addr[1:0]}];
    wire [127:0] b_read_b1_lo_g1 = b_tile_buffer[1][0][{1'b1,k_read_addr[1:0]}];
    wire [127:0] b_read_b1_hi_g0 = b_tile_buffer[1][1][{1'b0,k_read_addr[1:0]}];
    wire [127:0] b_read_b1_hi_g1 = b_tile_buffer[1][1][{1'b1,k_read_addr[1:0]}];

    reg [127:0] a_r1_packet_mux, b_r1_packet_mux;
    always_comb begin
        if (FEEDER_IMPL == 3) begin
            case (r0_candidate_select)
            3'd0: begin
                a_r1_packet_mux = a_r0_candidate[0];
                b_r1_packet_mux = b_r0_candidate[0];
            end
            3'd1: begin
                a_r1_packet_mux = a_r0_candidate[1];
                b_r1_packet_mux = b_r0_candidate[1];
            end
            3'd2: begin
                a_r1_packet_mux = a_r0_candidate[2];
                b_r1_packet_mux = b_r0_candidate[2];
            end
            3'd3: begin
                a_r1_packet_mux = a_r0_candidate[3];
                b_r1_packet_mux = b_r0_candidate[3];
            end
            3'd4: begin a_r1_packet_mux = a_r0_candidate[4]; b_r1_packet_mux = b_r0_candidate[4]; end
            3'd5: begin a_r1_packet_mux = a_r0_candidate[5]; b_r1_packet_mux = b_r0_candidate[5]; end
            3'd6: begin a_r1_packet_mux = a_r0_candidate[6]; b_r1_packet_mux = b_r0_candidate[6]; end
            default: begin a_r1_packet_mux = a_r0_candidate[7]; b_r1_packet_mux = b_r0_candidate[7]; end
            endcase
        end else begin
            case (r0_candidate_select[1:0])
            2'd0: begin a_r1_packet_mux = a_r0_candidate[0]; b_r1_packet_mux = b_r0_candidate[0]; end
            2'd1: begin a_r1_packet_mux = a_r0_candidate[1]; b_r1_packet_mux = b_r0_candidate[1]; end
            2'd2: begin a_r1_packet_mux = a_r0_candidate[2]; b_r1_packet_mux = b_r0_candidate[2]; end
            default: begin a_r1_packet_mux = a_r0_candidate[3]; b_r1_packet_mux = b_r0_candidate[3]; end
            endcase
        end
    end

    wire last_k_tile = scheduler_last_k;


    // The row serializer is the elastic output register. It advances only on
    // a successful handshake, so payload and boundary flags remain stable
    // under arbitrary result backpressure. No result-buffer selector remains
    // in the combinational path to the output port.
    assign m_result_valid = !reset && result_valid_reg;
    assign m_result_data = result_serializer_data[0][0 +: ACC_WIDTH];
    assign m_result_tile_last = m_result_valid && result_tile_last_reg;
    assign m_result_last = m_result_valid && result_last_reg;

    wire result_output_fire = m_result_valid && m_result_ready;

    // A command stage aligns the common data bus and last marker with the
    // per-word registered enables instantiated below. bank_readable is asserted
    // from this commit event, never from the earlier interface acceptance.
    always_ff @(posedge clk) begin : track_activation_write_command
        if (reset) begin
            a_write_command_valid <= 1'b0;
            a_write_done <= 1'b0;
        end else begin
            if (loader_launch)
                a_write_done <= 1'b0;
            else if (a_write_last_commit)
                a_write_done <= 1'b1;

            a_write_command_valid <= a_load_fire;
            if (a_load_fire) begin
                a_write_data_stage <= s_activation_data;
                a_write_last_stage <= a_load_last;
            end
        end
    end

    always_ff @(posedge clk) begin : track_weight_write_command
        if (reset) begin
            b_write_command_valid <= 1'b0;
            b_write_done <= 1'b0;
        end else begin
            if (loader_launch)
                b_write_done <= 1'b0;
            else if (b_write_last_commit)
                b_write_done <= 1'b1;

            b_write_command_valid <= b_load_fire;
            if (b_load_fire) begin
                b_write_data_stage <= s_weight_data;
                b_write_last_stage <= b_load_last;
            end
        end
    end

    generate
        genvar tile_bank, tile_half, tile_word;
        for (tile_bank = 0; tile_bank < 2; tile_bank = tile_bank + 1) begin : tile_banks
            for (tile_half = 0; tile_half < 2; tile_half = tile_half + 1) begin : tile_halves
                for (tile_word = 0; tile_word < 8; tile_word = tile_word + 1) begin : tile_words
                    wire a_word_match = a_load_fire &&
                        (loader_bank == tile_bank) &&
                        (a_load_count[3] == tile_half) &&
                        (a_load_count[2:0] == tile_word);
                    wire b_word_match = b_load_fire &&
                        (loader_bank == tile_bank) &&
                        (b_load_count[3] == tile_half) &&
                        (b_load_count[2:0] == tile_word);

                    tile_buffer_word u_activation_word (
                        .clk(clk), .reset(reset),
                        .write_match(a_word_match),
                        .write_data(a_write_data_stage),
                        .read_data(a_tile_buffer[tile_bank][tile_half][tile_word])
                    );
                    tile_buffer_word u_weight_word (
                        .clk(clk), .reset(reset),
                        .write_match(b_word_match),
                        .write_data(b_write_data_stage),
                        .read_data(b_tile_buffer[tile_bank][tile_half][tile_word])
                    );
                end
            end
        end
    endgenerate

    // R0: each candidate has only its local three-bit 8:1 address cone.
    // Candidate data is don't-care when r0_operand_valid is zero and therefore
    // intentionally remains reset-free.
    always_ff @(posedge clk) begin : register_tile_buffer_r0_candidates
        if (issue_valid) begin
            if (FEEDER_IMPL == 3) begin
                a_r0_candidate[0] <= a_read_b0_lo_g0; a_r0_candidate[1] <= a_read_b0_lo_g1;
                a_r0_candidate[2] <= a_read_b0_hi_g0; a_r0_candidate[3] <= a_read_b0_hi_g1;
                a_r0_candidate[4] <= a_read_b1_lo_g0; a_r0_candidate[5] <= a_read_b1_lo_g1;
                a_r0_candidate[6] <= a_read_b1_hi_g0; a_r0_candidate[7] <= a_read_b1_hi_g1;
                b_r0_candidate[0] <= b_read_b0_lo_g0; b_r0_candidate[1] <= b_read_b0_lo_g1;
                b_r0_candidate[2] <= b_read_b0_hi_g0; b_r0_candidate[3] <= b_read_b0_hi_g1;
                b_r0_candidate[4] <= b_read_b1_lo_g0; b_r0_candidate[5] <= b_read_b1_lo_g1;
                b_r0_candidate[6] <= b_read_b1_hi_g0; b_r0_candidate[7] <= b_read_b1_hi_g1;
            end else if (FEEDER_IMPL == 1) begin
                a_r0_candidate[0] <= a_read_b0_lo_f1; a_r0_candidate[1] <= a_read_b0_hi_f1;
                a_r0_candidate[2] <= a_read_b1_lo_f1; a_r0_candidate[3] <= a_read_b1_hi_f1;
                b_r0_candidate[0] <= b_read_b0_lo_f1; b_r0_candidate[1] <= b_read_b0_hi_f1;
                b_r0_candidate[2] <= b_read_b1_lo_f1; b_r0_candidate[3] <= b_read_b1_hi_f1;
            end else begin
                a_r0_candidate[0] <= a_read_b0_lo; a_r0_candidate[1] <= a_read_b0_hi;
                a_r0_candidate[2] <= a_read_b1_lo; a_r0_candidate[3] <= a_read_b1_hi;
                b_r0_candidate[0] <= b_read_b0_lo; b_r0_candidate[1] <= b_read_b0_hi;
                b_r0_candidate[2] <= b_read_b1_lo; b_r0_candidate[3] <= b_read_b1_hi;
            end
        end
    end

    // R1: the bank/half mux sees only R0 registers.  This remains the sole
    // 128-bit packet boundary before lane split and the existing skew pipes.
    always_ff @(posedge clk) begin : register_tile_buffer_r1_packet
        if (r0_operand_valid[0]) begin
            a_read_packet_reg <= a_r1_packet_mux;
            b_read_packet_reg <= b_r1_packet_mux;
        end
    end

    always_ff @(posedge clk) begin : register_tile_buffer_read_metadata
        integer token_lane;
        if (reset) begin
            r0_operand_valid  <= 2'b0;
            r0_first          <= 1'b0;
            r0_last           <= 1'b0;
            for (token_lane = 0; token_lane < ARRAY_SIZE;
                 token_lane = token_lane + 1) begin
                r0_a_lane_active[token_lane] <= 1'b0;
                r0_b_lane_active[token_lane] <= 1'b0;
                a_read_valid_reg[token_lane] <= 2'b0;
                b_read_valid_reg[token_lane] <= 2'b0;
                a_read_first_reg[token_lane] <= 1'b0;
                b_read_first_reg[token_lane] <= 1'b0;
                a_read_last_reg[token_lane]  <= 1'b0;
                b_read_last_reg[token_lane]  <= 1'b0;
            end
        end else begin
            // Issue metadata enters R0 on the same edge as all four candidate
            // words.  Select identifies which candidate belongs to the token.
            r0_candidate_select <= (FEEDER_IMPL == 3) ?
                                   {compute_bank, k_read_addr[3], k_read_addr[2]} :
                                   {1'b0, compute_bank, k_read_addr[3]};
            r0_operand_valid    <= {issue_lane1_valid, issue_valid};
            r0_first            <= issue_first;
            r0_last             <= issue_last && scheduler_last_k;
            for (token_lane = 0; token_lane < ARRAY_SIZE;
                 token_lane = token_lane + 1) begin
                r0_a_lane_active[token_lane] <= token_lane < m_len;
                r0_b_lane_active[token_lane] <= token_lane < n_len;

                // R1 metadata is derived exclusively from the preceding R0
                // token; it cannot move independently of the selected packet.
                a_read_valid_reg[token_lane] <=
                    r0_a_lane_active[token_lane] ? r0_operand_valid : 2'b0;
                b_read_valid_reg[token_lane] <=
                    r0_b_lane_active[token_lane] ? r0_operand_valid : 2'b0;
                // Last must continue through inactive edge lanes because tile
                // completion is deliberately observed at the far-corner PE.
                a_read_first_reg[token_lane] <= r0_first;
                b_read_first_reg[token_lane] <= r0_first;
                a_read_last_reg[token_lane]  <= r0_last;
                b_read_last_reg[token_lane]  <= r0_last;
            end
        end
    end

    generate
        genvar result_read_column;
        for (result_read_column = 0; result_read_column < ARRAY_SIZE;
             result_read_column = result_read_column + 1) begin : result_read_columns
            for (genvar result_read_quarter = 0;
                 result_read_quarter < 4;
                 result_read_quarter = result_read_quarter + 1) begin : quarters
                assign result_sum_read_quarter[result_read_quarter]
                                              [result_read_column] =
                    result_buffer_sum[result_read_quarter][result_read_row[1:0]]
                                     [result_read_column];
                assign result_carry_read_quarter[result_read_quarter]
                                                [result_read_column] =
                    result_buffer_carry[result_read_quarter][result_read_row[1:0]]
                                       [result_read_column];
            end
        end

        genvar edge_index;
        for (edge_index = 0; edge_index < ARRAY_SIZE;
             edge_index = edge_index + 1) begin : edge_skew
            operand_skew_lane #(.DELAY(edge_index)) u_a_skew (
                .clk(clk),
                .reset(reset),
                .data_in(a_read_packet_reg[(edge_index*8) +: 8]),
                .valid_in(a_read_valid_reg[edge_index]),
                .first_in(a_read_first_reg[edge_index]),
                .last_in(a_read_last_reg[edge_index]),
                .data_out(a_edge[edge_index]),
                .valid_out(a_edge_valid[edge_index]),
                .first_out(a_edge_first[edge_index]),
                .last_out(a_edge_last[edge_index])
            );

            operand_skew_lane #(.DELAY(edge_index)) u_b_skew (
                .clk(clk),
                .reset(reset),
                .data_in(b_read_packet_reg[(edge_index*8) +: 8]),
                .valid_in(b_read_valid_reg[edge_index]),
                .first_in(b_read_first_reg[edge_index]),
                .last_in(b_read_last_reg[edge_index]),
                .data_out(b_edge[edge_index]),
                .valid_out(b_edge_valid[edge_index]),
                .first_out(b_edge_first[edge_index]),
                .last_out(b_edge_last[edge_index])
            );
        end

        // Result capture uses fixed PE-to-buffer mappings. Each 32-bit stored
        // word owns a registered local enable, so no row-select signal drives
        // an entire 1024-bit sum/carry row directly.
        genvar capture_index;
        for (capture_index = 0; capture_index < ARRAY_SIZE;
             capture_index = capture_index + 1) begin : result_capture_rows
            localparam [3:0] CAPTURE_ROW_INDEX = capture_index;
            localparam integer CAPTURE_QUARTER = capture_index / 4;
            localparam integer CAPTURE_QUARTER_ROW = capture_index % 4;
            assign capture_oh[capture_index] =
                !reset && (state == S_CAPTURE) &&
                (capture_row == CAPTURE_ROW_INDEX);
            for (genvar capture_column = 0;
                 capture_column < ARRAY_SIZE;
                 capture_column = capture_column + 1) begin : columns
                result_capture_word #(.W(ACC_WIDTH)) u_result_word (
                    .clk(clk),
                    .reset(reset),
                    .capture_enable(capture_oh[capture_index]),
                    .sum_in(array_result_sum[capture_index][capture_column]),
                    .carry_in(array_result_carry[capture_index][capture_column]),
                    .sum_out(result_buffer_sum[CAPTURE_QUARTER]
                                              [CAPTURE_QUARTER_ROW]
                                              [capture_column]),
                    .carry_out(result_buffer_carry[CAPTURE_QUARTER]
                                                  [CAPTURE_QUARTER_ROW]
                                                  [capture_column])
                );
            end
        end

        // The upper final CPA is explicit rather than a three-term inferred
        // expression. low_carry is the CPA cin, not a third adder operand.
        genvar finalizer_column;
        for (finalizer_column = 0; finalizer_column < ARRAY_SIZE;
             finalizer_column = finalizer_column + 1) begin : finalizers
            if (RESULT_IMPL == 2) begin : lower_csel
                // R2 applies the same parallel-prefix structure to the lower
                // half. R1's always-loaded staging is retained.
                result_prefix16 u_lower_cpa (
                    .a(result_row_sum_stage[finalizer_column][15:0]),
                    .b(result_row_carry_stage[finalizer_column][15:0]),
                    .cin(1'b0),
                    .sum(result_row_low_sum_comb[finalizer_column]),
                    .cout(result_row_low_carry_comb[finalizer_column])
                );
            end else begin : lower_inferred
                assign {result_row_low_carry_comb[finalizer_column],
                        result_row_low_sum_comb[finalizer_column]} =
                    {1'b0, result_row_sum_stage[finalizer_column][15:0]} +
                    {1'b0, result_row_carry_stage[finalizer_column][15:0]};
            end
            result_prefix16 u_upper_cpa (
                .a(result_row_upper_sum_stage[finalizer_column]),
                .b(result_row_upper_carry_stage[finalizer_column]),
                .cin(result_row_low_carry_stage[finalizer_column]),
                .sum(result_row_upper_final[finalizer_column]),
                .cout(result_row_upper_cout[finalizer_column])
            );
        end

        // Four local serializer groups keep load ownership spatially bounded.
        // A group's final word shifts from the next group's first word.
        genvar serializer_group, serializer_word;
        for (serializer_group = 0; serializer_group < 4;
             serializer_group = serializer_group + 1) begin : serializers
            for (serializer_word = 0; serializer_word < 4;
                 serializer_word = serializer_word + 1) begin : load_words
                assign result_serializer_load[serializer_group]
                                             [serializer_word*ACC_WIDTH +:
                                              ACC_WIDTH] =
                    result_row_final_stage[serializer_group*4 +
                                           serializer_word];
            end

            if (serializer_group < 3) begin : has_next_group
                result_serializer_group #(.W(ACC_WIDTH), .WORDS(4))
                    u_serializer (
                        .clk(clk),
                        .reset(reset),
                        .prepare_load((state == S_DRAIN_FINALIZE_HI) ||
                                      consume_prefetch),
                        .shift_enable(result_output_fire),
                        .load_data(result_serializer_load[serializer_group]),
                        .shift_tail_in(result_serializer_data
                                           [serializer_group+1][0 +: ACC_WIDTH]),
                        .data_out(result_serializer_data[serializer_group])
                    );
            end else begin : last_group
                result_serializer_group #(.W(ACC_WIDTH), .WORDS(4))
                    u_serializer (
                        .clk(clk),
                        .reset(reset),
                        .prepare_load((state == S_DRAIN_FINALIZE_HI) ||
                                      consume_prefetch),
                        .shift_enable(result_output_fire),
                        .load_data(result_serializer_load[serializer_group]),
                        .shift_tail_in({ACC_WIDTH{1'b0}}),
                        .data_out(result_serializer_data[serializer_group])
                    );
            end
        end

        if (ARRAY_SIZE != 16) begin : invalid_array_size
            initial $error("tpu_stream_top requires ARRAY_SIZE=16 for 128-bit streams");
        end
        if (ACC_WIDTH != 32) begin : invalid_acc_width
            initial $error("tpu_stream_top E3 result finalizer requires ACC_WIDTH=32");
        end
    endgenerate

    // Result-read R0: each quarter contains exactly one 4:1 selector per bit.
    // Capture only for a row-read command; R1 consumes it on the next edge.
    always_ff @(posedge clk) begin : register_result_quarter_candidates
        integer candidate_quarter, candidate_column;
        if (result_r0_load_cmd[0])
            result_quarter_select_r0 <= result_read_row[3:2];
        for (candidate_quarter = 0; candidate_quarter < 4;
             candidate_quarter = candidate_quarter + 1) begin
            for (candidate_column = 0; candidate_column < ARRAY_SIZE;
                 candidate_column = candidate_column + 1) begin
                if (result_r0_load_cmd[candidate_column]) begin
                    result_sum_candidate_quarter[candidate_quarter]
                                                [candidate_column] <=
                        result_sum_read_quarter[candidate_quarter]
                                               [candidate_column];
                    result_carry_candidate_quarter[candidate_quarter]
                                                  [candidate_column] <=
                        result_carry_read_quarter[candidate_quarter]
                                                 [candidate_column];
                end
            end
        end
    end

    // Result-read R1: only a registered 4:1 quarter selection remains. The
    // DRAIN_LOAD/ARM schedule guarantees the selected row has crossed both
    // boundaries before FINALIZE_LO consumes it.
    always_ff @(posedge clk) begin : register_selected_result_row
        integer selected_column;
        for (selected_column = 0; selected_column < ARRAY_SIZE;
             selected_column = selected_column + 1) begin
            if (result_r1_select_cmd[selected_column])
              case (result_quarter_select_r0)
                    2'd0: begin
                        result_row_sum_stage[selected_column] <=
                            result_sum_candidate_quarter[0][selected_column];
                        result_row_carry_stage[selected_column] <=
                            result_carry_candidate_quarter[0][selected_column];
                    end
                    2'd1: begin
                        result_row_sum_stage[selected_column] <=
                            result_sum_candidate_quarter[1][selected_column];
                        result_row_carry_stage[selected_column] <=
                            result_carry_candidate_quarter[1][selected_column];
                    end
                    2'd2: begin
                        result_row_sum_stage[selected_column] <=
                            result_sum_candidate_quarter[2][selected_column];
                        result_row_carry_stage[selected_column] <=
                            result_carry_candidate_quarter[2][selected_column];
                    end
                    default: begin
                        result_row_sum_stage[selected_column] <=
                            result_sum_candidate_quarter[3][selected_column];
                        result_row_carry_stage[selected_column] <=
                            result_carry_candidate_quarter[3][selected_column];
                    end
              endcase
        end
    end

    generate begin : result_finalizer_pipeline
        always_ff @(posedge clk) begin : register_finalized_result_row
            integer c;
            for (c = 0; c < ARRAY_SIZE; c = c + 1)
                if (result_finalize_hi_cmd[c])
                    result_row_final_stage[c] <=
                        {result_row_upper_final[c],result_row_low_stage[c]};
        end
        always_ff @(posedge clk) begin : update_result_row_payload
            integer c;
            for (c = 0; c < ARRAY_SIZE; c = c + 1)
                if ((RESULT_IMPL != 0) || result_finalize_lo_cmd[c]) begin
                    {result_row_low_carry_stage[c],result_row_low_stage[c]} <=
                        {result_row_low_carry_comb[c],result_row_low_sum_comb[c]};
                    result_row_upper_sum_stage[c] <= result_row_sum_stage[c][31:16];
                    result_row_upper_carry_stage[c] <= result_row_carry_stage[c][31:16];
                end
        end
    end endgenerate

    // Register the event that enters each result phase. Wide payload banks
    // consume only the corresponding local command bit on the following edge.
    // A finalized row stays in final_stage until the serializer accepts it.
    // Prefetch starts only when COMMIT transfers ownership of the preceding row.
    wire start_prefetch = (state == S_DRAIN_COMMIT) &&
                          (drain_row != last_row_index);
    wire consume_prefetch = prefetch_ready &&
        (((state == S_DRAIN) && result_output_fire &&
          !m_result_tile_last && (drain_col == last_col_index)) ||
         (state == S_WAIT_ROW));
    wire launch_next_result_row = (state == S_CAPTURE_FLUSH) || start_prefetch;
    always_ff @(posedge clk) begin : prefetch_ownership
        if (reset) begin
            prefetch_phase <= 0;
            prefetch_ready <= 0;
            prefetch_row <= 0;
        end else begin
            if (consume_prefetch) prefetch_ready <= 0;
            if (start_prefetch) begin
                prefetch_row <= drain_row + 1'b1;
                prefetch_phase <= 1;
            end else if (prefetch_phase != 0) begin
                if (prefetch_phase == 4) begin
                    prefetch_phase <= 0;
                    prefetch_ready <= 1;
                end else prefetch_phase <= prefetch_phase + 1'b1;
            end
        end
    end
    always_ff @(posedge clk) begin : register_result_phase_commands
        if (reset) begin
            result_r0_load_cmd     <= '0;
            result_r1_select_cmd   <= '0;
            result_finalize_lo_cmd <= '0;
            result_finalize_hi_cmd <= '0;
        end else begin
            result_r0_load_cmd <=
                {ARRAY_SIZE{launch_next_result_row}};
            result_r1_select_cmd <=
                {ARRAY_SIZE{((state == S_DRAIN_LOAD) && result_bank_full) ||
                            (prefetch_phase == 1)}};
            result_finalize_lo_cmd <=
                {ARRAY_SIZE{((state == S_DRAIN_ARM) && result_bank_full) ||
                            (prefetch_phase == 2)}};
            result_finalize_hi_cmd <=
                {ARRAY_SIZE{((state == S_DRAIN_FINALIZE_LO) &&
                             result_bank_full) || (prefetch_phase == 3)}};
        end
    end

    systolic_array #(
        .N(ARRAY_SIZE),
        .ACC_WIDTH(ACC_WIDTH),
        .USE_CSA_ACCUM(USE_CSA_ACCUM)
    ) u_array (
        .clk(clk),
        .reset(reset),
        .precision_load(cfg_valid && cfg_ready),
        .precision_mode(precision_mode),
        .activation_in(a_edge),
        .weight_in(b_edge),
        .activation_valid(a_edge_valid),
        .weight_valid(b_edge_valid),
        .activation_first(a_edge_first),
        .weight_first(b_edge_first),
        .activation_last(a_edge_last),
        .weight_last(b_edge_last),
        .result_sum(array_result_sum),
        .result_carry(array_result_carry),
        .tile_done(array_tile_done)
    );

    always @(posedge clk) begin
        if (reset) begin
            state            <= S_IDLE;
            last_row_index <= 0;
            last_col_index <= 0;
            penultimate_col_index <= 0;
            last_m_tile <= 0;
            last_n_tile <= 0;
            row_is_last <= 0;
            cfg_m_reg        <= 16'b0;
            cfg_n_reg        <= 16'b0;
            cfg_k_reg        <= 16'b0;
            precision_reg    <= 1'b0;
            m_base           <= 16'b0;
            n_base           <= 16'b0;
            k_base           <= 16'b0;
            m_remaining      <= 16'b0;
            n_remaining      <= 16'b0;
            k_remaining      <= 16'b0;
            next_k_remaining <= 16'b0;
            m_len            <= 5'b0;
            n_len            <= 5'b0;
            k_len            <= 5'b0;
            next_k_len       <= 5'b0;
            k_steps          <= 5'b0;
            first_k_tile     <= 1'b0;
            descriptor_last_k_tile <= 1'b0;
            descriptor_last_packet <= 4'b0;
            bank_readable    <= 2'b0;
            compute_bank     <= 1'b0;
            loader_active    <= 1'b0;
            loader_bank      <= 1'b0;
            load_steps       <= 5'b0;
            a_load_count     <= 5'b0;
            b_load_count     <= 5'b0;
            a_load_done      <= 1'b0;
            b_load_done      <= 1'b0;
            k_read_addr       <= 4'b0;
            issue_active      <= 1'b0;
            capture_row      <= 4'b0;
            drain_row        <= 4'b0;
            drain_col        <= 4'b0;
            result_bank_full <= 1'b0;
            result_valid_reg <= 1'b0;
            result_tile_last_reg <= 1'b0;
            result_last_reg  <= 1'b0;
        end else begin
            // Independent A/B progress for writes performed by the dedicated
            // banked storage blocks above.
            if (a_load_fire) begin
                if (a_load_last)
                    a_load_done <= 1'b1;
                else
                    a_load_count <= a_load_count + 1'b1;
            end

            if (b_load_fire) begin
                if (b_load_last)
                    b_load_done <= 1'b1;
                else
                    b_load_count <= b_load_count + 1'b1;
            end

            if (loader_complete_now) begin
                loader_active <= 1'b0;
                bank_readable[loader_bank] <= 1'b1;
            end

            // Release storage as soon as the final read has been isolated in
            // R0.  The array continues computing independently until the
            // final C-tile token produces bank_compute_done_event.
            if (bank_read_done_event)
                bank_readable[compute_bank] <= 1'b0;

            case (state)
                S_IDLE: begin
                    result_bank_full <= 1'b0;
                    result_valid_reg <= 1'b0;
                    if (cfg_valid && cfg_ready) begin
                        cfg_m_reg     <= cfg_m;
                        cfg_n_reg     <= cfg_n;
                        cfg_k_reg     <= cfg_k;
                        precision_reg <= precision_mode;
                        m_base        <= 16'b0;
                        n_base        <= 16'b0;
                        k_base        <= 16'b0;
                        m_remaining   <= cfg_m;
                        n_remaining   <= cfg_n;
                        k_remaining   <= cfg_k;
                        first_k_tile  <= 1'b1;
                        bank_readable <= 2'b0;
                        compute_bank  <= 1'b0;
                        loader_active <= 1'b0;

                        if ((cfg_m == 0) || (cfg_n == 0) || (cfg_k == 0)) begin
                            state <= S_IDLE;
                        end else begin
                            state <= S_PREP_LEN;
                        end
                    end
                end

                // Scheduler pipeline stage 1: clamp registered remaining
                // dimensions. There is no dimension-minus-base arithmetic in
                // this state.
                S_PREP_LEN: begin
                    last_m_tile <= (m_remaining <= 16'd16);
                    last_n_tile <= (n_remaining <= 16'd16);
                    m_len <= clamp_tile_len(m_remaining);
                    n_len <= clamp_tile_len(n_remaining);
                    k_len <= clamp_tile_len(k_remaining);
                    state <= S_PREP_COUNT;
                end

                // Scheduler pipeline stage 2: derive packet count from the
                // registered K tile length, then launch the initial loader.
                S_PREP_COUNT: begin
                    last_row_index <= m_len[3:0] - 4'd1;
                    last_col_index <= n_len[3:0] - 4'd1;
                    penultimate_col_index <= n_len[3:0] - 4'd2;
                    k_steps      <= packet_count(k_len, precision_reg);
                    if (SCHED_IMPL == 2) begin
                        descriptor_last_k_tile <= (k_remaining <= 16'd16);
                        descriptor_last_packet <= 4'(packet_count(k_len, precision_reg)) - 4'd1;
                    end
                    load_steps   <= packet_count(k_len, precision_reg);
                    loader_active <= 1'b1;
                    loader_bank  <= compute_bank;
                    a_load_count <= 5'b0;
                    b_load_count <= 5'b0;
                    a_load_done  <= 1'b0;
                    b_load_done  <= 1'b0;
                    state        <= S_WAIT_BANK;
                end

                S_WAIT_BANK: begin
                    if (bank_readable[compute_bank])
                        state <= S_START;
                end

                S_START: begin
                    k_read_addr <= 4'b0;

                    // Prepare the following K tile in short stages before
                    // current packet issue begins. Its loader then overlaps
                    // the current compute phase as before.
                    if (!last_k_tile) begin
                        // Non-final tiles are exactly 16 elements, so this is
                        // a constant decrement rather than a variable adder.
                        next_k_remaining <= k_remaining - 16'd16;
                        issue_active <= 1'b0;
                        state <= S_PRELOAD_LEN;
                    end else begin
                        issue_active <= 1'b1;
                        state <= S_COMPUTE;
                    end
                end

                S_PRELOAD_LEN: begin
                    next_k_len <= clamp_tile_len(next_k_remaining);
                    state <= S_PRELOAD_COUNT;
                end

                S_PRELOAD_COUNT: begin
                    load_steps    <= packet_count(next_k_len, precision_reg);
                    loader_active <= 1'b1;
                    loader_bank   <= ~compute_bank;
                    a_load_count  <= 5'b0;
                    b_load_count  <= 5'b0;
                    a_load_done   <= 1'b0;
                    b_load_done   <= 1'b0;
                    issue_active  <= 1'b1;
                    state         <= S_COMPUTE;
                end

                S_COMPUTE: begin
                    if (issue_active) begin
                        if (k_read_addr == scheduler_last_packet)
                            issue_active <= 1'b0;
                        else
                            k_read_addr <= k_read_addr + 1'b1;
                    end

                    if ((last_k_tile && bank_compute_done_event) ||
                        (!last_k_tile && bank_read_done_event)) begin
                        if (last_k_tile) begin
                            capture_row <= 4'b0;
                            state <= S_CAPTURE;
                        end else begin
                            if (SCHED_IMPL == 0)
                                k_base <= k_base + 16'd16;
                            else
                                first_k_tile <= 1'b0;
                            k_remaining <= next_k_remaining;
                            k_len       <= next_k_len;
                            k_steps     <= load_steps;
                            if (SCHED_IMPL == 2) begin
                                descriptor_last_k_tile <= (next_k_remaining <= 16'd16);
                                descriptor_last_packet <= load_steps[3:0] - 4'd1;
                            end
                            compute_bank <= ~compute_bank;
                            state <= S_WAIT_BANK;
                        end
                    end
                end

                S_CAPTURE: begin
                    // Tail M tiles capture only their architecturally valid
                    // rows; the fixed row mapping itself is generated above.
                    if (capture_row == last_row_index) begin
                        // Per-word local enables commit this row one edge
                        // later. Ownership changes only after that event.
                        state <= S_CAPTURE_FLUSH;
                    end else begin
                        capture_row <= capture_row + 1'b1;
                    end
                end

                S_CAPTURE_FLUSH: begin
                    result_bank_full <= 1'b1;
                    drain_row <= 4'b0;
                    drain_col <= 4'b0;
                    state <= S_DRAIN_LOAD;
                end

                S_DRAIN_LOAD: begin
                    row_is_last <= (drain_row == last_row_index);
                    // R0 captures four bank-local 4:1 candidates on this cycle;
                    // R1 completes the registered 4:1 quarter selection in ARM.
                    if (result_bank_full) begin
                        state <= S_DRAIN_ARM;
                    end
                end

                S_DRAIN_ARM: begin
                    // The row-select pulse is consumed on this edge.  Keep
                    // output invalid while the selected CSA rows settle in
                    // their dedicated staging registers.
                    if (result_bank_full) begin
                        state <= S_DRAIN_FINALIZE_LO;
                    end
                end

                S_DRAIN_FINALIZE_LO: begin
                    if (result_bank_full)
                        state <= S_DRAIN_FINALIZE_HI;
                end

                S_DRAIN_FINALIZE_HI: begin
                    // Capture the finalized upper half. COMMIT consumes the
                    // completed registered row on the next edge.
                    if (result_bank_full) begin
                        state <= S_DRAIN_COMMIT;
                    end
                end

                S_DRAIN_COMMIT: begin
                    if (result_bank_full) begin
                        row_is_last <= (drain_row == last_row_index);
                        result_valid_reg <= 1'b1;
                        result_tile_last_reg <=
                            (drain_row == last_row_index) && (last_col_index == 0);
                        result_last_reg <=
                            (drain_row == last_row_index) && (last_col_index == 0) &&
                            last_m_tile && last_n_tile;
                        state <= S_DRAIN;
                    end
                end

                S_DRAIN: begin
                    if (m_result_valid && m_result_ready) begin
                        if (m_result_tile_last) begin
                            result_bank_full <= 1'b0;
                            result_valid_reg <= 1'b0;
                            result_tile_last_reg <= 1'b0;
                            result_last_reg <= 1'b0;
                            state <= S_ADVANCE_TILE;
                        end else if (drain_col == last_col_index) begin
                            drain_col <= 4'b0;
                            drain_row <= drain_row + 1'b1;
                            result_valid_reg <= 1'b0;
                            result_tile_last_reg <= 1'b0;
                            result_last_reg <= 1'b0;
                            state <= prefetch_ready ? S_DRAIN_COMMIT : S_WAIT_ROW;
                        end else begin
                            drain_col <= drain_col + 1'b1;
                            result_tile_last_reg <=
                                row_is_last &&
                                (drain_col == penultimate_col_index);
                            result_last_reg <=
                                row_is_last &&
                                (drain_col == penultimate_col_index) &&
                                last_m_tile && last_n_tile;
                        end
                    end
                end

                S_WAIT_ROW: begin
                    if (prefetch_ready) state <= S_DRAIN_COMMIT;
                end

                S_ADVANCE_TILE: begin
                    if (last_m_tile && last_n_tile) begin
                        state <= S_IDLE;
                    end else begin
                        if (!last_n_tile) begin
                            n_base <= n_base + 16'd16;
                            n_remaining <= n_remaining - 16'd16;
                        end else begin
                            n_base <= 16'b0;
                            n_remaining <= cfg_n_reg;
                            m_base <= m_base + 16'd16;
                            m_remaining <= m_remaining - 16'd16;
                        end

                        k_base        <= 16'b0;
                        first_k_tile  <= 1'b1;
                        k_remaining   <= cfg_k_reg;
                        bank_readable <= 2'b0;
                        compute_bank  <= 1'b0;
                        loader_active <= 1'b0;
                        state <= S_PREP_LEN;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    // Structural/ownership checks. Functional packet and result counts are
    // checked in the testbench at the external handshakes.
    always @(posedge clk) begin : structural_assertions
        if (!reset) begin
            if (prefetch_ready || state == S_DRAIN_COMMIT) begin
                for (integer c = 0; c < ARRAY_SIZE; c = c + 1)
                    if (c < int'(n_len))
                        assert (result_row_final_stage[c] ==
                                (result_row_sum_stage[c] + result_row_carry_stage[c]))
                            else $error("result CPA pipeline lost a byte or carry");
            end
            if (start_prefetch)
                assert (!prefetch_ready && prefetch_phase == 0)
                    else $error("prefetch overwrote an unconsumed row");
            if (consume_prefetch)
                assert (prefetch_phase == 0 && prefetch_ready)
                    else $error("serializer consumed incomplete prefetch");
            if (prefetch_phase != 0)
                assert (result_bank_full && prefetch_row <= last_row_index)
                    else $error("prefetch outside owned result bank");
            if (bank_compute_done_event)
                assert (state == S_COMPUTE && last_k_tile && !issue_active)
                    else $error("C tile retired before final issue completed");
            if (state == S_START)
                assert (bank_readable[compute_bank])
                    else $error("compute started before bank became readable");

            if ((state == S_PREP_LEN) || (state == S_PREP_COUNT)) begin
                assert ((m_remaining > 0) && (n_remaining > 0) &&
                        (k_remaining > 0))
                    else $error("scheduler prepared an empty active tile");
            end

            if (state == S_PREP_COUNT) begin
                assert ((m_len > 0) && (m_len <= 16) &&
                        (n_len > 0) && (n_len <= 16) &&
                        (k_len > 0) && (k_len <= 16))
                    else $error("prepared tile length out of range");
            end

            if ((state == S_PRELOAD_LEN) ||
                (state == S_PRELOAD_COUNT)) begin
                assert ((next_k_remaining > 0) &&
                        (next_k_remaining < k_remaining))
                    else $error("next K remaining count did not advance");
            end

            if (state == S_PRELOAD_COUNT) begin
                assert ((next_k_len > 0) && (next_k_len <= 16))
                    else $error("next K tile length out of range");
                assert (!loader_active)
                    else $error("next K loader started before prior load completed");
            end

            if (issue_valid) begin
                assert (bank_readable[compute_bank])
                    else $error("issued a packet after buffer read ownership ended");
                assert (k_steps > 0)
                    else $error("issued a packet for an empty K tile");
                assert (int'(k_read_addr) < K_PACKET_DEPTH)
                    else $error("compute buffer read address out of range");
            end

            if (bank_read_done_event)
                assert (bank_readable[compute_bank])
                    else $error("bank read-done repeated after ownership release");

            if (loader_active) begin
                assert (!bank_readable[loader_bank])
                    else $error("loader attempted to overwrite a readable bank");
                assert (load_steps > 0 && int'(load_steps) <= K_PACKET_DEPTH)
                    else $error("loader tile size out of range");
                assert (int'(a_load_count) < K_PACKET_DEPTH &&
                        int'(b_load_count) < K_PACKET_DEPTH)
                    else $error("loader buffer address out of range");
            end

            // Storage may be reused while old operands are still computing,
            // but never while the read issuer can still reference that bank.
            if (loader_active && issue_active)
                assert (loader_bank != compute_bank)
                    else $error("loader attempted to overwrite active read bank");

            if (a_write_last_commit)
                assert (a_load_done)
                    else $error("A bank committed last word before acceptance completed");
            if (b_write_last_commit)
                assert (b_load_done)
                    else $error("B bank committed last word before acceptance completed");
            if (loader_complete_now)
                assert ((a_write_done || a_write_last_commit) &&
                        (b_write_done || b_write_last_commit))
                    else $error("bank became readable before both physical writes committed");

            if (issue_valid && precision_reg &&
                (issue_scalar_base + 5'd1 >= k_len))
                assert (!issue_lane1_valid)
                    else $error("INT4 odd-K high nibble was marked valid");

            // Each pipeline boundary carries one indivisible issued-packet
            // token.  In particular, an INT4 high nibble can never survive
            // without the low nibble, and first/last cannot exist on bubbles.
            if (r0_operand_valid[1])
                assert (r0_operand_valid[0])
                    else $error("R0 INT4 lane 1 valid without lane 0");
            if (r0_first || r0_last)
                assert (r0_operand_valid[0])
                    else $error("R0 boundary marker detached from packet");
            if (a_read_valid_reg[0][1] || b_read_valid_reg[0][1])
                assert (a_read_valid_reg[0][0] &&
                        b_read_valid_reg[0][0])
                    else $error("R1 INT4 lane 1 valid without lane 0");
            if (a_read_first_reg[0] || a_read_last_reg[0])
                assert (a_read_valid_reg[0][0] &&
                        b_read_valid_reg[0][0])
                    else $error("R1 boundary marker detached from packet");

            if (bank_compute_done_event)
                assert (!bank_readable[compute_bank])
                    else $error("array completed before final bank read retired");

            assert ($onehot0(capture_oh))
                else $error("multiple result rows enabled for capture");

            if ((state == S_DRAIN_LOAD) || (state == S_DRAIN_ARM) ||
                (state == S_DRAIN_FINALIZE_LO) ||
                (state == S_DRAIN_FINALIZE_HI) ||
                (state == S_DRAIN_COMMIT)) begin
                assert (result_bank_full)
                    else $error("result row loaded before result bank became full");
                assert ({1'b0,drain_row} < m_len)
                    else $error("result drain row out of range");
            end

            if (state == S_DRAIN_ARM)
                assert (result_quarter_select_r0 == drain_row[3:2])
                    else $error("result R0 quarter selector detached from row data");

        end
    end
`endif

endmodule

`default_nettype wire
