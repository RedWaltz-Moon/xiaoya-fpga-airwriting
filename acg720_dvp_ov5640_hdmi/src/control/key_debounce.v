`timescale 1ns / 1ps

// 单个低有效机械按键的同步与消抖模块。
// 按键先在clk域连续同步两拍；只有新电平持续满20 ms后才更新稳定状态，
// 并在确认按下时产生一个clk周期的pressed_pulse，供上层状态机统一分派功能。
module key_debounce #(
    parameter [19:0] DEBOUNCE_COUNT_MAX = 20'd999_999
) (
    input  wire clk,
    input  wire reset_n,
    input  wire key_n,
    output reg  pressed_pulse
);

    reg [1:0]  key_sync;
    reg [19:0] debounce_count;
    reg        stable_n;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            key_sync       <= 2'b11;
            debounce_count <= 20'd0;
            pressed_pulse  <= 1'b0;
            stable_n       <= 1'b1;
        end else begin
            key_sync      <= {key_sync[0], key_n};
            pressed_pulse <= 1'b0;

            if (key_sync[1] == stable_n) begin
                debounce_count <= 20'd0;
            end else if (debounce_count == DEBOUNCE_COUNT_MAX) begin
                debounce_count <= 20'd0;
                stable_n       <= key_sync[1];
                if (!key_sync[1])
                    pressed_pulse <= 1'b1;
            end else begin
                debounce_count <= debounce_count + 1'b1;
            end
        end
    end

endmodule
