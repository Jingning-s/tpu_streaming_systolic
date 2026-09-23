`default_nettype none
`timescale 1ns/1ps

module tb_fused_accumulator;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg signed [15:0] delta_in;
    reg valid_in, first_in, last_in;
    wire signed [31:0] accumulator;
    wire done;

    integer errors;
    integer expected_running;
    integer expected_result [0:15];
    integer expected_write, expected_read;

    always #0.5 clk = ~clk;

    dse_acc32_fused_top dut(.*);

    task automatic send_token;
        input signed [15:0] delta;
        input first;
        input last;
        begin
            @(negedge clk);
            delta_in = delta;
            valid_in = 1'b1;
            first_in = first;
            last_in = last;
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
            valid_in = 1'b0;
            first_in = 1'b0;
            last_in = 1'b0;
            delta_in = 16'sd0;
        end
    endtask

    always @(posedge clk) begin
        #0.01;
        if (done) begin
            if (expected_read >= expected_write) begin
                $error("unexpected done pulse");
                errors = errors + 1;
            end else if (accumulator !== expected_result[expected_read]) begin
                $error("result %0d expected %0d at job %0d",
                    accumulator, expected_result[expected_read], expected_read);
                errors = errors + 1;
            end
            expected_read = expected_read + 1;
        end
    end

    initial begin
        delta_in = 16'sd0;
        valid_in = 1'b0;
        first_in = 1'b0;
        last_in = 1'b0;
        errors = 0;
        expected_running = 0;
        expected_write = 0;
        expected_read = 0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Signed extremes, bubbles, and a multi-token tile.
        send_token(-16'sd32768, 1'b1, 1'b0);
        send_bubble();
        send_token(16'sd32767, 1'b0, 1'b0);
        send_token(-16'sd19, 1'b0, 1'b1);

        // A new tile starts immediately after the preceding last token.
        send_token(16'sd101, 1'b1, 1'b0);
        send_token(-16'sd7, 1'b0, 1'b1);

        // Single-token tile exercises first && last.
        send_token(-16'sd1234, 1'b1, 1'b1);
        send_bubble();
        send_bubble();
        send_bubble();

        if (expected_read != expected_write) begin
            $error("received %0d of %0d expected results",
                expected_read, expected_write);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: lean fused-CSA accumulator");
        else
            $fatal(1, "FAIL: %0d fused accumulator mismatches", errors);
        $finish;
    end
endmodule

`default_nettype wire
