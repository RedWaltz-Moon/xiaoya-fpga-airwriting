`timescale 1ns / 1ps

// HT6221/NEC型红外遥控接收与四键事件映射模块。
// 板载HS38B已经输出解调后的低有效脉冲，本模块在50 MHz时钟域先做异步同步，
// 再按9 ms引导码、4.5 ms数据引导间隔和560 us/1.69 ms位间隔接收32位帧。
// 只接受“命令+命令反码”正确的完整帧，并把遥控器数字键1～4映射成单周期事件。
// NEC重复帧和长按重发只维持按下锁，不再次产生事件；静默120 ms后允许同键重触发。
module ht6221_remote_buttons (
    input  wire clk,
    input  wire reset_n,
    input  wire ir_rx,
    output reg  s1_pressed_pulse,
    output reg  s2_pressed_pulse,
    output reg  s3_pressed_pulse,
    output reg  s4_pressed_pulse
);

    // 50 MHz计数门限保留约20%的遥控器、接收头和时钟误差余量。
    localparam [19:0] LEADER_LOW_MIN   = 20'd400_000; // 8.0 ms
    localparam [19:0] LEADER_LOW_MAX   = 20'd500_000; // 10.0 ms
    localparam [19:0] LEADER_HIGH_MIN  = 20'd200_000; // 4.0 ms
    localparam [19:0] LEADER_HIGH_MAX  = 20'd260_000; // 5.2 ms
    localparam [19:0] REPEAT_HIGH_MIN  = 20'd90_000;  // 1.8 ms
    localparam [19:0] REPEAT_HIGH_MAX  = 20'd140_000; // 2.8 ms
    localparam [19:0] BIT_LOW_MIN      = 20'd20_000;  // 0.4 ms
    localparam [19:0] BIT_LOW_MAX      = 20'd36_000;  // 0.72 ms
    localparam [19:0] BIT_ZERO_MIN     = 20'd20_000;  // 0.4 ms
    localparam [19:0] BIT_ZERO_MAX     = 20'd38_000;  // 0.76 ms
    localparam [19:0] BIT_ONE_MIN      = 20'd65_000;  // 1.3 ms
    localparam [19:0] BIT_ONE_MAX      = 20'd100_000; // 2.0 ms
    localparam [19:0] PULSE_TIMEOUT    = 20'd600_000; // 12 ms异常恢复

    localparam [2:0] STATE_IDLE        = 3'd0;
    localparam [2:0] STATE_LEADER_LOW  = 3'd1;
    localparam [2:0] STATE_LEADER_HIGH = 3'd2;
    localparam [2:0] STATE_BIT_LOW     = 3'd3;
    localparam [2:0] STATE_BIT_HIGH    = 3'd4;
    localparam [2:0] STATE_REPEAT_LOW  = 3'd5;

    // F21来自独立红外接收头，与clk50M异步；两级同步后再做边沿和脉宽判断。
    reg ir_meta;
    reg ir_sync;
    reg ir_delay;
    wire ir_falling = ir_delay && !ir_sync;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            ir_meta  <= 1'b1;
            ir_sync  <= 1'b1;
            ir_delay <= 1'b1;
        end else begin
            ir_meta  <= ir_rx;
            ir_sync  <= ir_meta;
            ir_delay <= ir_sync;
        end
    end

    reg [2:0]  state;
    reg [19:0] pulse_count;
    reg [5:0]  bit_index;
    reg [31:0] shift_data;
    reg [7:0]  frame_command;
    reg        frame_valid;
    reg        repeat_valid;

    wire bit_high_is_zero = (pulse_count >= BIT_ZERO_MIN) &&
                            (pulse_count <= BIT_ZERO_MAX);
    wire bit_high_is_one  = (pulse_count >= BIT_ONE_MIN) &&
                            (pulse_count <= BIT_ONE_MAX);
    wire decoded_bit = bit_high_is_one;

    // 数据按LSB先行到达；每次从高位移入后，32次结束时位序恢复为
    // [15:0]地址、[23:16]命令、[31:24]命令反码。
    wire [31:0] completed_frame = {decoded_bit, shift_data[31:1]};
    wire command_inverse_ok =
        (completed_frame[31:24] == ~completed_frame[23:16]);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state         <= STATE_IDLE;
            pulse_count   <= 20'd0;
            bit_index     <= 6'd0;
            shift_data    <= 32'd0;
            frame_command <= 8'd0;
            frame_valid   <= 1'b0;
            repeat_valid  <= 1'b0;
        end else begin
            frame_valid  <= 1'b0;
            repeat_valid <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    pulse_count <= 20'd0;
                    if (ir_falling) begin
                        state       <= STATE_LEADER_LOW;
                        pulse_count <= 20'd1;
                    end
                end

                STATE_LEADER_LOW: begin
                    if (!ir_sync) begin
                        if (pulse_count < PULSE_TIMEOUT)
                            pulse_count <= pulse_count + 1'b1;
                        else begin
                            state       <= STATE_IDLE;
                            pulse_count <= 20'd0;
                        end
                    end else if ((pulse_count >= LEADER_LOW_MIN) &&
                                 (pulse_count <= LEADER_LOW_MAX)) begin
                        state       <= STATE_LEADER_HIGH;
                        pulse_count <= 20'd1;
                    end else begin
                        state       <= STATE_IDLE;
                        pulse_count <= 20'd0;
                    end
                end

                STATE_LEADER_HIGH: begin
                    if (ir_sync) begin
                        if (pulse_count < PULSE_TIMEOUT)
                            pulse_count <= pulse_count + 1'b1;
                        else begin
                            state       <= STATE_IDLE;
                            pulse_count <= 20'd0;
                        end
                    end else if ((pulse_count >= LEADER_HIGH_MIN) &&
                                 (pulse_count <= LEADER_HIGH_MAX)) begin
                        state       <= STATE_BIT_LOW;
                        pulse_count <= 20'd1;
                        bit_index   <= 6'd0;
                        shift_data  <= 32'd0;
                    end else if ((pulse_count >= REPEAT_HIGH_MIN) &&
                                 (pulse_count <= REPEAT_HIGH_MAX)) begin
                        state       <= STATE_REPEAT_LOW;
                        pulse_count <= 20'd1;
                    end else begin
                        state       <= STATE_IDLE;
                        pulse_count <= 20'd0;
                    end
                end

                STATE_BIT_LOW: begin
                    if (!ir_sync) begin
                        if (pulse_count < PULSE_TIMEOUT)
                            pulse_count <= pulse_count + 1'b1;
                        else begin
                            state       <= STATE_IDLE;
                            pulse_count <= 20'd0;
                        end
                    end else if ((pulse_count >= BIT_LOW_MIN) &&
                                 (pulse_count <= BIT_LOW_MAX)) begin
                        state       <= STATE_BIT_HIGH;
                        pulse_count <= 20'd1;
                    end else begin
                        state       <= STATE_IDLE;
                        pulse_count <= 20'd0;
                    end
                end

                STATE_BIT_HIGH: begin
                    if (ir_sync) begin
                        if (pulse_count < PULSE_TIMEOUT)
                            pulse_count <= pulse_count + 1'b1;
                        else begin
                            state       <= STATE_IDLE;
                            pulse_count <= 20'd0;
                        end
                    end else if (bit_high_is_zero || bit_high_is_one) begin
                        shift_data <= completed_frame;
                        if (bit_index == 6'd31) begin
                            state       <= STATE_IDLE;
                            pulse_count <= 20'd0;
                            if (command_inverse_ok) begin
                                frame_command <= completed_frame[23:16];
                                frame_valid   <= 1'b1;
                            end
                        end else begin
                            bit_index   <= bit_index + 1'b1;
                            state       <= STATE_BIT_LOW;
                            pulse_count <= 20'd1;
                        end
                    end else begin
                        state       <= STATE_IDLE;
                        pulse_count <= 20'd0;
                    end
                end

                // 重复帧最后仍有一个约560 us低脉冲；只把它作为长按活动，
                // 不重新发出按键事件，从而避免模式连续翻转或反复清空/确认。
                STATE_REPEAT_LOW: begin
                    if (!ir_sync) begin
                        if (pulse_count < PULSE_TIMEOUT)
                            pulse_count <= pulse_count + 1'b1;
                        else begin
                            state       <= STATE_IDLE;
                            pulse_count <= 20'd0;
                        end
                    end else begin
                        state       <= STATE_IDLE;
                        pulse_count <= 20'd0;
                        if ((pulse_count >= BIT_LOW_MIN) &&
                            (pulse_count <= BIT_LOW_MAX))
                            repeat_valid <= 1'b1;
                    end
                end

                default: begin
                    state       <= STATE_IDLE;
                    pulse_count <= 20'd0;
                end
            endcase
        end
    end

    localparam [22:0] RELEASE_COUNT_MAX = 23'd5_999_999; // 120 ms静默
    reg [22:0] release_count;
    reg [7:0]  locked_command;
    reg        command_locked;

    // 只映射官方数字键1～4。地址字段暂不写死，避免未知地址造成官方遥控器失效；
    // 完整脉宽、32位帧、命令反码和有限命令集合共同承担首版抗误触发门禁。
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            release_count     <= 23'd0;
            locked_command    <= 8'd0;
            command_locked    <= 1'b0;
            s1_pressed_pulse  <= 1'b0;
            s2_pressed_pulse  <= 1'b0;
            s3_pressed_pulse  <= 1'b0;
            s4_pressed_pulse  <= 1'b0;
        end else begin
            s1_pressed_pulse <= 1'b0;
            s2_pressed_pulse <= 1'b0;
            s3_pressed_pulse <= 1'b0;
            s4_pressed_pulse <= 1'b0;

            if (frame_valid || repeat_valid) begin
                release_count <= 23'd0;
            end else if (command_locked) begin
                if (release_count == RELEASE_COUNT_MAX) begin
                    release_count  <= 23'd0;
                    command_locked <= 1'b0;
                end else begin
                    release_count <= release_count + 1'b1;
                end
            end else begin
                release_count <= 23'd0;
            end

            if (frame_valid) begin
                case (frame_command)
                    8'h0C, 8'h18, 8'h5E, 8'h08: begin
                        if (!command_locked || (frame_command != locked_command)) begin
                            case (frame_command)
                                8'h0C: s1_pressed_pulse <= 1'b1;
                                8'h18: s2_pressed_pulse <= 1'b1;
                                8'h5E: s3_pressed_pulse <= 1'b1;
                                8'h08: s4_pressed_pulse <= 1'b1;
                                default: ;
                            endcase
                            locked_command <= frame_command;
                            command_locked <= 1'b1;
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

endmodule
