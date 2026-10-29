`timescale 1ns / 1ps

// 将64个归一化点封装为V1轨迹帧并通过115200 8N1发送。
// 帧：A5 5A | 01 01 seq 40 80 00 | 64组X/Y | crc_lo crc_hi。
// CRC16-CCITT初值FFFF、多项式1021，覆盖version到payload，帧头和CRC本身不参与。
module trajectory_uart_packet_tx (
    input  wire        clk,
    input  wire        reset_n,
    input  wire        points_ready,
    input  wire        allow_start,
    output wire        frame_busy,
    output reg  [5:0]  point_read_addr,
    input  wire [15:0] point_read_data,
    output reg         frame_sent_pulse,
    output reg  [7:0]  frame_sent_sequence,
    output wire        uart_tx
);

    localparam [2:0] ST_IDLE       = 3'd0;
    localparam [2:0] ST_WAIT_BYTE  = 3'd1;
    localparam [2:0] ST_READ_WAIT1 = 3'd2;
    localparam [2:0] ST_READ_WAIT2 = 3'd3;
    localparam [2:0] ST_CRC_PREP   = 3'd4;

    reg [2:0] state;
    reg [7:0] byte_index;
    reg [7:0] sequence_number;
    reg [15:0] crc16;
    reg [15:0] point_latched;
    reg        uart_start;
    reg [7:0]  uart_data;
    wire       uart_busy;
    wire       uart_done;
    reg        points_pending;
    assign frame_busy = (state != ST_IDLE);

    uart_tx_8n1 u_uart_tx (
        .clk(clk), .reset_n(reset_n), .start(uart_start), .data(uart_data),
        .tx(uart_tx), .busy(uart_busy), .done(uart_done)
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

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state           <= ST_IDLE;
            points_pending  <= 1'b0;
            byte_index      <= 8'd0;
            sequence_number <= 8'd0;
            crc16           <= 16'hFFFF;
            point_read_addr <= 6'd0;
            point_latched   <= 16'd0;
            uart_start      <= 1'b0;
            uart_data       <= 8'hFF;
            frame_sent_pulse    <= 1'b0;
            frame_sent_sequence <= 8'd0;
        end else begin
            uart_start       <= 1'b0;
            frame_sent_pulse <= 1'b0;
            // 状态帧占用主机口时先记住ready，获准后才启动完整轨迹帧。
            if (points_ready) points_pending <= 1'b1;
            case (state)
                ST_IDLE: begin
                    if ((points_ready || points_pending) && !uart_busy && allow_start) begin
                        points_pending <= 1'b0;
                        crc16      <= 16'hFFFF;
                        byte_index <= 8'd0;
                        uart_data  <= 8'hA5;
                        uart_start <= 1'b1;
                        state      <= ST_WAIT_BYTE;
                    end
                end

                ST_WAIT_BYTE: begin
                    if (uart_done) begin
                        case (byte_index)
                            8'd0: begin
                                uart_data  <= 8'h5A;
                                uart_start <= 1'b1;
                                byte_index <= 8'd1;
                            end
                            8'd1: begin
                                uart_data  <= 8'h01;
                                uart_start <= 1'b1;
                                byte_index <= 8'd2;
                                crc16      <= crc16_next(16'hFFFF, 8'h01);
                            end
                            8'd2: begin
                                uart_data  <= 8'h01;
                                uart_start <= 1'b1;
                                byte_index <= 8'd3;
                                crc16      <= crc16_next(crc16, 8'h01);
                            end
                            8'd3: begin
                                uart_data  <= sequence_number;
                                uart_start <= 1'b1;
                                byte_index <= 8'd4;
                                crc16      <= crc16_next(crc16, sequence_number);
                            end
                            8'd4: begin
                                uart_data  <= 8'h40;
                                uart_start <= 1'b1;
                                byte_index <= 8'd5;
                                crc16      <= crc16_next(crc16, 8'h40);
                            end
                            8'd5: begin
                                uart_data  <= 8'h80;
                                uart_start <= 1'b1;
                                byte_index <= 8'd6;
                                crc16      <= crc16_next(crc16, 8'h80);
                            end
                            8'd6: begin
                                uart_data  <= 8'h00;
                                uart_start <= 1'b1;
                                byte_index <= 8'd7;
                                crc16      <= crc16_next(crc16, 8'h00);
                            end
                            8'd7: begin
                                point_read_addr <= 6'd0;
                                state           <= ST_READ_WAIT1;
                            end
                            8'd136: begin
                                uart_data  <= crc16[15:8];
                                uart_start <= 1'b1;
                                byte_index <= 8'd137;
                            end
                            8'd137: begin
                                // 停止位完整发送后才发布序号，回传结果不能抢先关联未完成的轨迹帧。
                                frame_sent_sequence <= sequence_number;
                                frame_sent_pulse    <= 1'b1;
                                sequence_number <= sequence_number + 1'b1;
                                state           <= ST_IDLE;
                            end
                            default: begin
                                if ((byte_index >= 8'd8) && (byte_index <= 8'd135)) begin
                                    if (!byte_index[0]) begin
                                        // X发送完成后发送同一点Y；CRC在字节启动时同步推进。
                                        uart_data  <= point_latched[7:0];
                                        uart_start <= 1'b1;
                                        byte_index <= byte_index + 1'b1;
                                        crc16      <= crc16_next(crc16, point_latched[7:0]);
                                    end else if (point_read_addr == 6'd63) begin
                                        state <= ST_CRC_PREP;
                                    end else begin
                                        point_read_addr <= point_read_addr + 1'b1;
                                        state           <= ST_READ_WAIT1;
                                    end
                                end else begin
                                    state <= ST_IDLE;
                                end
                            end
                        endcase
                    end
                end

                ST_READ_WAIT1: state <= ST_READ_WAIT2;

                ST_READ_WAIT2: begin
                    point_latched <= point_read_data;
                    uart_data     <= point_read_data[15:8];
                    uart_start    <= 1'b1;
                    byte_index    <= 8'd8 + {point_read_addr, 1'b0};
                    crc16         <= crc16_next(crc16, point_read_data[15:8]);
                    state         <= ST_WAIT_BYTE;
                end

                ST_CRC_PREP: begin
                    // 最后一个payload字节的CRC已在前一发送拍写回，此处再读取最终值。
                    uart_data  <= crc16[7:0];
                    uart_start <= 1'b1;
                    byte_index <= 8'd136;
                    state      <= ST_WAIT_BYTE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
