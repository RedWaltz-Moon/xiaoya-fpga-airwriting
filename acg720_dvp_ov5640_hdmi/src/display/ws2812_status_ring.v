`timescale 1ns / 1ps

// 十六灯板端状态显示：所有输入已在50MHz域，只读观察，不给原管线施加反压。
// 灯色只表示板端状态，合法回传不等于游戏答对，打印结束也不等于纸张成功输出。
// 每20ms刷新；每帧锁存状态/亮度/灯号，串行输出途中改变输入不会撕裂同一帧。
module ws2812_status_ring #(
    parameter [15:0] MS_LAST = 16'd49_999
) (
    input wire clk,
    input wire reset_n,
    input wire [1:0] boot_state,
    input wire hand_mode,
    input wire result_armed,
    input wire result_valid,
    input wire clear_request,
    input wire printer_active,
    output wire dout
);
    // 16颗灯编号0～15；同一终点同时用于发送器、跑马回绕和0号灯的尾点。
    localparam [3:0] LED_LAST = 4'd15;
    localparam [2:0] RING_OFF = 3'd0, RING_BOOT = 3'd1,
                     RING_PEN = 3'd2, RING_HAND = 3'd3,
                     RING_WAIT = 3'd4, RING_DONE = 3'd5,
                     RING_PRINT = 3'd6, RING_FAULT = 3'd7;
    reg [15:0] ms_count;
    reg [4:0] refresh_count;
    reg [5:0] animation_phase;
    reg [2:0] chase_count;
    reg [3:0] chase_head;
    reg [9:0] result_hold_ms;
    reg result_valid_d;
    reg refresh_pending;
    reg first_frame;
    reg frame_start;
    reg [2:0] frame_state;
    reg [3:0] frame_level;
    reg [3:0] frame_head;
    reg frame_blink;
    wire tx_busy;
    wire [3:0] pixel_index;
    wire ms_tick = ms_count == MS_LAST;
    wire result_event = result_valid && !result_valid_d;
    wire [3:0] breathe_level = animation_phase[5] ?
        4'd8 - {1'b0, animation_phase[4:2]} : {1'b0, animation_phase[4:2]} + 4'd1;

    // 自检故障最高优先；打印为独立覆盖，不改变原DRAW/WAIT/DONE生命周期。
    wire [2:0] selected_state = boot_state == 2'd2 ? RING_FAULT :
        boot_state != 2'd1 ? RING_BOOT : printer_active ? RING_PRINT :
        result_valid ? RING_DONE : result_armed ? RING_WAIT :
        hand_mode ? RING_HAND : RING_PEN;
    wire [3:0] selected_level = selected_state == RING_DONE ?
        ((result_hold_ms != 10'd0 || result_event) ? 4'd8 : 4'd2) :
        ((selected_state == RING_PEN || selected_state == RING_HAND) ? breathe_level : 4'd8);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            ms_count <= 16'd0;
            refresh_count <= 5'd0;
            animation_phase <= 6'd0;
            chase_count <= 3'd0;
            chase_head <= 4'd0;
            result_hold_ms <= 10'd0;
            result_valid_d <= 1'b0;
            refresh_pending <= 1'b1;
            first_frame <= 1'b1;
            frame_start <= 1'b0;
            frame_state <= RING_OFF;
            frame_level <= 4'd0;
            frame_head <= 4'd0;
            frame_blink <= 1'b0;
        end else begin
            frame_start <= 1'b0;
            result_valid_d <= result_valid;
            // result_valid是保持电平，只在上升沿点亮800ms，不能每拍重复续期。
            // 清空/切模式取消旧回传亮灯，但不取消打印桥已接受的打印任务。
            if (clear_request || boot_state != 2'd1)
                result_hold_ms <= 10'd0;
            else if (result_event)
                result_hold_ms <= 10'd800;
            else if (ms_tick && result_hold_ms != 10'd0)
                result_hold_ms <= result_hold_ms - 1'b1;

            if (ms_tick) begin
                ms_count <= 16'd0;
                if (refresh_count == 5'd19) begin
                    refresh_count <= 5'd0;
                    animation_phase <= animation_phase + 1'b1;
                    refresh_pending <= 1'b1;
                    if (chase_count == 3'd4) begin
                        chase_count <= 3'd0;
                        chase_head <= chase_head == LED_LAST ? 4'd0 : chase_head + 1'b1;
                    end else chase_count <= chase_count + 1'b1;
                end else refresh_count <= refresh_count + 1'b1;
            end else ms_count <= ms_count + 1'b1;

            // 只在串行器空闲时提交快照；start保持一拍，下一拍由串行器接受。
            if (!tx_busy && !frame_start && refresh_pending && !clear_request) begin
                frame_start <= 1'b1;
                refresh_pending <= 1'b0;
                frame_state <= first_frame ? RING_OFF : selected_state;
                frame_level <= first_frame ? 4'd0 : selected_level;
                frame_head <= chase_head;
                frame_blink <= animation_phase[4];
                first_frame <= 1'b0;
            end
        end
    end

    // 通道最大仅8/255，亮度1～8整数渐变，无乘法、除法和附加PWM时钟。
    // 跑马仅一个亮点及一个2/255尾点；LED编号沿DIN到DOUT的物理级联方向。
    wire [3:0] previous_head = frame_head == 4'd0 ? LED_LAST : frame_head - 1'b1;
    wire [7:0] chase_level = pixel_index == frame_head ? {4'd0, frame_level} :
        (pixel_index == previous_head ? 8'd2 : 8'd0);
    reg [7:0] red;
    reg [7:0] green;
    reg [7:0] blue;
    always @* begin
        red = 8'd0;
        green = 8'd0;
        blue = 8'd0;
        case (frame_state)
            RING_BOOT: blue = chase_level;
            RING_PEN: begin green = {4'd0, frame_level}; blue = {4'd0, frame_level}; end
            RING_HAND: begin red = {4'd0, frame_level}; blue = {4'd0, frame_level}; end
            RING_WAIT: begin red = chase_level; green = chase_level; end
            RING_DONE: green = {4'd0, frame_level};
            RING_PRINT: begin red = chase_level; green = chase_level; blue = chase_level; end
            RING_FAULT: red = frame_blink ? 8'd8 : 8'd0;
            default: begin end
        endcase
    end

    ws2812b_tx #(.LED_LAST(LED_LAST)) u_ws2812b_tx (
        .clk(clk), .reset_n(reset_n), .frame_start(frame_start),
        .pixel_grb({green, red, blue}), .pixel_index(pixel_index),
        .busy(tx_busy), .dout(dout)
    );
endmodule
