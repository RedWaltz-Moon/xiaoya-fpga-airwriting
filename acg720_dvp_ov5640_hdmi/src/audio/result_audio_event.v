`timescale 1ns / 1ps

// 合法回传有效上升沿→短喵事件。50MHz队列通过翻转位/应答跨入像素域，
// 不直接跨域传单拍脉冲；播放忙时保留请求，重复回传保持高电平不重复入队。
// PLL失锁/系统复位共同异步清空；复位释放先采当前有效电平，避免旧DONE重播。
module result_audio_event (
    input wire source_clk,
    input wire source_reset_n,
    input wire result_valid,
    input wire pixel_clk,
    input wire pixel_reset_n,
    input wire player_ready,
    output reg play_start,
    output reg queue_overflow
);
    // HDMI PLL锁定来自另一时钟域；源端同样异步拉低、两拍同步释放复位。
    // 与像素域共用失锁清除条件，但各自按本域时钟恢复，避免复位释放竞态。
    reg [1:0] source_reset_pipe;
    wire source_domain_reset_n = source_reset_pipe[1];
    always @(posedge source_clk or negedge source_reset_n) begin
        if (!source_reset_n) source_reset_pipe <= 2'b00;
        else source_reset_pipe <= {source_reset_pipe[0], 1'b1};
    end
    reg result_valid_d;
    reg source_initialized;
    reg [3:0] pending_count;
    reg request_toggle;
    reg [1:0] ack_sync;
    reg [2:0] request_sync;
    reg ack_toggle;
    wire result_edge = source_initialized && result_valid && !result_valid_d;
    wire dispatch = pending_count != 4'd0 && request_toggle == ack_sync[1];
    always @(posedge source_clk or negedge source_domain_reset_n) begin
        if (!source_domain_reset_n) begin
            result_valid_d <= 1'b0;
            source_initialized <= 1'b0;
            pending_count <= 4'd0;
            request_toggle <= 1'b0;
            ack_sync <= 2'b00;
            queue_overflow <= 1'b0;
        end else begin
            result_valid_d <= result_valid;
            source_initialized <= 1'b1;
            ack_sync <= {ack_sync[0], ack_toggle};
            if (dispatch) request_toggle <= !request_toggle;
            // 请求发出后直到像素域接受均保持翻转位；计数含最多15个待发事件。
            case ({result_edge, dispatch})
                2'b10: begin
                    if (pending_count != 4'd15) pending_count <= pending_count + 1'b1;
                    else queue_overflow <= 1'b1;
                end
                2'b01: pending_count <= pending_count - 1'b1;
                default: pending_count <= pending_count;
            endcase
        end
    end
    always @(posedge pixel_clk or negedge pixel_reset_n) begin
        if (!pixel_reset_n) begin
            request_sync <= 3'b000;
            ack_toggle <= 1'b0;
            play_start <= 1'b0;
        end else begin
            request_sync <= {request_sync[1:0], request_toggle};
            play_start <= 1'b0;
            if (request_sync[2] != ack_toggle && player_ready && !play_start) begin
                play_start <= 1'b1;
                ack_toggle <= request_sync[2];
            end
        end
    end
endmodule
