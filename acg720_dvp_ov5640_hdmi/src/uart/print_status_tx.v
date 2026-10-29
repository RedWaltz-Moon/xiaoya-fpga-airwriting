`timescale 1ns / 1ps

// 17字节状态帧整帧发送。独立探针中独占主机TX；完整工程由host_uart_bridge仲裁。
// request空闲时采样一次，busy覆盖整帧及全部停止位，不能与轨迹按字节交错。
module print_status_tx #(
    parameter [15:0] CLOCKS_PER_BIT=16'd434
) (
    input wire clk, input wire reset_n, input wire request,
    input wire [7:0] frame_sequence, input wire [31:0] job_id,
    input wire [7:0] status, input wire [15:0] length,
    output wire tx, output wire busy
);
    reg active, start;
    reg [4:0] index;
    reg [7:0] data, saved_seq, saved_status;
    reg [31:0] saved_job;
    reg [15:0] saved_length, crc;
    wire uart_busy, uart_done;
    reg waiting;
    reg [7:0] selected;
    assign busy=active;
    uart_tx_8n1 #(.CLOCKS_PER_BIT(CLOCKS_PER_BIT)) u_tx(
        .clk(clk),.reset_n(reset_n),.start(start),.data(data),
        .tx(tx),.busy(uart_busy),.done(uart_done));
    function [15:0] crc_next;
        input [15:0] c; input [7:0] b;
        reg [15:0] w; integer i;
        begin
            w=c^{b,8'h00};
            for(i=0;i<8;i=i+1) w=w[15] ? (w<<1)^16'h1021 : w<<1;
            crc_next=w;
        end
    endfunction
    always @* begin
        case(index)
            0:selected=8'ha5; 1:selected=8'h5a; 2:selected=1; 3:selected=2;
            4:selected=saved_seq; 5:selected=1; 6:selected=7; 7:selected=0;
            8:selected=saved_job[7:0]; 9:selected=saved_job[15:8];
            10:selected=saved_job[23:16]; 11:selected=saved_job[31:24];
            12:selected=saved_status; 13:selected=saved_length[7:0];
            14:selected=saved_length[15:8]; 15:selected=crc[7:0];
            default:selected=crc[15:8];
        endcase
    end
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            active<=0; start<=0; index<=0; data<=0; saved_seq<=0;
            saved_status<=0; saved_job<=0; saved_length<=0; crc<=16'hffff; waiting<=0;
        end else begin
            start<=0;
            if(!active) begin
                if(request) begin
                    saved_seq<=frame_sequence; saved_job<=job_id; saved_status<=status;
                    saved_length<=length; crc<=16'hffff; index<=0;
                    active<=1; waiting<=0;
                end
            end else if(!waiting && !uart_busy) begin
                data<=selected; start<=1; waiting<=1;
                if(index>=2 && index<=14) crc<=crc_next(crc,selected);
            end else if(waiting && uart_done) begin
                if(index==16) active<=0;
                else begin index<=index+1'b1; waiting<=0; end
            end
        end
    end
endmodule
