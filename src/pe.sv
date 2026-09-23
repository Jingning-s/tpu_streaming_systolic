`default_nettype none
`timescale 1ns/1ps

// E3 output-stationary PE: M0 operands, M1 Baugh-Wooley paired 4:2,
// M2 product CPA, then direct precision formatting into accumulator state.
module pe #(
    parameter integer ACC_WIDTH = 32,
    parameter integer USE_CSA_ACCUM = 0
) (
    input wire clk, input wire reset, input wire precision_mode,
    input wire [7:0] activation_in, input wire [7:0] weight_in,
    input wire [1:0] activation_valid_in, input wire [1:0] weight_valid_in,
    input wire activation_first_in, input wire weight_first_in,
    input wire activation_last_in, input wire weight_last_in,
    output reg [7:0] activation_out, output reg [7:0] weight_out,
    output reg [1:0] activation_valid_out, output reg [1:0] weight_valid_out,
    output reg activation_first_out, output reg weight_first_out,
    output reg activation_last_out, output reg weight_last_out,
    output reg precision_out,
    output wire signed [ACC_WIDTH-1:0] accumulator_sum,
    output wire signed [ACC_WIDTH-1:0] accumulator_carry,
    output wire tile_done
);
    reg [7:0] m0_activation, m0_weight;
    reg m0_mode, m0_valid0, m0_valid1, m0_init, m0_last;
    reg signed [17:0] m1_int8_row0, m1_int8_row1;
    reg signed [17:0] m1_int8_row2, m1_int8_row3;
    reg [7:0] m1_int4_sum0, m1_int4_carry0;
    reg [7:0] m1_int4_sum1, m1_int4_carry1;
    reg m1_mode, m1_valid0, m1_valid1, m1_init, m1_last;
    reg signed [17:0] m2_int8_sum, m2_int8_carry;
    reg signed [7:0] m2_product4_0, m2_product4_1;
    reg m2_int8_work, m2_int4_work0, m2_int4_work1;
    reg m2_init, m2_last;

    // Exact signed 8x8 Baugh-Wooley matrix. pp0 includes -2^16 in its
    // two upper bits, so the signed sum of the 18-bit rows is the product.
    wire [17:0] pp0 = {2'b11,1'b1,6'b0,1'b1,
        ~(m0_activation[0]&m0_weight[7]),
        m0_activation[0]&m0_weight[6],m0_activation[0]&m0_weight[5],
        m0_activation[0]&m0_weight[4],m0_activation[0]&m0_weight[3],
        m0_activation[0]&m0_weight[2],m0_activation[0]&m0_weight[1],
        m0_activation[0]&m0_weight[0]};
    wire [17:0] pp1 = {2'b0,7'b0,~(m0_activation[1]&m0_weight[7]),
        m0_activation[1]&m0_weight[6],m0_activation[1]&m0_weight[5],
        m0_activation[1]&m0_weight[4],m0_activation[1]&m0_weight[3],
        m0_activation[1]&m0_weight[2],m0_activation[1]&m0_weight[1],
        m0_activation[1]&m0_weight[0],1'b0};
    wire [17:0] pp2 = {2'b0,6'b0,~(m0_activation[2]&m0_weight[7]),
        m0_activation[2]&m0_weight[6],m0_activation[2]&m0_weight[5],
        m0_activation[2]&m0_weight[4],m0_activation[2]&m0_weight[3],
        m0_activation[2]&m0_weight[2],m0_activation[2]&m0_weight[1],
        m0_activation[2]&m0_weight[0],2'b0};
    wire [17:0] pp3 = {2'b0,5'b0,~(m0_activation[3]&m0_weight[7]),
        m0_activation[3]&m0_weight[6],m0_activation[3]&m0_weight[5],
        m0_activation[3]&m0_weight[4],m0_activation[3]&m0_weight[3],
        m0_activation[3]&m0_weight[2],m0_activation[3]&m0_weight[1],
        m0_activation[3]&m0_weight[0],3'b0};
    wire [17:0] pp4 = {2'b0,4'b0,~(m0_activation[4]&m0_weight[7]),
        m0_activation[4]&m0_weight[6],m0_activation[4]&m0_weight[5],
        m0_activation[4]&m0_weight[4],m0_activation[4]&m0_weight[3],
        m0_activation[4]&m0_weight[2],m0_activation[4]&m0_weight[1],
        m0_activation[4]&m0_weight[0],4'b0};
    wire [17:0] pp5 = {2'b0,3'b0,~(m0_activation[5]&m0_weight[7]),
        m0_activation[5]&m0_weight[6],m0_activation[5]&m0_weight[5],
        m0_activation[5]&m0_weight[4],m0_activation[5]&m0_weight[3],
        m0_activation[5]&m0_weight[2],m0_activation[5]&m0_weight[1],
        m0_activation[5]&m0_weight[0],5'b0};
    wire [17:0] pp6 = {2'b0,2'b0,~(m0_activation[6]&m0_weight[7]),
        m0_activation[6]&m0_weight[6],m0_activation[6]&m0_weight[5],
        m0_activation[6]&m0_weight[4],m0_activation[6]&m0_weight[3],
        m0_activation[6]&m0_weight[2],m0_activation[6]&m0_weight[1],
        m0_activation[6]&m0_weight[0],6'b0};
    wire [17:0] pp7 = {2'b0,1'b0,m0_activation[7]&m0_weight[7],
        ~(m0_activation[7]&m0_weight[6]),~(m0_activation[7]&m0_weight[5]),
        ~(m0_activation[7]&m0_weight[4]),~(m0_activation[7]&m0_weight[3]),
        ~(m0_activation[7]&m0_weight[2]),~(m0_activation[7]&m0_weight[1]),
        ~(m0_activation[7]&m0_weight[0]),7'b0};

    // E3 M1: two direct paired 4:2 compressors.
    wire [17:0] lo_s0 = pp0 ^ pp1 ^ pp2;
    wire [17:0] lo_c0 = ((pp0&pp1)|(pp0&pp2)|(pp1&pp2)) << 1;
    wire [17:0] m1_row0_next = lo_s0 ^ lo_c0 ^ pp3;
    wire [17:0] m1_row1_next =
        ((lo_s0&lo_c0)|(lo_s0&pp3)|(lo_c0&pp3)) << 1;
    wire [17:0] hi_s0 = pp4 ^ pp5 ^ pp6;
    wire [17:0] hi_c0 = ((pp4&pp5)|(pp4&pp6)|(pp5&pp6)) << 1;
    wire [17:0] m1_row2_next = hi_s0 ^ hi_c0 ^ pp7;
    wire [17:0] m1_row3_next =
        ((hi_s0&hi_c0)|(hi_s0&pp7)|(hi_c0&pp7)) << 1;

    // E3 M2: four registered rows become exactly two; still no CPA.
    wire [17:0] m2_s0 = m1_int8_row0 ^ m1_int8_row1 ^ m1_int8_row2;
    wire [17:0] m2_c0 = ((m1_int8_row0&m1_int8_row1)|
        (m1_int8_row0&m1_int8_row2)|(m1_int8_row1&m1_int8_row2)) << 1;
    wire [17:0] m2_sum_next = m2_s0 ^ m2_c0 ^ m1_int8_row3;
    wire [17:0] m2_carry_next =
        ((m2_s0&m2_c0)|(m2_s0&m1_int8_row3)|
         (m2_c0&m1_int8_row3)) << 1;

    // Two exact signed 4x4 Baugh-Wooley matrices.  The correction bits at
    // weights 4 and 7 occupy otherwise-zero positions in row0, so folding
    // them into that row leaves exactly four modulo-2^8 rows per lane.
    // M1 reduces each matrix to sum/carry with a balanced paired 4:2; it does
    // not contain a carry-propagate adder.
    wire [7:0] i4_row0_0 = {1'b1,2'b0,1'b1,
        ~(m0_activation[0]&m0_weight[3]),
        m0_activation[0]&m0_weight[2],
        m0_activation[0]&m0_weight[1],
        m0_activation[0]&m0_weight[0]};
    wire [7:0] i4_row1_0 = {3'b0,~(m0_activation[1]&m0_weight[3]),
        m0_activation[1]&m0_weight[2],
        m0_activation[1]&m0_weight[1],
        m0_activation[1]&m0_weight[0],1'b0};
    wire [7:0] i4_row2_0 = {2'b0,~(m0_activation[2]&m0_weight[3]),
        m0_activation[2]&m0_weight[2],
        m0_activation[2]&m0_weight[1],
        m0_activation[2]&m0_weight[0],2'b0};
    wire [7:0] i4_row3_0 = {1'b0,m0_activation[3]&m0_weight[3],
        ~(m0_activation[3]&m0_weight[2]),
        ~(m0_activation[3]&m0_weight[1]),
        ~(m0_activation[3]&m0_weight[0]),3'b0};
    wire [7:0] i4_s0_0 = i4_row0_0 ^ i4_row1_0 ^ i4_row2_0;
    wire [7:0] i4_c0_0 = ((i4_row0_0&i4_row1_0)|
        (i4_row0_0&i4_row2_0)|(i4_row1_0&i4_row2_0)) << 1;
    wire [7:0] i4_sum0_next = i4_s0_0 ^ i4_c0_0 ^ i4_row3_0;
    wire [7:0] i4_carry0_next = ((i4_s0_0&i4_c0_0)|
        (i4_s0_0&i4_row3_0)|(i4_c0_0&i4_row3_0)) << 1;

    wire [7:0] i4_row0_1 = {1'b1,2'b0,1'b1,
        ~(m0_activation[4]&m0_weight[7]),
        m0_activation[4]&m0_weight[6],
        m0_activation[4]&m0_weight[5],
        m0_activation[4]&m0_weight[4]};
    wire [7:0] i4_row1_1 = {3'b0,~(m0_activation[5]&m0_weight[7]),
        m0_activation[5]&m0_weight[6],
        m0_activation[5]&m0_weight[5],
        m0_activation[5]&m0_weight[4],1'b0};
    wire [7:0] i4_row2_1 = {2'b0,~(m0_activation[6]&m0_weight[7]),
        m0_activation[6]&m0_weight[6],
        m0_activation[6]&m0_weight[5],
        m0_activation[6]&m0_weight[4],2'b0};
    wire [7:0] i4_row3_1 = {1'b0,m0_activation[7]&m0_weight[7],
        ~(m0_activation[7]&m0_weight[6]),
        ~(m0_activation[7]&m0_weight[5]),
        ~(m0_activation[7]&m0_weight[4]),3'b0};
    wire [7:0] i4_s0_1 = i4_row0_1 ^ i4_row1_1 ^ i4_row2_1;
    wire [7:0] i4_c0_1 = ((i4_row0_1&i4_row1_1)|
        (i4_row0_1&i4_row2_1)|(i4_row1_1&i4_row2_1)) << 1;
    wire [7:0] i4_sum1_next = i4_s0_1 ^ i4_c0_1 ^ i4_row3_1;
    wire [7:0] i4_carry1_next = ((i4_s0_1&i4_c0_1)|
        (i4_s0_1&i4_row3_1)|(i4_c0_1&i4_row3_1)) << 1;

    // M2 owns the two independent INT4 CPAs. The products remain separate and
    // become the two input rows of the accumulator compressor.
    wire [7:0] i4_product0_next = m1_int4_sum0 + m1_int4_carry0;
    wire [7:0] i4_product1_next = m1_int4_sum1 + m1_int4_carry1;

    // INT8 and INT4 work are mode-exclusive. Formatting is combinational from
    // the M2 registers into the accumulator, eliminating the former D-stage
    // 64-bit payload and token register boundary.
    wire [ACC_WIDTH-1:0] int8_sum_extended =
        {{(ACC_WIDTH-18){m2_int8_sum[17]}},m2_int8_sum};
    wire [ACC_WIDTH-1:0] int8_carry_extended =
        {{(ACC_WIDTH-18){m2_int8_carry[17]}},m2_int8_carry};
    wire [ACC_WIDTH-1:0] int4_product0_extended =
        {{(ACC_WIDTH-8){m2_product4_0[7]}},m2_product4_0};
    wire [ACC_WIDTH-1:0] int4_product1_extended =
        {{(ACC_WIDTH-8){m2_product4_1[7]}},m2_product4_1};
    wire [ACC_WIDTH-1:0] delta_sum_next =
        (int8_sum_extended & {ACC_WIDTH{m2_int8_work}}) |
        (int4_product0_extended & {ACC_WIDTH{m2_int4_work0}});
    wire [ACC_WIDTH-1:0] delta_carry_next =
        (int8_carry_extended & {ACC_WIDTH{m2_int8_work}}) |
        (int4_product1_extended & {ACC_WIDTH{m2_int4_work1}});
    wire delta_valid = m2_int8_work || m2_int4_work0 || m2_int4_work1;
    wire delta_init = m2_init;
    wire delta_last = m2_last;

    // Payload enables hold unused arithmetic branches and bubble data.
    // Forwarding uses each operand's own valid, never the paired MAC valid.
    // Control tokens below continue advancing even through inactive tail PEs.
    always_ff @(posedge clk) begin : datapath
        if (|activation_valid_in) activation_out<=activation_in;
        if (|weight_valid_in) weight_out<=weight_in;
        precision_out<=precision_mode;
        if (activation_valid_in[0] && weight_valid_in[0]) begin
            m0_activation<=activation_in; m0_weight<=weight_in;
        end
        m0_mode<=precision_mode;
        if (!m0_mode && m0_valid0) begin
            m1_int8_row0<=m1_row0_next; m1_int8_row1<=m1_row1_next;
            m1_int8_row2<=m1_row2_next; m1_int8_row3<=m1_row3_next;
        end
        if (m0_mode && m0_valid0) begin
            m1_int4_sum0<=i4_sum0_next; m1_int4_carry0<=i4_carry0_next;
        end
        if (m0_mode && m0_valid1) begin
            m1_int4_sum1<=i4_sum1_next; m1_int4_carry1<=i4_carry1_next;
        end
        m1_mode<=m0_mode;
        if (!m1_mode && m1_valid0) begin
            m2_int8_sum<=m2_sum_next; m2_int8_carry<=m2_carry_next;
        end
        if (m1_mode && m1_valid0) m2_product4_0<=i4_product0_next;
        if (m1_mode && m1_valid1) m2_product4_1<=i4_product1_next;
    end

    always_ff @(posedge clk) begin : tokens
        if (reset) begin
            activation_valid_out<=0; weight_valid_out<=0;
            activation_first_out<=0; weight_first_out<=0;
            activation_last_out<=0; weight_last_out<=0;
            m0_valid0<=0; m0_valid1<=0; m0_init<=0; m0_last<=0;
            m1_valid0<=0; m1_valid1<=0; m1_init<=0; m1_last<=0;
            m2_int8_work<=0; m2_int4_work0<=0; m2_int4_work1<=0;
            m2_init<=0; m2_last<=0;
        end else begin
            activation_valid_out<=activation_valid_in;
            weight_valid_out<=weight_valid_in;
            activation_first_out<=activation_first_in;
            weight_first_out<=weight_first_in;
            activation_last_out<=activation_last_in;
            weight_last_out<=weight_last_in;
            m0_valid0<=activation_valid_in[0]&&weight_valid_in[0];
            m0_valid1<=activation_valid_in[1]&&weight_valid_in[1];
            m0_init<=activation_first_in&&weight_first_in;
            m0_last<=activation_last_in&&weight_last_in;
            m1_valid0<=m0_valid0; m1_valid1<=m0_valid1;
            m1_init<=m0_init; m1_last<=m0_last;
            m2_int8_work<=!m1_mode && m1_valid0;
            m2_int4_work0<=m1_mode && m1_valid0;
            m2_int4_work1<=m1_mode && m1_valid1;
            m2_init<=m1_init; m2_last<=m1_last;
        end
    end

    generate
      if (USE_CSA_ACCUM==0) begin : a0
        reg signed [ACC_WIDTH-1:0] acc;
        reg done;
        wire signed [ACC_WIDTH-1:0] scalar_delta=delta_sum_next+delta_carry_next;
        always_ff @(posedge clk) begin
          // The far-corner completion token must survive masked M/N lanes.
          if(reset) done<=0; else done<=delta_last;
          if(delta_valid) acc<=delta_init ? scalar_delta : acc+scalar_delta;
        end
        assign accumulator_sum=acc; assign accumulator_carry=0; assign tile_done=done;
      end else begin : a1
        reg signed [ACC_WIDTH-1:0] acc_sum, acc_carry;
        reg done;
        wire [ACC_WIDTH-1:0] rs0=acc_sum^acc_carry^delta_sum_next;
        wire [ACC_WIDTH-1:0] rc0=((acc_sum&acc_carry)|
          (acc_sum&delta_sum_next)|(acc_carry&delta_sum_next))<<1;
        wire [ACC_WIDTH-1:0] rs=rs0^rc0^delta_carry_next;
        wire [ACC_WIDTH-1:0] rc=((rs0&rc0)|(rs0&delta_carry_next)|
          (rc0&delta_carry_next))<<1;
        always_ff @(posedge clk) begin
          // The far-corner completion token must survive masked M/N lanes.
          if(reset) done<=0; else done<=delta_last;
          if(delta_valid) begin
            if(delta_init) begin acc_sum<=delta_sum_next; acc_carry<=delta_carry_next; end
            else begin acc_sum<=rs; acc_carry<=rc; end
          end
        end
        assign accumulator_sum=acc_sum; assign accumulator_carry=acc_carry;
        assign tile_done=done;
      end
      if ((USE_CSA_ACCUM!=0)&&(USE_CSA_ACCUM!=1)) begin : bad_mode
        initial $error("USE_CSA_ACCUM must be 0 or 1");
      end
      if (ACC_WIDTH<18) begin : bad_width
        initial $error("ACC_WIDTH must be at least 18");
      end
    endgenerate

`ifndef SYNTHESIS
    always @(posedge clk) if (!reset) begin
      if (m0_mode && m0_valid1)
        assert(m0_valid0) else $error("INT4 lane 1 valid without lane 0");
      assert (!(m2_int8_work && (m2_int4_work0 || m2_int4_work1)))
        else $error("PE M2 INT8 and INT4 work overlap");
      if (m2_int4_work1)
        assert(m2_int4_work0)
          else $error("PE INT4 high product valid without low product");
    end
`endif
endmodule
`default_nettype wire
