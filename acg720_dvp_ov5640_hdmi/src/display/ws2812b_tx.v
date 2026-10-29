`timescale 1ns / 1ps

// 十六灯WS2812B串行器：固定50MHz参考时钟，GRB高位先发，每灯24位。
// 不产生新时钟，不使用BRAM/DSP；只缓存当前灯的24位，避免整环双缓冲。
// 时序依据WS2812B-V5/W：一位64拍，0高16拍，1高34拍，帧间低350us。
// LED之间LOAD多一拍低电平，0/1的低宽变为980/620ns，仍在该手册范围内。
module ws2812b_tx #(
    // 4位索引覆盖0～15；上层统一传入末灯编号，发送与跑马使用同一边界。
    parameter [3:0] LED_LAST = 4'd15
) (
    input  wire        clk,
    input  wire        reset_n,
    input  wire        frame_start,
    input  wire [23:0] pixel_grb,
    output reg  [3:0]  pixel_index,
    output wire        busy,
    output reg         dout
);
    localparam [1:0] ST_LATCH = 2'd0, ST_IDLE = 2'd1,
                     ST_LOAD  = 2'd2, ST_SEND = 2'd3;
    localparam [5:0] BIT_LAST = 6'd63;
    localparam [5:0] ZERO_HIGH_TICKS = 6'd16;
    localparam [5:0] ONE_HIGH_TICKS  = 6'd34;
    localparam [14:0] RESET_LAST = 15'd17_499;
    reg [1:0] state;
    reg [5:0] bit_cycle;
    reg [4:0] bit_index;
    reg [14:0] reset_count;
    reg [23:0] shift_grb;
    assign busy = state != ST_IDLE;

    // reset_n由顶层异步拉低、50MHz同步释放；先等待复位低电平再接收首帧。
    // frame_start只在!busy接受；pixel_grb在ST_LOAD采样，整帧颜色由上层快照保持。
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= ST_LATCH;
            bit_cycle <= 6'd0;
            bit_index <= 5'd23;
            reset_count <= 15'd0;
            shift_grb <= 24'd0;
            pixel_index <= 4'd0;
            dout <= 1'b0;
        end else begin
            case (state)
                ST_LATCH: begin
                    dout <= 1'b0;
                    if (reset_count == RESET_LAST) begin
                        reset_count <= 15'd0;
                        state <= ST_IDLE;
                    end else reset_count <= reset_count + 1'b1;
                end
                ST_IDLE: begin
                    dout <= 1'b0;
                    if (frame_start) begin
                        pixel_index <= 4'd0;
                        state <= ST_LOAD;
                    end
                end
                ST_LOAD: begin
                    // 上层快照/灯号已稳定一拍，再取下一个完整GRB字，首灯也同样处理。
                    shift_grb <= pixel_grb;
                    bit_index <= 5'd23;
                    bit_cycle <= 6'd0;
                    dout <= 1'b0;
                    state <= ST_SEND;
                end
                ST_SEND: begin
                    dout <= bit_cycle < (shift_grb[23] ? ONE_HIGH_TICKS : ZERO_HIGH_TICKS);
                    if (bit_cycle == BIT_LAST) begin
                        bit_cycle <= 6'd0;
                        if (bit_index == 5'd0) begin
                            if (pixel_index == LED_LAST) begin
                                reset_count <= 15'd0;
                                state <= ST_LATCH;
                            end else begin
                                pixel_index <= pixel_index + 1'b1;
                                state <= ST_LOAD;
                            end
                        end else begin
                            bit_index <= bit_index - 1'b1;
                            shift_grb <= {shift_grb[22:0], 1'b0};
                        end
                    end else bit_cycle <= bit_cycle + 1'b1;
                end
                default: begin
                    dout <= 1'b0;
                    reset_count <= 15'd0;
                    state <= ST_LATCH;
                end
            endcase
        end
    end
endmodule
