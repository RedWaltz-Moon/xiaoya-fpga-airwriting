`timescale 1ns / 1ps

// 原主机口统一解析/整帧复用，全部50MHz域，打印串口独立。
// 优先发送已排队状态，再允许新轨迹起帧；轨迹一旦起帧绝不插入状态字节。
// pending保持到status_busy实际拉高，覆盖request打一拍与发送器接收之间的空隙。
module host_uart_bridge (
    input wire clk, input wire reset_n, input wire uart_rx,
    output wire uart_tx, output wire printer_uart_tx,
    input wire trajectory_serial, input wire trajectory_busy,
    output wire trajectory_allow_start, input wire result_cancel,
    output wire result_packet_valid, output wire [7:0] result_sequence,
    output wire [7:0] result_ascii,
    // 仅把已有打印活动接给灯环，不回控解析器/缓存/发送仲裁。
    output wire printer_active
);
    wire [7:0] rx_data, response_seq, response_status, printer_data;
    wire rx_valid, rx_error, response_valid, status_busy, printer_start, printer_busy, printer_done;
    wire [31:0] response_job;
    wire [15:0] response_length;
    reg pending, starting, status_start;
    reg [7:0] saved_seq, saved_status;
    reg [31:0] saved_job;
    reg [15:0] saved_length;
    wire status_serial;
    assign trajectory_allow_start=!(pending || starting || status_busy);
    assign uart_tx=trajectory_busy ? trajectory_serial : status_serial;
    uart_rx_8n1 u_rx(.clk(clk),.reset_n(reset_n),.rx(uart_rx),.data(rx_data),
        .valid(rx_valid),.framing_error(rx_error));
    print_link_core u_print(.clk(clk),.reset_n(reset_n),.rx_data(rx_data),
        .rx_valid(rx_valid),.rx_error(rx_error),.result_cancel(result_cancel),
        .reply_busy(pending || starting || status_busy),.reply_valid(response_valid),
        .reply_sequence(response_seq),.reply_job(response_job),.reply_status(response_status),
        .reply_length(response_length),.printer_start(printer_start),.printer_data(printer_data),
        .printer_busy(printer_busy),.printer_done(printer_done),.print_active(printer_active),
        .result_packet_valid(result_packet_valid),.result_sequence(result_sequence),.result_ascii(result_ascii));
    // E10实机为9600波特：50MHz/5208约9600.6；只改独立打印口，主机收发仍115200。
    uart_tx_8n1 #(.CLOCKS_PER_BIT(16'd5208)) u_printer(.clk(clk),.reset_n(reset_n),.start(printer_start),.data(printer_data),
        .tx(printer_uart_tx),.busy(printer_busy),.done(printer_done));
    print_status_tx u_status(.clk(clk),.reset_n(reset_n),.request(status_start),
        .frame_sequence(saved_seq),.job_id(saved_job),.status(saved_status),
        .length(saved_length),.tx(status_serial),.busy(status_busy));
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            pending<=0; starting<=0; status_start<=0;
            saved_seq<=0; saved_job<=0; saved_status<=0; saved_length<=0;
        end else begin
            status_start<=0;
            if(response_valid) begin
                pending<=1; saved_seq<=response_seq; saved_job<=response_job;
                saved_status<=response_status; saved_length<=response_length;
            end
            if(pending && !starting && !status_busy && !trajectory_busy) begin
                status_start<=1; starting<=1;
            end
            if(starting && status_busy) begin pending<=0; starting<=0; end
        end
    end
endmodule
