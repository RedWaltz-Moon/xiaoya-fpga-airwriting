`timescale 1ns / 1ps

// 50 MHz时钟域的115200波特率8N1字节发送器。
// 每个bit固定434拍，实际波特率约115207；start仅在busy=0时接受一次。
module uart_tx_8n1 #(
    parameter [15:0] CLOCKS_PER_BIT = 16'd434
) (
    input  wire       clk,
    input  wire       reset_n,
    input  wire       start,
    input  wire [7:0] data,
    output reg        tx,
    output reg        busy,
    output reg        done
);

    reg [15:0] baud_count;
    reg [3:0]  bit_index;
    reg [9:0]  shift_frame;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            tx          <= 1'b1;
            busy        <= 1'b0;
            done        <= 1'b0;
            baud_count  <= 16'd0;
            bit_index   <= 4'd0;
            shift_frame <= 10'h3FF;
        end else begin
            done <= 1'b0;
            if (!busy) begin
                tx         <= 1'b1;
                baud_count <= 16'd0;
                bit_index  <= 4'd0;
                if (start) begin
                    // 位序：1个低电平起始位、8位数据LSB优先、1个高电平停止位。
                    shift_frame <= {1'b1, data, 1'b0};
                    tx           <= 1'b0;
                    busy         <= 1'b1;
                end
            end else if (baud_count == CLOCKS_PER_BIT - 1'b1) begin
                baud_count <= 16'd0;
                if (bit_index == 4'd9) begin
                    tx   <= 1'b1;
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    bit_index <= bit_index + 1'b1;
                    tx        <= shift_frame[bit_index + 1'b1];
                end
            end else begin
                baud_count <= baud_count + 1'b1;
            end
        end
    end

endmodule
