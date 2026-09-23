`default_nettype none
`timescale 1ns/1ps

// Synthesizable register FIFO. DEPTH is expected to be a power of two.
module stream_fifo #(
    parameter integer WIDTH = 8,
    parameter integer DEPTH = 64,
    parameter integer PTR_WIDTH = $clog2(DEPTH)
) (
    input  wire             clk,
    input  wire             reset,
    input  wire [WIDTH-1:0] in_data,
    input  wire             in_valid,
    output wire             in_ready,
    output wire [WIDTH-1:0] out_data,
    output wire             out_valid,
    input  wire             out_ready,
    output wire             empty,
    output wire             full
);

    reg [WIDTH-1:0] storage [0:DEPTH-1];
    reg [PTR_WIDTH-1:0] write_pointer;
    reg [PTR_WIDTH-1:0] read_pointer;
    reg [PTR_WIDTH:0] count;
    wire push = in_valid && in_ready;
    wire pop  = out_valid && out_ready;

    assign empty     = (count == 0);
    assign full      = (count == DEPTH);
    assign out_valid = !empty;
    assign out_data  = storage[read_pointer];
    assign in_ready  = !full || pop;

    always @(posedge clk) begin
        if (reset) begin
            write_pointer <= {PTR_WIDTH{1'b0}};
            read_pointer  <= {PTR_WIDTH{1'b0}};
            count         <= {(PTR_WIDTH+1){1'b0}};
        end else begin
            if (push) begin
                storage[write_pointer] <= in_data;
                write_pointer <= write_pointer + 1'b1;
            end
            if (pop)
                read_pointer <= read_pointer + 1'b1;
            case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end
endmodule

`default_nettype wire
