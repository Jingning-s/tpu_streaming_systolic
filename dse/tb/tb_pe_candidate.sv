`default_nettype none
`timescale 1ns/1ps

module tb_pe_candidate #(
    parameter integer INT4_IMPL = 2,
    parameter integer INT8_IMPL = 1,
    parameter integer CPA16_IMPL = 1,
    parameter integer ACC32_IMPL = 4
);
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg precision_mode;
    reg [7:0] activation, weight;
    reg [1:0] valid_in;
    reg first_in, last_in;
    wire signed [31:0] accumulator;
    wire done;
    integer errors;
    integer expected;

    always #0.5 clk = ~clk;

    dse_pe_single_top #(
        .INT4_IMPL(INT4_IMPL), .INT8_IMPL(INT8_IMPL),
        .CPA16_IMPL(CPA16_IMPL), .ACC32_IMPL(ACC32_IMPL)
    ) dut(.*);

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
            expected = first ? (a*b) : (expected + a*b);
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
            expected = first ? delta : (expected + delta);
        end
    endtask

    task automatic drive_bubble;
        begin
            @(negedge clk);
            valid_in = 2'b0;
            first_in = 1'b0;
            last_in = 1'b0;
        end
    endtask

    task automatic wait_and_check;
        begin
            while (!done) @(posedge clk);
            #0.01;
            if (accumulator !== expected) begin
                $error("accumulator %0d expected %0d", accumulator, expected);
                errors = errors + 1;
            end
            @(posedge clk);
        end
    endtask

    initial begin
        precision_mode = 0;
        activation = 0;
        weight = 0;
        valid_in = 0;
        first_in = 0;
        last_in = 0;
        errors = 0;
        expected = 0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        send_int8(8'sh80, 8'sh7f, 1'b1, 1'b0);
        send_int8(8'sd31, -8'sd17, 1'b0, 1'b0);
        send_int8(-8'sd3, -8'sd11, 1'b0, 1'b1);
        drive_bubble();
        wait_and_check();

        expected = 0;
        send_int4(4'sh8, 4'sh7, 4'sh7, 4'sh8, 1'b1, 1'b1, 1'b0);
        send_int4(4'sd3, -4'sd2, -4'sd4, -4'sd3, 1'b1, 1'b0, 1'b0);
        send_int4(-4'sd7, -4'sd7, 4'sd0, 4'sd0, 1'b0, 1'b0, 1'b1);
        drive_bubble();
        wait_and_check();

        if (errors == 0)
            $display("PASS: integrated PE candidate");
        else
            $fatal(1, "FAIL: %0d PE candidate mismatches", errors);
        $finish;
    end
endmodule

`default_nettype wire
