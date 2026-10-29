`timescale 1ns / 1ps

// 接收并校验V1单字符识别结果帧。
// 帧：A5 5A | 01 81 seq 01 01 00 | ASCII | crc_lo crc_hi。
// CRC16-CCITT初值FFFF、多项式1021，覆盖version至ASCII；接受0-9、A-Z和a-z。
// PEN S4或HAND比耶只登记确认；完整上行轨迹帧发送后才开启接收窗口并清旧结果。
// 无效短轨迹和重复确认不会误入WAIT；回传序号仍须匹配该完整上行帧。
// S3或模式切换关闭窗口、取消待发确认并清除结果。
module result_uart_packet_rx (
    input  wire       clk,
    input  wire       reset_n,
    input  wire       uart_rx,
    input  wire       confirm_request,
    input  wire       clear_request,
    input  wire       trajectory_sent_pulse,
    input  wire [7:0] trajectory_sent_sequence,
    output wire       result_armed,
    output reg        result_valid,
    output reg  [7:0] result_ascii
);

    localparam [3:0] ST_SOF_A5  = 4'd0;
    localparam [3:0] ST_SOF_5A  = 4'd1;
    localparam [3:0] ST_VERSION = 4'd2;
    localparam [3:0] ST_TYPE    = 4'd3;
    localparam [3:0] ST_SEQ     = 4'd4;
    localparam [3:0] ST_COUNT   = 4'd5;
    localparam [3:0] ST_LEN_LO  = 4'd6;
    localparam [3:0] ST_LEN_HI  = 4'd7;
    localparam [3:0] ST_RESULT  = 4'd8;
    localparam [3:0] ST_CRC_LO  = 4'd9;
    localparam [3:0] ST_CRC_HI  = 4'd10;

    wire [7:0] rx_data;
    wire       rx_valid;
    wire       rx_framing_error;
    reg [3:0]  state;
    reg [15:0] crc16;
    reg [7:0]  frame_sequence;
    reg [7:0]  frame_ascii;
    reg [7:0]  received_crc_low;
    reg        receive_armed;
    reg        confirm_pending;
    reg        expected_sequence_valid;
    reg [7:0]  expected_sequence;

    // 仅完整发送后的轨迹开放接收窗口，供HDMI/OLED显示DRAW/WAIT/DONE。
    assign result_armed = receive_armed;

    uart_rx_8n1 u_uart_rx (
        .clk(clk), .reset_n(reset_n), .rx(uart_rx),
        .data(rx_data), .valid(rx_valid), .framing_error(rx_framing_error)
    );

    function [15:0] crc16_next;
        input [15:0] crc_in;
        input [7:0]  data_in;
        integer bit_index_crc;
        reg [15:0] crc_work;
        begin
            crc_work = crc_in ^ {data_in, 8'h00};
            for (bit_index_crc = 0; bit_index_crc < 8; bit_index_crc = bit_index_crc + 1) begin
                if (crc_work[15])
                    crc_work = (crc_work << 1) ^ 16'h1021;
                else
                    crc_work = crc_work << 1;
            end
            crc16_next = crc_work;
        end
    endfunction

    function is_supported_ascii;
        input [7:0] ascii_in;
        begin
            is_supported_ascii = ((ascii_in >= 8'h30) && (ascii_in <= 8'h39)) ||
                                 ((ascii_in >= 8'h41) && (ascii_in <= 8'h5A)) ||
                                 ((ascii_in >= 8'h61) && (ascii_in <= 8'h7A));
        end
    endfunction

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state                   <= ST_SOF_A5;
            crc16                   <= 16'hFFFF;
            frame_sequence          <= 8'd0;
            frame_ascii             <= 8'd0;
            received_crc_low        <= 8'd0;
            receive_armed           <= 1'b0;
            confirm_pending         <= 1'b0;
            expected_sequence_valid <= 1'b0;
            expected_sequence       <= 8'd0;
            result_valid            <= 1'b0;
            result_ascii            <= 8'd0;
        end else begin
            if (clear_request) begin
                receive_armed           <= 1'b0;
                confirm_pending         <= 1'b0;
                expected_sequence_valid <= 1'b0;
                result_valid            <= 1'b0;
                state                   <= ST_SOF_A5;
            end else if (trajectory_sent_pulse && confirm_pending) begin
                // 发送器完成最后停止位后才绑定序号；未产生上行帧的确认不改变显示。
                receive_armed           <= 1'b1;
                confirm_pending         <= 1'b0;
                expected_sequence       <= trajectory_sent_sequence;
                expected_sequence_valid <= 1'b1;
                result_valid            <= 1'b0;
                state                   <= ST_SOF_A5;
            end else if (confirm_request && !receive_armed) begin
                // 点缓存已冻结时重复确认不会再产生新帧，保持已有结果与窗口状态。
                confirm_pending <= 1'b1;
            end else if (rx_framing_error) begin
                state <= ST_SOF_A5;
            end else begin
                if (rx_valid) begin
                    case (state)
                    ST_SOF_A5: begin
                        if (rx_data == 8'hA5)
                            state <= ST_SOF_5A;
                    end

                    ST_SOF_5A: begin
                        if (rx_data == 8'h5A)
                            state <= ST_VERSION;
                        else if (rx_data != 8'hA5)
                            state <= ST_SOF_A5;
                    end

                    ST_VERSION: begin
                        if (rx_data == 8'h01) begin
                            crc16 <= crc16_next(16'hFFFF, rx_data);
                            state <= ST_TYPE;
                        end else begin
                            state <= (rx_data == 8'hA5) ? ST_SOF_5A : ST_SOF_A5;
                        end
                    end

                    ST_TYPE: begin
                        if (rx_data == 8'h81) begin
                            crc16 <= crc16_next(crc16, rx_data);
                            state <= ST_SEQ;
                        end else begin
                            state <= (rx_data == 8'hA5) ? ST_SOF_5A : ST_SOF_A5;
                        end
                    end

                    ST_SEQ: begin
                        frame_sequence <= rx_data;
                        crc16          <= crc16_next(crc16, rx_data);
                        state          <= ST_COUNT;
                    end

                    ST_COUNT: begin
                        if (rx_data == 8'h01) begin
                            crc16 <= crc16_next(crc16, rx_data);
                            state <= ST_LEN_LO;
                        end else begin
                            state <= (rx_data == 8'hA5) ? ST_SOF_5A : ST_SOF_A5;
                        end
                    end

                    ST_LEN_LO: begin
                        if (rx_data == 8'h01) begin
                            crc16 <= crc16_next(crc16, rx_data);
                            state <= ST_LEN_HI;
                        end else begin
                            state <= (rx_data == 8'hA5) ? ST_SOF_5A : ST_SOF_A5;
                        end
                    end

                    ST_LEN_HI: begin
                        if (rx_data == 8'h00) begin
                            crc16 <= crc16_next(crc16, rx_data);
                            state <= ST_RESULT;
                        end else begin
                            state <= (rx_data == 8'hA5) ? ST_SOF_5A : ST_SOF_A5;
                        end
                    end

                    ST_RESULT: begin
                        if (is_supported_ascii(rx_data)) begin
                            frame_ascii <= rx_data;
                            crc16       <= crc16_next(crc16, rx_data);
                            state       <= ST_CRC_LO;
                        end else begin
                            state <= (rx_data == 8'hA5) ? ST_SOF_5A : ST_SOF_A5;
                        end
                    end

                    ST_CRC_LO: begin
                        received_crc_low <= rx_data;
                        state            <= ST_CRC_HI;
                    end

                    ST_CRC_HI: begin
                        if (receive_armed && expected_sequence_valid &&
                            (frame_sequence == expected_sequence) &&
                            ({rx_data, received_crc_low} == crc16)) begin
                            result_ascii <= frame_ascii;
                            result_valid <= 1'b1;
                        end
                        state <= ST_SOF_A5;
                    end

                        default: state <= ST_SOF_A5;
                    endcase
                end
            end
        end
    end

endmodule
