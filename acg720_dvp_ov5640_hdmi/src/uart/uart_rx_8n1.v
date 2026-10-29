`timescale 1ns / 1ps

// 50 MHz时钟域的115200波特率8N1字节接收器。
// 异步RX先经过两级同步，再在起始位中点和后续每个bit中点采样；数据按LSB优先输出。
module uart_rx_8n1 #(
    parameter [15:0] CLOCKS_PER_BIT = 16'd434
) (
    input  wire       clk,
    input  wire       reset_n,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid,
    output reg        framing_error
);

    localparam [1:0] ST_IDLE  = 2'd0;
    localparam [1:0] ST_START = 2'd1;
    localparam [1:0] ST_DATA  = 2'd2;
    localparam [1:0] ST_STOP  = 2'd3;

    reg [1:0]  state;
    reg [1:0]  rx_sync;
    reg [15:0] baud_count;
    reg [2:0]  bit_index;
    reg [7:0]  shift_data;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rx_sync <= 2'b11;
        end else begin
            rx_sync <= {rx_sync[0], rx};
        end
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state         <= ST_IDLE;
            baud_count    <= 16'd0;
            bit_index     <= 3'd0;
            shift_data    <= 8'd0;
            data          <= 8'd0;
            valid         <= 1'b0;
            framing_error <= 1'b0;
        end else begin
            valid         <= 1'b0;
            framing_error <= 1'b0;
            case (state)
                ST_IDLE: begin
                    baud_count <= 16'd0;
                    bit_index  <= 3'd0;
                    if (!rx_sync[1]) begin
                        // 半个bit后复核起始位，滤除短低脉冲。
                        baud_count <= (CLOCKS_PER_BIT >> 1) - 1'b1;
                        state      <= ST_START;
                    end
                end

                ST_START: begin
                    if (baud_count != 16'd0) begin
                        baud_count <= baud_count - 1'b1;
                    end else if (!rx_sync[1]) begin
                        baud_count <= CLOCKS_PER_BIT - 1'b1;
                        state      <= ST_DATA;
                    end else begin
                        state <= ST_IDLE;
                    end
                end

                ST_DATA: begin
                    if (baud_count != 16'd0) begin
                        baud_count <= baud_count - 1'b1;
                    end else begin
                        shift_data[bit_index] <= rx_sync[1];
                        baud_count <= CLOCKS_PER_BIT - 1'b1;
                        if (bit_index == 3'd7) begin
                            state <= ST_STOP;
                        end else begin
                            bit_index <= bit_index + 1'b1;
                        end
                    end
                end

                ST_STOP: begin
                    if (baud_count != 16'd0) begin
                        baud_count <= baud_count - 1'b1;
                    end else begin
                        if (rx_sync[1]) begin
                            data  <= shift_data;
                            valid <= 1'b1;
                        end else begin
                            framing_error <= 1'b1;
                        end
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
