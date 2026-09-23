`default_nettype none

// Fixed A1 synthesis tops for selector comparisons. Common RTL fixes apply
// to every root; historical reports remain snapshots of their original RTL.  Keeping the
// parameter choices in separately named roots means every Genus checkpoint
// has a stable top-level name and no experiment can accidentally inherit a
// prior experiment's option.
`define TPU_DSE_PORTS \
    input wire clk, input wire reset, \
    input wire cfg_valid, output wire cfg_ready, \
    input wire [15:0] cfg_m, input wire [15:0] cfg_n, input wire [15:0] cfg_k, \
    input wire precision_mode, \
    input wire [127:0] s_activation_data, input wire s_activation_valid, output wire s_activation_ready, \
    input wire [127:0] s_weight_data, input wire s_weight_valid, output wire s_weight_ready, \
    output wire signed [31:0] m_result_data, output wire m_result_valid, input wire m_result_ready, \
    output wire m_result_tile_last, output wire m_result_last, output wire busy

`define TPU_DSE_CONNECT \
    .clk(clk), .reset(reset), .cfg_valid(cfg_valid), .cfg_ready(cfg_ready), \
    .cfg_m(cfg_m), .cfg_n(cfg_n), .cfg_k(cfg_k), .precision_mode(precision_mode), \
    .s_activation_data(s_activation_data), .s_activation_valid(s_activation_valid), .s_activation_ready(s_activation_ready), \
    .s_weight_data(s_weight_data), .s_weight_valid(s_weight_valid), .s_weight_ready(s_weight_ready), \
    .m_result_data(m_result_data), .m_result_valid(m_result_valid), .m_result_ready(m_result_ready), \
    .m_result_tile_last(m_result_tile_last), .m_result_last(m_result_last), .busy(busy)

module tpu_stream_dse_base (`TPU_DSE_PORTS);
    tpu_stream_top #(.USE_CSA_ACCUM(1), .RESULT_IMPL(0), .SCHED_IMPL(0)) u_dut (`TPU_DSE_CONNECT);
endmodule

// S1: one-bit first-K token in place of the 16-bit k_base first-tile test.
module tpu_stream_dse_s1 (`TPU_DSE_PORTS);
    tpu_stream_top #(.USE_CSA_ACCUM(1), .RESULT_IMPL(0), .SCHED_IMPL(1)) u_dut (`TPU_DSE_CONNECT);
endmodule

// S2: S1 plus registered current-tile descriptor facts for last-K/last-packet.
module tpu_stream_dse_s2 (`TPU_DSE_PORTS);
    tpu_stream_top #(.USE_CSA_ACCUM(1), .RESULT_IMPL(0), .SCHED_IMPL(2)) u_dut (`TPU_DSE_CONNECT);
endmodule

// R1: continuously updated result CPA staging; valid remains token-controlled.
module tpu_stream_dse_r1 (`TPU_DSE_PORTS);
    tpu_stream_top #(.USE_CSA_ACCUM(1), .SCHED_IMPL(0), .RESULT_IMPL(1)) u_dut (`TPU_DSE_CONNECT);
endmodule

// R2: R1 plus a segmented carry-select lower CPA.
module tpu_stream_dse_r2 (`TPU_DSE_PORTS);
    tpu_stream_top #(.USE_CSA_ACCUM(1), .SCHED_IMPL(0), .RESULT_IMPL(2)) u_dut (`TPU_DSE_CONNECT);
endmodule

// F1: one-hot local 8-entry R0 read selector.
module tpu_stream_dse_f1 (`TPU_DSE_PORTS);
    tpu_stream_top #(.USE_CSA_ACCUM(1), .RESULT_IMPL(0), .SCHED_IMPL(0), .FEEDER_IMPL(1)) u_dut (`TPU_DSE_CONNECT);
endmodule

// F3: 4:1 local R0 candidates followed by an 8:1 registered R1 selection.
module tpu_stream_dse_f3 (`TPU_DSE_PORTS);
    tpu_stream_top #(.USE_CSA_ACCUM(1), .RESULT_IMPL(0), .SCHED_IMPL(0), .FEEDER_IMPL(3)) u_dut (`TPU_DSE_CONNECT);
endmodule

// Current shallow result pipeline with registered scheduler descriptors.
module tpu_stream_dse_arch (`TPU_DSE_PORTS);
    tpu_stream_top #(.USE_CSA_ACCUM(1), .SCHED_IMPL(2), .RESULT_IMPL(0))
        u_dut (`TPU_DSE_CONNECT);
endmodule

`undef TPU_DSE_CONNECT
`undef TPU_DSE_PORTS
`default_nettype wire
