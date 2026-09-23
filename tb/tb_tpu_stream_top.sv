`timescale 1ns/1ps

module tb_tpu_stream_top #(
    parameter integer USE_CSA_ACCUM = 1,
    parameter integer SCHED_IMPL = 2,
    parameter integer RESULT_IMPL = 0,
    parameter integer FEEDER_IMPL = 0
);
    localparam integer ARRAY_SIZE = 16;
    localparam integer MAX_DIM = 256;
    localparam integer MAX_ELEMS = MAX_DIM*MAX_DIM;

    reg clk = 1'b0;
    reg reset = 1'b1;

    reg cfg_valid;
    wire cfg_ready;
    reg [15:0] cfg_m, cfg_n, cfg_k;
    reg precision_mode;

    reg [127:0] s_activation_data;
    reg s_activation_valid;
    wire s_activation_ready;
    reg [127:0] s_weight_data;
    reg s_weight_valid;
    wire s_weight_ready;

    wire signed [31:0] m_result_data;
    wire m_result_valid;
    reg  m_result_ready;
    wire m_result_tile_last;
    wire m_result_last;
    wire busy;

    integer signed matrix_a [0:MAX_ELEMS-1];
    integer signed matrix_b [0:MAX_ELEMS-1];
    integer signed expected [0:MAX_ELEMS-1];
    reg expected_tile_last [0:MAX_ELEMS-1];

    bit bench_mode;
    bit bench_stalls;
    integer bench_m = 16, bench_n = 16, bench_k = 16, bench_int4 = 0;
    integer a_gap = -1, b_gap = -1;
    integer perf_cycles, perf_first, perf_issue, perf_wait, perf_drain;
    integer perf_out_stall, perf_prepare, perf_capture, perf_other;

    // Count edges after configuration through the final accepted output.
    // Phase counters partition latency; issue/stall counters can overlap phases.
    always @(posedge clk) begin
        if (reset || (cfg_valid && cfg_ready)) begin
            perf_cycles = 0; perf_first = 0; perf_issue = 0;
            perf_wait = 0; perf_drain = 0; perf_out_stall = 0;
            perf_prepare = 0; perf_capture = 0; perf_other = 0;
        end else if (job_active) begin
            perf_cycles = perf_cycles + 1;
            if (dut.issue_valid) perf_issue = perf_issue + 1;
            if (m_result_valid && !m_result_ready)
                perf_out_stall = perf_out_stall + 1;
            case (dut.state)
                1: perf_wait = perf_wait + 1;
                6: perf_drain = perf_drain + 1;
                7,11,12,13,15: perf_prepare = perf_prepare + 1;
                5,14: perf_capture = perf_capture + 1;
                default: perf_other = perf_other + 1;
            endcase
            if (m_result_valid && m_result_ready) begin
                if (perf_first == 0) perf_first = perf_cycles;
                if (bench_mode && m_result_last)
                    $display("PERF,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                        bench_m,bench_n,bench_k,bench_int4,perf_cycles,
                        perf_first,perf_issue,perf_wait,perf_drain,
                        perf_prepare,perf_capture,perf_other,perf_out_stall,
                        accepted_a_packets,accepted_b_packets,emitted_results+1);
            end
        end
    end

    integer errors;
    integer ready_cycle;
    integer accepted_a_packets;
    integer accepted_b_packets;
    integer emitted_results;
    integer expected_packets_for_job;
    integer expected_results_for_job;
    reg     job_active;
    reg     output_was_stalled;
    reg signed [31:0] stalled_data;
    reg     stalled_tile_last;
    reg     stalled_last;

    always #0.5 clk = ~clk;

    tpu_stream_top #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .ACC_WIDTH(32),
        .USE_CSA_ACCUM(USE_CSA_ACCUM),
        .SCHED_IMPL(SCHED_IMPL),
        .RESULT_IMPL(RESULT_IMPL),
        .FEEDER_IMPL(FEEDER_IMPL)
    ) dut (
        .clk(clk),
        .reset(reset),
        .cfg_valid(cfg_valid),
        .cfg_ready(cfg_ready),
        .cfg_m(cfg_m),
        .cfg_n(cfg_n),
        .cfg_k(cfg_k),
        .precision_mode(precision_mode),
        .s_activation_data(s_activation_data),
        .s_activation_valid(s_activation_valid),
        .s_activation_ready(s_activation_ready),
        .s_weight_data(s_weight_data),
        .s_weight_valid(s_weight_valid),
        .s_weight_ready(s_weight_ready),
        .m_result_data(m_result_data),
        .m_result_valid(m_result_valid),
        .m_result_ready(m_result_ready),
        .m_result_tile_last(m_result_tile_last),
        .m_result_last(m_result_last),
        .busy(busy)
    );

    function automatic integer imin;
        input integer left;
        input integer right;
        begin
            imin = (left < right) ? left : right;
        end
    endfunction

    task automatic prepare_case;
        input integer m_dim;
        input integer n_dim;
        input integer k_dim;
        input integer int4_mode;
        integer row, col, inner;
        integer mb, nb, ml, nl;
        integer output_index;
        begin
            for (row = 0; row < m_dim; row = row + 1)
                for (inner = 0; inner < k_dim; inner = inner + 1) begin
                    if (int4_mode)
                        matrix_a[row*k_dim+inner] =
                            ((row*5 + inner*3 + 2) % 15) - 7;
                    else
                        matrix_a[row*k_dim+inner] =
                            ((row*11 + inner*7 + 3) % 31) - 15;
                end

            for (inner = 0; inner < k_dim; inner = inner + 1)
                for (col = 0; col < n_dim; col = col + 1) begin
                    if (int4_mode)
                        matrix_b[inner*n_dim+col] =
                            ((inner*7 + col*2 + 1) % 15) - 7;
                    else
                        matrix_b[inner*n_dim+col] =
                            ((inner*3 + col*13 + 5) % 29) - 14;
                end

            // Ensure signed extrema occur in normal regression traffic.
            if (int4_mode) begin
                matrix_a[0] = -8;
                matrix_a[m_dim*k_dim-1] = 7;
                matrix_b[0] = 7;
                matrix_b[k_dim*n_dim-1] = -8;
            end else begin
                matrix_a[0] = -128;
                matrix_a[m_dim*k_dim-1] = 127;
                matrix_b[0] = 127;
                matrix_b[k_dim*n_dim-1] = -128;
            end

            output_index = 0;
            for (mb = 0; mb < m_dim; mb = mb + ARRAY_SIZE) begin
                ml = imin(ARRAY_SIZE, m_dim-mb);
                for (nb = 0; nb < n_dim; nb = nb + ARRAY_SIZE) begin
                    nl = imin(ARRAY_SIZE, n_dim-nb);
                    for (row = 0; row < ml; row = row + 1)
                        for (col = 0; col < nl; col = col + 1) begin
                            expected[output_index] = 0;
                            for (inner = 0; inner < k_dim; inner = inner + 1)
                                expected[output_index] = expected[output_index] +
                                    matrix_a[(mb+row)*k_dim+inner] *
                                    matrix_b[inner*n_dim+(nb+col)];
                            expected_tile_last[output_index] =
                                (row == ml-1) && (col == nl-1);
                            output_index = output_index + 1;
                        end
                end
            end
        end
    endtask

    task automatic configure;
        input integer m_dim;
        input integer n_dim;
        input integer k_dim;
        input integer int4_mode;
        begin
            while (!cfg_ready) @(posedge clk);
            @(negedge clk);
            cfg_m = m_dim;
            cfg_n = n_dim;
            cfg_k = k_dim;
            precision_mode = int4_mode;
            cfg_valid = 1'b1;
            do @(posedge clk); while (!cfg_ready);
            @(negedge clk);
            cfg_valid = 1'b0;
        end
    endtask

    task automatic send_a_tiles;
        input integer m_dim;
        input integer n_dim;
        input integer k_dim;
        input integer int4_mode;
        integer mb, nb, kb, step, spatial;
        integer k_len, steps, k0, k1;
        integer stall_cycles;
        reg [127:0] beat;
        reg [15:0] stall_lfsr;
        begin
            stall_lfsr = 16'h1ace;
            for (mb = 0; mb < m_dim; mb = mb + ARRAY_SIZE)
                for (nb = 0; nb < n_dim; nb = nb + ARRAY_SIZE)
                    for (kb = 0; kb < k_dim; kb = kb + ARRAY_SIZE) begin
                        k_len = imin(ARRAY_SIZE, k_dim-kb);
                        steps = int4_mode ? ((k_len+1)/2) : k_len;
                        for (step = 0; step < steps; step = step + 1) begin
                            beat = 128'b0;
                            for (spatial = 0; spatial < ARRAY_SIZE;
                                 spatial = spatial + 1) begin
                                if ((mb+spatial) < m_dim) begin
                                    if (int4_mode) begin
                                        k0 = kb + 2*step;
                                        k1 = k0 + 1;
                                        if (k0 < k_dim)
                                            beat[(spatial*8) +: 4] =
                                                matrix_a[(mb+spatial)*k_dim+k0];
                                        if (k1 < (kb+k_len))
                                            beat[(spatial*8+4) +: 4] =
                                                matrix_a[(mb+spatial)*k_dim+k1];
                                        else
                                            // Deliberately nonzero padding:
                                            // odd-K validity must suppress it.
                                            beat[(spatial*8+4) +: 4] = 4'h7;
                                    end else begin
                                        beat[(spatial*8) +: 8] =
                                            matrix_a[(mb+spatial)*k_dim+kb+step];
                                    end
                                end
                            end
                            stall_lfsr = {stall_lfsr[14:0],
                                stall_lfsr[15] ^ stall_lfsr[13] ^
                                stall_lfsr[12] ^ stall_lfsr[10]};
                            stall_cycles = (a_gap >= 0) ? a_gap : ((bench_mode && !bench_stalls) ? 0 : int'(stall_lfsr[1:0]));
                            repeat (stall_cycles) begin
                                @(negedge clk);
                                if (reset) return;
                                s_activation_valid = 1'b0;
                            end
                            @(negedge clk);
                            if (reset) return;
                            s_activation_data = beat;
                            s_activation_valid = 1'b1;
                            do begin
                                @(posedge clk);
                                if (reset) return;
                            end while (!s_activation_ready);
                        end
                    end
            @(negedge clk);
            if (reset) return;
            s_activation_valid = 1'b0;
        end
    endtask

    task automatic send_b_tiles;
        input integer m_dim;
        input integer n_dim;
        input integer k_dim;
        input integer int4_mode;
        integer mb, nb, kb, step, spatial;
        integer k_len, steps, k0, k1;
        integer stall_cycles;
        reg [127:0] beat;
        reg [15:0] stall_lfsr;
        begin
            stall_lfsr = 16'hc35a;
            for (mb = 0; mb < m_dim; mb = mb + ARRAY_SIZE)
                for (nb = 0; nb < n_dim; nb = nb + ARRAY_SIZE)
                    for (kb = 0; kb < k_dim; kb = kb + ARRAY_SIZE) begin
                        k_len = imin(ARRAY_SIZE, k_dim-kb);
                        steps = int4_mode ? ((k_len+1)/2) : k_len;
                        for (step = 0; step < steps; step = step + 1) begin
                            beat = 128'b0;
                            for (spatial = 0; spatial < ARRAY_SIZE;
                                 spatial = spatial + 1) begin
                                if ((nb+spatial) < n_dim) begin
                                    if (int4_mode) begin
                                        k0 = kb + 2*step;
                                        k1 = k0 + 1;
                                        if (k0 < k_dim)
                                            beat[(spatial*8) +: 4] =
                                                matrix_b[k0*n_dim+nb+spatial];
                                        if (k1 < (kb+k_len))
                                            beat[(spatial*8+4) +: 4] =
                                                matrix_b[k1*n_dim+nb+spatial];
                                        else
                                            beat[(spatial*8+4) +: 4] = 4'h9;
                                    end else begin
                                        beat[(spatial*8) +: 8] =
                                            matrix_b[(kb+step)*n_dim+nb+spatial];
                                    end
                                end
                            end
                            stall_lfsr = {stall_lfsr[14:0],
                                stall_lfsr[15] ^ stall_lfsr[14] ^
                                stall_lfsr[12] ^ stall_lfsr[3]};
                            stall_cycles = (b_gap >= 0) ? b_gap : ((bench_mode && !bench_stalls) ? 0 : int'(stall_lfsr[2:1]));
                            repeat (stall_cycles) begin
                                @(negedge clk);
                                if (reset) return;
                                s_weight_valid = 1'b0;
                            end
                            @(negedge clk);
                            if (reset) return;
                            s_weight_data = beat;
                            s_weight_valid = 1'b1;
                            do begin
                                @(posedge clk);
                                if (reset) return;
                            end while (!s_weight_ready);
                        end
                    end
            @(negedge clk);
            if (reset) return;
            s_weight_valid = 1'b0;
        end
    endtask

    task automatic prepare_identity_case;
        integer row, col, inner, output_index;
        begin
            for (row = 0; row < ARRAY_SIZE; row = row + 1)
                for (inner = 0; inner < ARRAY_SIZE; inner = inner + 1)
                    matrix_a[row*ARRAY_SIZE+inner] = (row == inner) ? 1 : 0;
            for (inner = 0; inner < ARRAY_SIZE; inner = inner + 1)
                for (col = 0; col < ARRAY_SIZE; col = col + 1)
                    matrix_b[inner*ARRAY_SIZE+col] =
                        (inner == col) ? (col-8) : 0;

            output_index = 0;
            for (row = 0; row < ARRAY_SIZE; row = row + 1)
                for (col = 0; col < ARRAY_SIZE; col = col + 1) begin
                    expected[output_index] = (row == col) ? (col-8) : 0;
                    expected_tile_last[output_index] =
                        (row == ARRAY_SIZE-1) && (col == ARRAY_SIZE-1);
                    output_index = output_index + 1;
                end
        end
    endtask

    task automatic run_identity_case;
        input integer case_number;
        begin
            $display("CASE %0d: full-array diagonal skew/far-corner", case_number);
            prepare_identity_case();
            configure(ARRAY_SIZE, ARRAY_SIZE, ARRAY_SIZE, 0);
            fork
                send_a_tiles(ARRAY_SIZE, ARRAY_SIZE, ARRAY_SIZE, 0);
                send_b_tiles(ARRAY_SIZE, ARRAY_SIZE, ARRAY_SIZE, 0);
                receive_results(ARRAY_SIZE*ARRAY_SIZE, case_number);
            join
            wait (cfg_ready);
        end
    endtask

    task automatic pulse_reset_in_state;
        input integer target_state;
        begin
            $display("RESET TEST: state=%0d", target_state);
            if (target_state == 0) begin
                @(negedge clk);
                reset = 1'b1;
                repeat (2) @(posedge clk);
                @(negedge clk);
                reset = 1'b0;
            end else begin
                prepare_case(17, 17, 33, 1);
                configure(17, 17, 33, 1);
                fork
                    send_a_tiles(17, 17, 33, 1);
                    send_b_tiles(17, 17, 33, 1);
                    begin
                        wait (dut.state == target_state);
                        @(negedge clk);
                        reset = 1'b1;
                        repeat (2) @(posedge clk);
                        @(negedge clk);
                        reset = 1'b0;
                    end
                join
                @(negedge clk);
                s_activation_valid = 1'b0;
                s_weight_valid = 1'b0;
            end
            wait (cfg_ready);
        end
    endtask

    task automatic reset_during_prefetch(input integer phase_target);
        begin
            $display("RESET PREFETCH: phase=%0d", phase_target);
            prepare_case(16, 16, 129, 1);
            configure(16, 16, 129, 1);
            fork
                send_a_tiles(16, 16, 129, 1);
                send_b_tiles(16, 16, 129, 1);
                begin
                    if (phase_target == 0)
                        wait (dut.prefetch_ready && !m_result_ready);
                    else wait (dut.prefetch_phase == phase_target);
                    @(negedge clk);
                    reset = 1;
                    repeat (2) @(posedge clk);
                    @(negedge clk);
                    reset = 0;
                end
            join
            @(negedge clk);
            s_activation_valid = 0;
            s_weight_valid = 0;
            wait (cfg_ready);
        end
    endtask

    task automatic receive_results;
        input integer result_count;
        input integer case_number;
        integer output_index;
        begin
            output_index = 0;
            while (output_index < result_count) begin
                @(posedge clk);
                if (m_result_valid && m_result_ready) begin
                    if ($signed(m_result_data) !== expected[output_index]) begin
                        $error("case %0d result %0d: got %0d expected %0d",
                               case_number, output_index,
                               $signed(m_result_data), expected[output_index]);
                        errors = errors + 1;
                    end
                    if (m_result_tile_last !== expected_tile_last[output_index]) begin
                        $error("case %0d result %0d: incorrect tile_last",
                               case_number, output_index);
                        errors = errors + 1;
                    end
                    if (m_result_last !== (output_index == result_count-1)) begin
                        $error("case %0d result %0d: incorrect last",
                               case_number, output_index);
                        errors = errors + 1;
                    end
                    output_index = output_index + 1;
                end
            end
        end
    endtask

    task automatic run_case;
        input integer m_dim;
        input integer n_dim;
        input integer k_dim;
        input integer int4_mode;
        input integer case_number;
        begin
            $display("CASE %0d: M=%0d N=%0d K=%0d mode=%s",
                     case_number, m_dim, n_dim, k_dim,
                     int4_mode ? "INT4" : "INT8");
            prepare_case(m_dim, n_dim, k_dim, int4_mode);
            configure(m_dim, n_dim, k_dim, int4_mode);
            fork
                send_a_tiles(m_dim, n_dim, k_dim, int4_mode);
                send_b_tiles(m_dim, n_dim, k_dim, int4_mode);
                receive_results(m_dim*n_dim, case_number);
            join
            wait (cfg_ready);
        end
    endtask

    always @(negedge clk) begin
        if (reset) begin
            ready_cycle = 0;
            m_result_ready = 1'b0;
        end else begin
            ready_cycle = ready_cycle + 1;
            // Exercise long output backpressure bursts and stability.
            m_result_ready = (bench_mode && !bench_stalls) || ((ready_cycle % 31) >= 12);
        end
    end

    // External transaction-count and elastic-output assertions.
    always @(posedge clk) begin
        if (reset) begin
            accepted_a_packets     <= 0;
            accepted_b_packets     <= 0;
            emitted_results        <= 0;
            expected_packets_for_job <= 0;
            expected_results_for_job <= 0;
            job_active             <= 1'b0;
            output_was_stalled     <= 1'b0;
        end else begin
            if (output_was_stalled) begin
                assert (m_result_valid &&
                        $signed(m_result_data) == stalled_data &&
                        m_result_tile_last == stalled_tile_last &&
                        m_result_last == stalled_last)
                    else begin
                        $error("result payload changed while stalled");
                        errors = errors + 1;
                    end
            end

            output_was_stalled <= m_result_valid && !m_result_ready;
            if (m_result_valid && !m_result_ready) begin
                stalled_data      <= m_result_data;
                stalled_tile_last <= m_result_tile_last;
                stalled_last      <= m_result_last;
            end

            if (cfg_valid && cfg_ready) begin
                accepted_a_packets <= 0;
                accepted_b_packets <= 0;
                emitted_results <= 0;
                expected_packets_for_job <=
                    ((cfg_m+15)/16) * ((cfg_n+15)/16) *
                    (precision_mode ? ((cfg_k+1)/2) : cfg_k);
                expected_results_for_job <= cfg_m * cfg_n;
                job_active <= (cfg_m != 0) && (cfg_n != 0) && (cfg_k != 0);
            end else begin
                if (s_activation_valid && s_activation_ready)
                    accepted_a_packets <= accepted_a_packets + 1;
                if (s_weight_valid && s_weight_ready)
                    accepted_b_packets <= accepted_b_packets + 1;
                if (m_result_valid && m_result_ready)
                    emitted_results <= emitted_results + 1;

                if (job_active && m_result_valid && m_result_ready &&
                    m_result_last) begin
                    assert (accepted_a_packets == expected_packets_for_job)
                        else begin
                            $error("A packet count %0d expected %0d",
                                   accepted_a_packets,
                                   expected_packets_for_job);
                            errors = errors + 1;
                        end
                    assert (accepted_b_packets == expected_packets_for_job)
                        else begin
                            $error("B packet count %0d expected %0d",
                                   accepted_b_packets,
                                   expected_packets_for_job);
                            errors = errors + 1;
                        end
                    assert (emitted_results + 1 == expected_results_for_job)
                        else begin
                            $error("result count %0d expected %0d",
                                   emitted_results + 1,
                                   expected_results_for_job);
                            errors = errors + 1;
                        end
                    job_active <= 1'b0;
                end
            end
        end
    end

    initial begin
        bench_mode = $test$plusargs("bench");
        bench_stalls = $test$plusargs("stalls");
        if ($value$plusargs("a_gap=%d", a_gap)) begin end
        if ($value$plusargs("b_gap=%d", b_gap)) begin end
        if ($value$plusargs("m=%d", bench_m)) begin end
        if ($value$plusargs("n=%d", bench_n)) begin end
        if ($value$plusargs("k=%d", bench_k)) begin end
        if ($value$plusargs("int4=%d", bench_int4)) begin end
        if (bench_m < 1 || bench_m > MAX_DIM ||
            bench_n < 1 || bench_n > MAX_DIM ||
            bench_k < 1 || bench_k > MAX_DIM ||
            bench_int4 < 0 || bench_int4 > 1)
            $fatal(1, "benchmark dimensions must be 1..256, int4 must be 0/1");
        cfg_valid = 1'b0;
        cfg_m = 16'b0;
        cfg_n = 16'b0;
        cfg_k = 16'b0;
        precision_mode = 1'b0;
        s_activation_data = 128'b0;
        s_activation_valid = 1'b0;
        s_weight_data = 128'b0;
        s_weight_valid = 1'b0;
        m_result_ready = 1'b0;
        errors = 0;
        ready_cycle = 0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        if (bench_mode) begin
            run_case(bench_m, bench_n, bench_k, bench_int4, 100);
            if (errors != 0) $fatal(1, "benchmark failed: %0d errors", errors);
            $display("PASS: benchmark output verified");
            $finish;
        end

        pulse_reset_in_state(0); // IDLE
        pulse_reset_in_state(1); // LOAD / WAIT_BANK
        pulse_reset_in_state(9); // NEXT-K LENGTH PREP
        pulse_reset_in_state(4); // COMPUTE
        pulse_reset_in_state(7); // RESULT ROW LOAD
        pulse_reset_in_state(11); // REGISTERED RESULT ROW ARM
        pulse_reset_in_state(6); // DRAIN
        pulse_reset_in_state(15); // COMMIT
        pulse_reset_in_state(16); // ADVANCE TILE

        pulse_reset_in_state(17); // waiting for a short-row prefetch
        for (integer phase_idx = 0; phase_idx <= 4; phase_idx++)
            reset_during_prefetch(phase_idx);
        for (integer long_mode = 0; long_mode < 2; long_mode++) begin
            run_case(16,16,129,long_mode,40+long_mode*3);
            run_case(17,3,255,long_mode,41+long_mode*3);
            run_case(1,17,256,long_mode,42+long_mode*3);
        end

        run_case(1, 1, 1, 0, 1);
        run_case(15, 15, 2, 1, 2);
        run_case(16, 16, 15, 0, 3);
        run_case(17, 17, 16, 1, 4);
        run_case(1, 17, 17, 0, 5);
        run_case(17, 1, 31, 1, 6);
        run_case(15, 16, 32, 0, 7);
        run_case(16, 15, 33, 1, 8);
        run_case(17, 18, 19, 0, 9);
        run_case(17, 18, 19, 1, 10);
        run_identity_case(11);
        run_case(64, 64, 64, 1, 12);
        run_case(64, 64, 64, 0, 13);
        run_case(1, 1, 1, 1, 14);
        for (integer mode = 0; mode < 2; mode = mode + 1) begin
            run_case(1, 1, 2, mode, 20+mode*10);
            run_case(1, 1, 15, mode, 21+mode*10);
            run_case(1, 1, 16, mode, 22+mode*10);
            run_case(1, 1, 17, mode, 23+mode*10);
            run_case(1, 1, 31, mode, 24+mode*10);
            run_case(1, 1, 32, mode, 25+mode*10);
            run_case(1, 1, 33, mode, 26+mode*10);
        end

        if (errors == 0)
            $display("PASS: tiled INT8/INT4 GEMM including 64x64");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        repeat (2000000) @(posedge clk);
        $fatal(1, "Timeout after 2000000 cycles");
    end

    initial begin
        if ($test$plusargs("dump")) begin
            $dumpfile("wave.vcd");
            $dumpvars(0, tb_tpu_stream_top);
        end
    end

endmodule
