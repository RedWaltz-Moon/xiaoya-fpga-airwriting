`timescale 1ns / 1ps

// 冻结轨迹快照的包围框归一化与等弧长重采样。
// 输入最多256个有序点；点21的connected=0表示当前点与前一点之间不累计长度，
// 可避免检测确认大跳变时在数据轨迹中插入一整条虚假长线。
// 输出固定64个8位X/Y点，保持长宽比并在0..255方形坐标中居中。
module trajectory_resampler #(
    parameter [8:0]  MIN_RAW_POINTS     = 9'd8,
    parameter [10:0] MIN_STROKE_SPAN    = 11'd48,
    parameter [18:0] MIN_STROKE_LENGTH  = 19'd64
) (
    input  wire        clk,
    input  wire        reset_n,
    input  wire        snapshot_toggle_async,
    input  wire [8:0]  snapshot_count_async,
    output reg  [7:0]  raw_read_addr,
    input  wire [21:0] raw_read_data,

    input  wire [5:0]  point_read_addr,
    output reg  [15:0] point_read_data,
    output reg         points_ready
);

    localparam [4:0] ST_IDLE               = 5'd0;
    localparam [4:0] ST_SCAN_WAIT1         = 5'd1;
    localparam [4:0] ST_SCAN_WAIT2         = 5'd2;
    localparam [4:0] ST_SCAN_CONSUME       = 5'd3;
    localparam [4:0] ST_SCAN_FINISH        = 5'd4;
    localparam [4:0] ST_STEP_START         = 5'd5;
    localparam [4:0] ST_STEP_WAIT          = 5'd6;
    localparam [4:0] ST_FIRST_WAIT1        = 5'd7;
    localparam [4:0] ST_FIRST_WAIT2        = 5'd8;
    localparam [4:0] ST_FIRST_CONSUME      = 5'd9;
    localparam [4:0] ST_NORM_X_START       = 5'd10;
    localparam [4:0] ST_NORM_X_WAIT        = 5'd11;
    localparam [4:0] ST_NORM_Y_START       = 5'd12;
    localparam [4:0] ST_NORM_Y_WAIT        = 5'd13;
    localparam [4:0] ST_STORE_POINT        = 5'd14;
    localparam [4:0] ST_FIND_SEGMENT       = 5'd15;
    localparam [4:0] ST_SEGMENT_WAIT1      = 5'd16;
    localparam [4:0] ST_SEGMENT_WAIT2      = 5'd17;
    localparam [4:0] ST_SEGMENT_CONSUME    = 5'd18;
    localparam [4:0] ST_INTERPOLATE_START  = 5'd19;
    localparam [4:0] ST_INTERPOLATE_WAIT   = 5'd20;

    reg [4:0] state;

    // snapshot_toggle跨域；点数与RAM在发送端冻结，经过两拍后与事件一起取样。
    reg [2:0] snapshot_toggle_sync;
    reg [8:0] snapshot_count_sync0;
    reg [8:0] snapshot_count_sync1;
    reg       snapshot_seen;

    reg [7:0] raw_last_index;
    reg [7:0] scan_index;
    reg [10:0] scan_prev_x;
    reg [9:0]  scan_prev_y;
    reg [10:0] first_x;
    reg [9:0]  first_y;
    reg [10:0] min_x;
    reg [10:0] max_x;
    reg [9:0]  min_y;
    reg [9:0]  max_y;
    reg [18:0] total_length;
    reg [10:0] span_x;
    reg [10:0] span_y;
    reg [10:0] max_span;

    reg [18:0] step_base;
    reg [5:0]  step_remainder;
    reg [5:0]  target_remainder_accum;
    reg [18:0] target_distance;
    reg [18:0] cumulative_length;
    reg [5:0]  output_index;

    reg [7:0]  traverse_index;
    reg [10:0] segment_prev_x;
    reg [9:0]  segment_prev_y;
    reg [10:0] segment_cur_x;
    reg [9:0]  segment_cur_y;
    reg [10:0] segment_dx;
    reg [9:0]  segment_dy;
    reg [11:0] segment_length;
    reg        segment_x_increase;
    reg        segment_y_increase;
    reg        segment_connected;
    reg        segment_loaded;
    reg [11:0] segment_offset;

    reg [10:0] interpolated_x;
    reg [9:0]  interpolated_y;
    reg [7:0]  normalized_x;
    reg [7:0]  normalized_y;

    (* syn_ramstyle = "block_ram" *) reg [15:0] normalized_points [0:63];
    always @(posedge clk) begin
        point_read_data <= normalized_points[point_read_addr];
    end

    reg        divider_start;
    reg [31:0] divider_dividend;
    reg [31:0] divider_divisor;
    wire       divider_busy;
    wire       divider_done;
    wire [31:0] divider_quotient;
    wire [31:0] divider_remainder;
    unsigned_divider_32 u_divider (
        .clk(clk), .reset_n(reset_n), .start(divider_start),
        .dividend(divider_dividend), .divisor(divider_divisor),
        .busy(divider_busy), .done(divider_done),
        .quotient(divider_quotient), .remainder(divider_remainder)
    );

    wire [10:0] loaded_x = raw_read_data[20:10];
    wire [9:0]  loaded_y = raw_read_data[9:0];
    wire [10:0] loaded_dx = (loaded_x >= segment_prev_x) ?
                              loaded_x - segment_prev_x : segment_prev_x - loaded_x;
    wire [9:0] loaded_dy = (loaded_y >= segment_prev_y) ?
                            loaded_y - segment_prev_y : segment_prev_y - loaded_y;
    wire [11:0] loaded_length = {1'b0, loaded_dx} + {2'b0, loaded_dy};
    wire [10:0] scan_dx = (loaded_x >= scan_prev_x) ?
                           loaded_x - scan_prev_x : scan_prev_x - loaded_x;
    wire [9:0] scan_dy = (loaded_y >= scan_prev_y) ?
                          loaded_y - scan_prev_y : scan_prev_y - loaded_y;
    wire [11:0] scan_segment_length = {1'b0, scan_dx} + {2'b0, scan_dy};
    wire [10:0] scanned_span_x = max_x - min_x;
    wire [10:0] scanned_span_y = {1'b0, max_y - min_y};
    wire [10:0] scanned_max_span = (scanned_span_x >= scanned_span_y) ?
                                    scanned_span_x : scanned_span_y;
    wire [19:0] segment_end_distance =
        {1'b0, cumulative_length} + {8'd0, segment_length};
    wire [6:0] next_remainder_sum =
        {1'b0, target_remainder_accum} + {1'b0, step_remainder};
    wire [19:0] interpolated_x_product = segment_dx * divider_quotient[8:0];
    wire [18:0] interpolated_y_product = segment_dy * divider_quotient[8:0];

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state                    <= ST_IDLE;
            snapshot_toggle_sync     <= 3'b000;
            snapshot_count_sync0     <= 9'd0;
            snapshot_count_sync1     <= 9'd0;
            snapshot_seen            <= 1'b0;
            raw_read_addr            <= 8'd0;
            raw_last_index           <= 8'd0;
            scan_index               <= 8'd0;
            scan_prev_x              <= 11'd0;
            scan_prev_y              <= 10'd0;
            first_x                  <= 11'd0;
            first_y                  <= 10'd0;
            min_x                    <= 11'd0;
            max_x                    <= 11'd0;
            min_y                    <= 10'd0;
            max_y                    <= 10'd0;
            total_length             <= 19'd0;
            span_x                   <= 11'd0;
            span_y                   <= 11'd0;
            max_span                 <= 11'd0;
            step_base                <= 19'd0;
            step_remainder           <= 6'd0;
            target_remainder_accum   <= 6'd0;
            target_distance          <= 19'd0;
            cumulative_length        <= 19'd0;
            output_index             <= 6'd0;
            traverse_index           <= 8'd0;
            segment_prev_x           <= 11'd0;
            segment_prev_y           <= 10'd0;
            segment_cur_x            <= 11'd0;
            segment_cur_y            <= 10'd0;
            segment_dx               <= 11'd0;
            segment_dy               <= 10'd0;
            segment_length           <= 12'd0;
            segment_x_increase       <= 1'b1;
            segment_y_increase       <= 1'b1;
            segment_connected        <= 1'b0;
            segment_loaded           <= 1'b0;
            segment_offset           <= 12'd0;
            interpolated_x           <= 11'd0;
            interpolated_y           <= 10'd0;
            normalized_x             <= 8'd0;
            normalized_y             <= 8'd0;
            divider_start            <= 1'b0;
            divider_dividend         <= 32'd0;
            divider_divisor          <= 32'd1;
            points_ready             <= 1'b0;
        end else begin
            snapshot_toggle_sync <= {snapshot_toggle_sync[1:0], snapshot_toggle_async};
            snapshot_count_sync0 <= snapshot_count_async;
            snapshot_count_sync1 <= snapshot_count_sync0;
            divider_start        <= 1'b0;
            points_ready         <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (snapshot_toggle_sync[2] != snapshot_seen) begin
                        snapshot_seen <= snapshot_toggle_sync[2];
                        if (snapshot_count_sync1 >= MIN_RAW_POINTS) begin
                            raw_last_index <= snapshot_count_sync1[7:0] - 1'b1;
                            scan_index     <= 8'd0;
                            raw_read_addr  <= 8'd0;
                            total_length   <= 19'd0;
                            state          <= ST_SCAN_WAIT1;
                        end
                    end
                end

                ST_SCAN_WAIT1: state <= ST_SCAN_WAIT2;
                ST_SCAN_WAIT2: state <= ST_SCAN_CONSUME;

                ST_SCAN_CONSUME: begin
                    if (scan_index == 8'd0) begin
                        first_x     <= loaded_x;
                        first_y     <= loaded_y;
                        min_x       <= loaded_x;
                        max_x       <= loaded_x;
                        min_y       <= loaded_y;
                        max_y       <= loaded_y;
                        scan_prev_x <= loaded_x;
                        scan_prev_y <= loaded_y;
                    end else begin
                        if (loaded_x < min_x) min_x <= loaded_x;
                        if (loaded_x > max_x) max_x <= loaded_x;
                        if (loaded_y < min_y) min_y <= loaded_y;
                        if (loaded_y > max_y) max_y <= loaded_y;
                        if (raw_read_data[21])
                            total_length <= total_length + scan_segment_length;
                        scan_prev_x <= loaded_x;
                        scan_prev_y <= loaded_y;
                    end

                    if (scan_index == raw_last_index) begin
                        state <= ST_SCAN_FINISH;
                    end else begin
                        scan_index    <= scan_index + 1'b1;
                        raw_read_addr <= scan_index + 1'b1;
                        state         <= ST_SCAN_WAIT1;
                    end
                end

                ST_SCAN_FINISH: begin
                    span_x   <= scanned_span_x;
                    span_y   <= scanned_span_y;
                    max_span <= scanned_max_span;
                    // 只有点数而没有实际位移时，摄像头亚像素抖动也会积累出许多点；
                    // 若直接归一化会把这团小抖动放大到全坐标范围。跨度和总路程
                    // 必须同时达标才发送，48/64像素抑制原地晃动，同时最大单轴
                    // 判定仍允许数字1、字母I等窄长字符通过。
                    if ((scanned_max_span < MIN_STROKE_SPAN) ||
                        (total_length < MIN_STROKE_LENGTH))
                        state <= ST_IDLE;
                    else
                        state <= ST_STEP_START;
                end

                ST_STEP_START: begin
                    divider_dividend <= {13'd0, total_length};
                    divider_divisor  <= 32'd63;
                    divider_start    <= 1'b1;
                    state            <= ST_STEP_WAIT;
                end

                ST_STEP_WAIT: begin
                    if (divider_done) begin
                        step_base              <= divider_quotient[18:0];
                        step_remainder         <= divider_remainder[5:0];
                        target_remainder_accum <= 6'd0;
                        target_distance        <= 19'd0;
                        cumulative_length      <= 19'd0;
                        output_index           <= 6'd0;
                        traverse_index         <= 8'd0;
                        segment_loaded         <= 1'b0;
                        raw_read_addr          <= 8'd0;
                        state                  <= ST_FIRST_WAIT1;
                    end
                end

                ST_FIRST_WAIT1: state <= ST_FIRST_WAIT2;
                ST_FIRST_WAIT2: state <= ST_FIRST_CONSUME;

                ST_FIRST_CONSUME: begin
                    segment_prev_x <= loaded_x;
                    segment_prev_y <= loaded_y;
                    interpolated_x <= loaded_x;
                    interpolated_y <= loaded_y;
                    state          <= ST_NORM_X_START;
                end

                ST_NORM_X_START: begin
                    if (max_span == 11'd0) begin
                        normalized_x <= 8'd127;
                        normalized_y <= 8'd127;
                        state        <= ST_STORE_POINT;
                    end else begin
                        // ((x-min_x)*255 + (max_span-span_x)*255/2) / max_span
                        divider_dividend <=
                            ((interpolated_x - min_x) * 32'd255) +
                            (((max_span - span_x) * 32'd255) >> 1);
                        divider_divisor <= {21'd0, max_span};
                        divider_start   <= 1'b1;
                        state           <= ST_NORM_X_WAIT;
                    end
                end

                ST_NORM_X_WAIT: begin
                    if (divider_done) begin
                        normalized_x <= (divider_quotient > 32'd255) ?
                                        8'd255 : divider_quotient[7:0];
                        state <= ST_NORM_Y_START;
                    end
                end

                ST_NORM_Y_START: begin
                    divider_dividend <=
                        (({1'b0, interpolated_y} - {1'b0, min_y}) * 32'd255) +
                        (((max_span - span_y) * 32'd255) >> 1);
                    divider_divisor <= {21'd0, max_span};
                    divider_start   <= 1'b1;
                    state           <= ST_NORM_Y_WAIT;
                end

                ST_NORM_Y_WAIT: begin
                    if (divider_done) begin
                        normalized_y <= (divider_quotient > 32'd255) ?
                                        8'd255 : divider_quotient[7:0];
                        state <= ST_STORE_POINT;
                    end
                end

                ST_STORE_POINT: begin
                    normalized_points[output_index] <= {normalized_x, normalized_y};
                    if (output_index == 6'd63) begin
                        points_ready <= 1'b1;
                        state        <= ST_IDLE;
                    end else begin
                        output_index <= output_index + 1'b1;
                        target_distance <= target_distance + step_base +
                                           ((next_remainder_sum >= 7'd63) ? 1'b1 : 1'b0);
                        target_remainder_accum <= (next_remainder_sum >= 7'd63) ?
                                                  next_remainder_sum - 7'd63 :
                                                  next_remainder_sum[5:0];
                        if (total_length == 19'd0) begin
                            interpolated_x <= first_x;
                            interpolated_y <= first_y;
                            state          <= ST_NORM_X_START;
                        end else begin
                            state <= ST_FIND_SEGMENT;
                        end
                    end
                end

                ST_FIND_SEGMENT: begin
                    if (!segment_loaded) begin
                        if (traverse_index == raw_last_index) begin
                            // 数值舍入或断段走到末尾时钳到最后一点，保证必定输出64点。
                            interpolated_x <= segment_prev_x;
                            interpolated_y <= segment_prev_y;
                            state          <= ST_NORM_X_START;
                        end else begin
                            traverse_index <= traverse_index + 1'b1;
                            raw_read_addr  <= traverse_index + 1'b1;
                            state          <= ST_SEGMENT_WAIT1;
                        end
                    end else if (!segment_connected || (segment_length == 12'd0)) begin
                        segment_prev_x <= segment_cur_x;
                        segment_prev_y <= segment_cur_y;
                        segment_loaded <= 1'b0;
                    end else if ({1'b0, target_distance} <= segment_end_distance) begin
                        segment_offset <= target_distance - cumulative_length;
                        if (target_distance == cumulative_length) begin
                            interpolated_x <= segment_prev_x;
                            interpolated_y <= segment_prev_y;
                            state          <= ST_NORM_X_START;
                        end else if ({1'b0, target_distance} == segment_end_distance) begin
                            interpolated_x <= segment_cur_x;
                            interpolated_y <= segment_cur_y;
                            state          <= ST_NORM_X_START;
                        end else begin
                            state <= ST_INTERPOLATE_START;
                        end
                    end else begin
                        cumulative_length <= cumulative_length + segment_length;
                        segment_prev_x    <= segment_cur_x;
                        segment_prev_y    <= segment_cur_y;
                        segment_loaded    <= 1'b0;
                    end
                end

                ST_SEGMENT_WAIT1: state <= ST_SEGMENT_WAIT2;
                ST_SEGMENT_WAIT2: state <= ST_SEGMENT_CONSUME;

                ST_SEGMENT_CONSUME: begin
                    segment_cur_x      <= loaded_x;
                    segment_cur_y      <= loaded_y;
                    segment_dx         <= loaded_dx;
                    segment_dy         <= loaded_dy;
                    segment_length     <= loaded_length;
                    segment_x_increase <= loaded_x >= segment_prev_x;
                    segment_y_increase <= loaded_y >= segment_prev_y;
                    segment_connected  <= raw_read_data[21];
                    segment_loaded     <= 1'b1;
                    state              <= ST_FIND_SEGMENT;
                end

                ST_INTERPOLATE_START: begin
                    // frac_256=(目标在本段内距离/本段长度)*256，范围0..256。
                    divider_dividend <= {12'd0, segment_offset, 8'd0};
                    divider_divisor  <= {20'd0, segment_length};
                    divider_start    <= 1'b1;
                    state            <= ST_INTERPOLATE_WAIT;
                end

                ST_INTERPOLATE_WAIT: begin
                    if (divider_done) begin
                        if (segment_x_increase)
                            interpolated_x <= segment_prev_x + interpolated_x_product[19:8];
                        else
                            interpolated_x <= segment_prev_x - interpolated_x_product[19:8];
                        if (segment_y_increase)
                            interpolated_y <= segment_prev_y + interpolated_y_product[18:8];
                        else
                            interpolated_y <= segment_prev_y - interpolated_y_product[18:8];
                        state <= ST_NORM_X_START;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
