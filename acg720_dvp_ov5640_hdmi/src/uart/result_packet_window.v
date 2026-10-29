`timescale 1ns / 1ps

// 保留原结果窗口生命周期；共享接收器只在格式/CRC/字符校验通过后投递结果包。
// 全部50MHz域：确认只登记pending，轨迹完整发完才绑定seq并进入WAIT。
// 清空或新绑定会阻止接收中的旧结果，不会取消已经接受的打印任务。
module result_packet_window (
    input wire clk, input wire reset_n,
    input wire packet_valid, input wire [7:0] packet_sequence, input wire [7:0] packet_ascii,
    input wire confirm_request, input wire clear_request,
    input wire trajectory_sent_pulse, input wire [7:0] trajectory_sent_sequence,
    output wire packet_cancel, output wire result_armed,
    output reg result_valid, output reg [7:0] result_ascii
);
    reg receive_armed, confirm_pending, expected_sequence_valid;
    reg [7:0] expected_sequence;
    assign result_armed=receive_armed;
    assign packet_cancel=clear_request || (trajectory_sent_pulse && confirm_pending);
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            receive_armed<=0; confirm_pending<=0; expected_sequence_valid<=0;
            expected_sequence<=0; result_valid<=0; result_ascii<=0;
        end else if(clear_request) begin
            receive_armed<=0; confirm_pending<=0; expected_sequence_valid<=0; result_valid<=0;
        end else if(trajectory_sent_pulse && confirm_pending) begin
            receive_armed<=1; confirm_pending<=0; expected_sequence<=trajectory_sent_sequence;
            expected_sequence_valid<=1; result_valid<=0;
        end else if(confirm_request && !receive_armed) begin
            confirm_pending<=1;
        end else if(packet_valid && receive_armed && expected_sequence_valid &&
                    packet_sequence==expected_sequence) begin
            result_ascii<=packet_ascii; result_valid<=1;
        end
    end
endmodule
