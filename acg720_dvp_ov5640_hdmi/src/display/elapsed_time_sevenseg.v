`timescale 1ns / 1ps

// 八位共阳数码管运行时间显示。
// 板上两片74HC595按{段码, 位选}级联，16位数据高位先发：
// SEG7_DIO接DS，SEG7_SCLK接SH_CP，SEG7_RCLK接ST_CP。
// 显示格式为DD.HH.MM.SS，日/时/分/秒均使用两位BCD；小数点仅用于分组。
module elapsed_time_sevenseg #(
    parameter [25:0] SECOND_TICK_MAX    = 26'd49_999_999,
    parameter [15:0] DIGIT_REFRESH_MAX = 16'd49_999,
    parameter [1:0]  SHIFT_STEP_MAX     = 2'd1
) (
    input  wire clk,
    input  wire reset_n,
    output reg  seg7_dio,
    output reg  seg7_rclk,
    output reg  seg7_sclk
);

    reg [25:0] second_tick_count;
    reg [3:0]  day_tens;
    reg [3:0]  day_ones;
    reg [3:0]  hour_tens;
    reg [3:0]  hour_ones;
    reg [3:0]  minute_tens;
    reg [3:0]  minute_ones;
    reg [3:0]  second_tens;
    reg [3:0]  second_ones;

    // 只产生1 Hz时钟使能，所有计数寄存器仍由板载50 MHz时钟驱动。
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            second_tick_count <= 26'd0;
            day_tens           <= 4'd0;
            day_ones           <= 4'd0;
            hour_tens          <= 4'd0;
            hour_ones          <= 4'd0;
            minute_tens        <= 4'd0;
            minute_ones        <= 4'd0;
            second_tens        <= 4'd0;
            second_ones        <= 4'd0;
        end else if (second_tick_count == SECOND_TICK_MAX) begin
            second_tick_count <= 26'd0;
            if (second_ones < 4'd9) begin
                second_ones <= second_ones + 1'b1;
            end else begin
                second_ones <= 4'd0;
                if (second_tens < 4'd5) begin
                    second_tens <= second_tens + 1'b1;
                end else begin
                    second_tens <= 4'd0;
                    if (minute_ones < 4'd9) begin
                        minute_ones <= minute_ones + 1'b1;
                    end else begin
                        minute_ones <= 4'd0;
                        if (minute_tens < 4'd5) begin
                            minute_tens <= minute_tens + 1'b1;
                        end else begin
                            minute_tens <= 4'd0;
                            if ((hour_tens == 4'd2) && (hour_ones == 4'd3)) begin
                                hour_tens <= 4'd0;
                                hour_ones <= 4'd0;
                                if ((day_tens == 4'd9) && (day_ones == 4'd9)) begin
                                    day_tens <= 4'd0;
                                    day_ones <= 4'd0;
                                end else if (day_ones < 4'd9) begin
                                    day_ones <= day_ones + 1'b1;
                                end else begin
                                    day_ones <= 4'd0;
                                    day_tens <= day_tens + 1'b1;
                                end
                            end else if (hour_ones < 4'd9) begin
                                hour_ones <= hour_ones + 1'b1;
                            end else begin
                                hour_ones <= 4'd0;
                                hour_tens <= hour_tens + 1'b1;
                            end
                        end
                    end
                end
            end
        end else begin
            second_tick_count <= second_tick_count + 1'b1;
        end
    end

    wire [31:0] display_data = {
        day_tens, day_ones, hour_tens, hour_ones,
        minute_tens, minute_ones, second_tens, second_ones
    };

    reg [15:0] refresh_count;
    reg [2:0]  digit_index;
    reg [3:0]  digit_value;
    reg [7:0]  segment_value;
    reg [15:0] shift_data;
    reg [4:0]  shift_bit_count;
    reg [1:0]  shift_step_count;
    reg        shift_high_phase;
    reg        latch_high_phase;
    reg        shift_busy;

    // digit_index=0对应最右侧秒个位，digit_index=7对应最左侧天十位。
    // 段码低电平点亮、位选高电平有效，编码与板卡官方hex8例程一致。
    always @(*) begin
        case (digit_index)
            3'd0: digit_value = display_data[3:0];
            3'd1: digit_value = display_data[7:4];
            3'd2: digit_value = display_data[11:8];
            3'd3: digit_value = display_data[15:12];
            3'd4: digit_value = display_data[19:16];
            3'd5: digit_value = display_data[23:20];
            3'd6: digit_value = display_data[27:24];
            default: digit_value = display_data[31:28];
        endcase

        case (digit_value)
            4'd0: segment_value = 8'b1100_0000;
            4'd1: segment_value = 8'b1111_1001;
            4'd2: segment_value = 8'b1010_0100;
            4'd3: segment_value = 8'b1011_0000;
            4'd4: segment_value = 8'b1001_1001;
            4'd5: segment_value = 8'b1001_0010;
            4'd6: segment_value = 8'b1000_0010;
            4'd7: segment_value = 8'b1111_1000;
            4'd8: segment_value = 8'b1000_0000;
            4'd9: segment_value = 8'b1001_0000;
            default: segment_value = 8'b1111_1111;
        endcase

        // 天、时、分两位组之后点亮小数点，形成DD.HH.MM.SS的视觉分隔。
        if ((digit_index == 3'd6) || (digit_index == 3'd4) ||
            (digit_index == 3'd2))
            segment_value[7] = 1'b0;
    end

    // 每1 ms启动一次单数位刷新；移位及锁存高/低电平各保持40 ns，
    // 与板卡已验证的digital_tube例程一致，16位数据约1.4 us内完成。
    // 串行发送期间使用shift_data快照，计数恰好跳秒也不会撕裂当前数位。
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            refresh_count    <= 16'd0;
            digit_index      <= 3'd0;
            shift_data       <= 16'd0;
            shift_bit_count  <= 5'd0;
            shift_step_count <= 2'd0;
            shift_high_phase <= 1'b0;
            latch_high_phase <= 1'b0;
            shift_busy       <= 1'b0;
            seg7_dio         <= 1'b0;
            seg7_rclk        <= 1'b0;
            seg7_sclk        <= 1'b0;
        end else begin
            if (refresh_count == DIGIT_REFRESH_MAX) begin
                refresh_count <= 16'd0;
                if (!shift_busy) begin
                    shift_data       <= {segment_value, (8'b0000_0001 << digit_index)};
                    shift_bit_count  <= 5'd0;
                    shift_step_count <= 2'd0;
                    shift_high_phase <= 1'b0;
                    latch_high_phase <= 1'b0;
                    shift_busy       <= 1'b1;
                    seg7_dio         <= segment_value[7];
                    seg7_rclk        <= 1'b0;
                    seg7_sclk        <= 1'b0;
                    digit_index      <= digit_index + 1'b1;
                end
            end else begin
                refresh_count <= refresh_count + 1'b1;
            end

            if (shift_busy) begin
                if (shift_step_count == SHIFT_STEP_MAX) begin
                    shift_step_count <= 2'd0;
                    if (latch_high_phase) begin
                        // ST_CP高电平保持一个完整分频步长后结束本次数位刷新。
                        seg7_rclk        <= 1'b0;
                        latch_high_phase <= 1'b0;
                        shift_busy       <= 1'b0;
                    end else if (!shift_high_phase) begin
                        // 74HC595在SH_CP上升沿采样当前串行数据。
                        seg7_sclk        <= 1'b1;
                        shift_high_phase <= 1'b1;
                    end else begin
                        seg7_sclk <= 1'b0;
                        if (shift_bit_count == 5'd15) begin
                            // 16位全部移入后拉高ST_CP，并在下一分频步长结束时拉低。
                            seg7_rclk        <= 1'b1;
                            latch_high_phase <= 1'b1;
                            shift_high_phase <= 1'b0;
                        end else begin
                            shift_data       <= {shift_data[14:0], 1'b0};
                            seg7_dio         <= shift_data[14];
                            shift_bit_count  <= shift_bit_count + 1'b1;
                            shift_high_phase <= 1'b0;
                        end
                    end
                end else begin
                    shift_step_count <= shift_step_count + 1'b1;
                end
            end
        end
    end

endmodule
