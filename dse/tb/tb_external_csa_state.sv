`default_nettype none
`timescale 1ns/1ps

module tb_external_csa_state;
    reg signed [7:0] check_a, check_b;
    wire [17:0] check_l1_sum, check_l1_carry, check_tail;
    wire [17:0] check_final_sum, check_final_carry;
    integer ai, bi, errors;
    reg signed [15:0] expected_product;

    reg clk = 1'b0;
    reg reset = 1'b1;
    reg precision_mode;
    reg [7:0] activation, weight;
    reg [1:0] valid_in;
    reg first_in, last_in;
    wire [31:0] sum_state, carry_state;
    wire state_done;
    wire [31:0] finalized_result;
    wire finalized_valid;
    wire [3:0] finalized_row;
    integer expected_running;
    integer expected_result [0:15];
    integer expected_write, expected_read;

    always #0.5 clk = ~clk;

    dse_int8_booth_first_compress u_check_first(
        .a(check_a), .b(check_b), .first_sum(check_l1_sum),
        .first_carry_shifted(check_l1_carry), .tail(check_tail));
    dse_csa3 #(.W(18)) u_check_final(
        .x(check_l1_sum), .y(check_l1_carry), .z(check_tail),
        .sum(check_final_sum), .carry_shifted(check_final_carry));

    dse_pe_token_single_top u_pe(.*);
    dse_result_row_finalizer_top #(.LANES(1), .CPA_IMPL(1)) u_finalizer(
        .clk(clk), .reset(reset), .capture_sum(sum_state),
        .capture_carry(carry_state), .capture_valid(state_done),
        .capture_row(4'b0), .result_data(finalized_result),
        .result_valid(finalized_valid), .result_row(finalized_row));

    task automatic send_int8;
        input signed [7:0] a;
        input signed [7:0] b;
        input first;
        input last;
        begin
            @(negedge clk);
            precision_mode = 1'b0;
            activation = a;
            weight = b;
            valid_in = 2'b01;
            first_in = first;
            last_in = last;
            expected_running = first ? a*b : expected_running + a*b;
            if (last) begin
                expected_result[expected_write] = expected_running;
                expected_write = expected_write + 1;
            end
        end
    endtask

    task automatic send_int4;
        input signed [3:0] a0;
        input signed [3:0] b0;
        input signed [3:0] a1;
        input signed [3:0] b1;
        input lane1_valid;
        input first;
        input last;
        integer delta;
        begin
            @(negedge clk);
            precision_mode = 1'b1;
            activation = {a1, a0};
            weight = {b1, b0};
            valid_in = {lane1_valid, 1'b1};
            first_in = first;
            last_in = last;
            delta = a0*b0 + (lane1_valid ? a1*b1 : 0);
            expected_running = first ? delta : expected_running + delta;
            if (last) begin
                expected_result[expected_write] = expected_running;
                expected_write = expected_write + 1;
            end
        end
    endtask

    task automatic send_bubble;
        begin
            @(negedge clk);
            activation = 8'b0;
            weight = 8'b0;
            valid_in = 2'b0;
            first_in = 1'b0;
            last_in = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        #0.01;
        if (finalized_valid) begin
            if (expected_read >= expected_write) begin
                $error("unexpected finalized result");
                errors = errors + 1;
            end else if ($signed(finalized_result) !==
                         expected_result[expected_read]) begin
                $error("result %0d expected %0d for job %0d",
                    $signed(finalized_result), expected_result[expected_read],
                    expected_read);
                errors = errors + 1;
            end
            expected_read = expected_read + 1;
        end
    end

    initial begin
        errors = 0;
        check_a = 0;
        check_b = 0;
        precision_mode = 0;
        activation = 0;
        weight = 0;
        valid_in = 0;
        first_in = 0;
        last_in = 0;
        expected_running = 0;
        expected_write = 0;
        expected_read = 0;

        for (ai = -128; ai <= 127; ai = ai + 1) begin
            for (bi = -128; bi <= 127; bi = bi + 1) begin
                check_a = ai;
                check_b = bi;
                expected_product = ai * bi;
                #1;
                if ((check_final_sum[15:0] + check_final_carry[15:0]) !==
                    expected_product)
                    errors = errors + 1;
            end
        end

        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        send_int8(-8'sd128, 8'sd127, 1'b1, 1'b0);
        send_bubble();
        send_int8(8'sd31, -8'sd17, 1'b0, 1'b1);
        send_int4(4'sh8, 4'sh7, 4'sh7, 4'sh8, 1'b1, 1'b1, 1'b0);
        send_int4(4'sd3, -4'sd2, -4'sd4, -4'sd3, 1'b1, 1'b0, 1'b0);
        send_int4(-4'sd7, -4'sd7, 4'sd0, 4'sd0, 1'b0, 1'b0, 1'b1);
        send_int8(-8'sd11, -8'sd13, 1'b1, 1'b1);
        repeat (12) send_bubble();

        if (expected_read != expected_write) begin
            $error("received %0d of %0d expected results",
                expected_read, expected_write);
            errors = errors + 1;
        end
        if (finalized_row !== 4'b0) begin
            $error("row metadata misaligned");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: external CSA state and row finalizer");
        else
            $fatal(1, "FAIL: %0d external-CSA mismatches", errors);
        $finish;
    end
endmodule

`default_nettype wire
