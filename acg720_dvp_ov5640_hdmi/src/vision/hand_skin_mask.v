`timescale 1ns / 1ps

// M5B手部前景与单食指指尖调试模块，工作在OV5640 PCLK域。
// HAND只识别蓝色背景布前的绿手套，不再把裸手肤色作为另一颜色入口。
module hand_skin_mask #(
    parameter [7:0] GLOVE_G_MIN = 8'd32,
    parameter [8:0] GLOVE_GREEN_EXCESS_MIN = 9'd28,
    parameter [3:0] FILTER_MIN_HITS = 4'd5,
    parameter [3:0] TIP_FILTER_MIN_HITS = 4'd6,
    parameter [19:0] HAND_MIN_AREA = 20'd2500,
    parameter [19:0] HAND_MAX_AREA = 20'd250000,
    parameter [10:0] HAND_MIN_WIDTH = 11'd48,
    parameter [10:0] GLOVE_MIN_HEIGHT = 11'd72,
    parameter [10:0] TIP_BAND_HEIGHT = 11'd16,
    parameter [10:0] TIP_MAX_WIDTH = 11'd96,
    parameter [10:0] TIP_TRACK_RADIUS = 11'd160,
    parameter [10:0] FINGER_ROW_MAX_WIDTH = 11'd72,
    parameter [7:0]  GLOVE_FINGER_MIN_ROWS = 8'd40,
    parameter [10:0] TIP_CONFIRM_RADIUS = 11'd64
) (
    input  wire        pclk,
    input  wire        reset_n,
    input  wire        frame_valid,
    input  wire        pixel_valid,
    input  wire [10:0] pixel_x,
    input  wire [10:0] pixel_y,
    input  wire [15:0] pixel_in,
    input  wire        hand_mode_enable,
    input  wire        debug_mask_enable,
    input  wire        threshold_decrease,
    input  wire        threshold_increase,
    input  wire        trajectory_clear,
    input  wire        trajectory_confirm,
    output wire        frame_valid_out,
    output wire        pixel_valid_out,
    output wire [15:0] pixel_out,
    output reg         fingertip_valid,
    output reg  [10:0] fingertip_x,
    output reg  [9:0]  fingertip_y,
    output reg         fingertip_sample_valid,
    output reg         fingertip_sample_connected,
    output reg  [10:0] fingertip_sample_x,
    output reg  [9:0]  fingertip_sample_y,
    output reg         gesture_confirm_pulse,
    output reg         gesture_clear_pulse
);

    wire [7:0] red8   = {pixel_in[15:11], pixel_in[15:13]};
    wire [7:0] green8 = {pixel_in[10:5],  pixel_in[10:9]};
    wire [7:0] blue8  = {pixel_in[4:0],   pixel_in[4:2]};

    // 捕获与跟踪使用同一套全帧严格绿色门禁。小噪点由后级逐候选面积过滤，
    // 不再用矩形ROI裁剪mask；近白手套与白墙不可可靠区分，极边缘漂白仍不处理。
    wire [8:0] green_x2 = {green8, 1'b0};
    wire [8:0] red_blue_sum = {1'b0, red8} + {1'b0, blue8};

    // S3/S4联动调节三项绿色优势：总差门限每次变4，单通道色差每次变2。
    // 总差限制在16～40，对应单通道差6～18；复位28/12，避免过度接纳近白墙面。
    // 请求值在PCLK域更新，实际判定值只在场消隐期间锁存，避免帧中途换阈值。
    reg [8:0] green_excess_requested;
    reg [8:0] green_excess_active;
    always @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            green_excess_requested <= GLOVE_GREEN_EXCESS_MIN;
            green_excess_active <= GLOVE_GREEN_EXCESS_MIN;
        end else begin
            if (threshold_decrease && !threshold_increase && hand_mode_enable &&
                (green_excess_requested > 9'd16))
                green_excess_requested <= green_excess_requested - 9'd4;
            else if (threshold_increase && !threshold_decrease && hand_mode_enable &&
                     (green_excess_requested < 9'd40))
                green_excess_requested <= green_excess_requested + 9'd4;
            if (!frame_valid)
                green_excess_active <= green_excess_requested;
        end
    end

    // 由同一个帧间锁存值派生两项色差，防止用户调参后总差门限被固定的
    // G-R/G-B门限架空。28对应12，16对应6，40对应18。
    wire [7:0] green_channel_diff_active = green_excess_active[8:1] - 8'd2;

    wire raw_glove_capture = (green8 >= GLOVE_G_MIN) &&
                             ({1'b0, green8} >
                              ({1'b0, red8} + {1'b0, green_channel_diff_active})) &&
                             ({1'b0, green8} >
                              ({1'b0, blue8} + {1'b0, green_channel_diff_active})) &&
                             ({1'b0, green_x2} >
                              ({1'b0, red_blue_sum} + {1'b0, green_excess_active}));
    wire raw_glove_color = raw_glove_capture;
    wire raw_hand_color = hand_mode_enable && raw_glove_color;

    // 第一拍保存像素、坐标、模式和原始手部mask。
    reg        frame_valid_d;
    reg        pixel_valid_d;
    reg [10:0] pixel_x_d;
    reg [10:0] pixel_y_d;
    reg [15:0] pixel_in_d;
    reg        raw_hand_color_d;
    reg        hand_mode_d;
    reg        debug_mask_d;
    always @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            frame_valid_d <= 1'b0;
            pixel_valid_d <= 1'b0;
            pixel_x_d     <= 11'd0;
            pixel_y_d     <= 11'd0;
            pixel_in_d    <= 16'd0;
            raw_hand_color_d <= 1'b0;
            hand_mode_d   <= 1'b0;
            debug_mask_d  <= 1'b0;
        end else begin
            frame_valid_d <= frame_valid;
            pixel_valid_d <= pixel_valid;
            hand_mode_d   <= hand_mode_enable;
            debug_mask_d  <= debug_mask_enable;
            if (pixel_valid) begin
                pixel_x_d  <= pixel_x;
                pixel_y_d  <= pixel_y;
                pixel_in_d <= pixel_in;
                raw_hand_color_d <= raw_hand_color;
            end
        end
    end

    wire foreground_hand_d = raw_hand_color_d;

    // 原始手部结果单独打一拍，切断颜色组合判定与3×3求和到像素输出的长路径。
    // 坐标、原图、模式和有效信号同步延迟，保证调试mask与像素对应。
    reg        frame_valid_filter_d;
    reg        pixel_valid_filter_d;
    reg [10:0] pixel_x_filter_d;
    reg [10:0] pixel_y_filter_d;
    reg [15:0] pixel_in_filter_d;
    reg        foreground_hand_filter_d;
    reg        hand_mode_filter_d;
    reg        debug_mask_filter_d;
    always @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            frame_valid_filter_d    <= 1'b0;
            pixel_valid_filter_d    <= 1'b0;
            pixel_x_filter_d        <= 11'd0;
            pixel_y_filter_d        <= 11'd0;
            pixel_in_filter_d       <= 16'd0;
            foreground_hand_filter_d <= 1'b0;
            hand_mode_filter_d      <= 1'b0;
            debug_mask_filter_d     <= 1'b0;
        end else begin
            frame_valid_filter_d <= frame_valid_d;
            pixel_valid_filter_d <= pixel_valid_d;
            hand_mode_filter_d   <= hand_mode_d;
            debug_mask_filter_d  <= debug_mask_d;
            if (pixel_valid_d) begin
                pixel_x_filter_d         <= pixel_x_d;
                pixel_y_filter_d         <= pixel_y_d;
                pixel_in_filter_d        <= pixel_in_d;
                foreground_hand_filter_d <= foreground_hand_d;
            end
        end
    end

    // 每个X地址用bit1/bit0保存上一行和上上行mask。复用M3已验证的2K×8 SDPB，
    // 第二个实例占用独立块RAM，不修改厂商生成IP文件。
    wire [7:0] line_history_q;
    wire [7:0] line_history_write = {6'd0, foreground_hand_filter_d,
                                     line_history_q[1]};
    mask_line_buffer_sdpb u_hand_mask_line_buffer (
        .dout (line_history_q),
        .clka (pclk),
        .cea  (pixel_valid_filter_d),
        .clkb (pclk),
        .ceb  (pixel_valid_d),
        .oce  (1'b1),
        .reset(~reset_n),
        .ada  (pixel_x_filter_d),
        .din  (line_history_write),
        .adb  (pixel_x_d)
    );

    reg row_m2_x2;
    reg row_m2_x1;
    reg row_m1_x2;
    reg row_m1_x1;
    reg row_now_x2;
    reg row_now_x1;
    wire [3:0] window_hits =
        {3'd0, row_m2_x2}  + {3'd0, row_m2_x1}  + {3'd0, line_history_q[0]} +
        {3'd0, row_m1_x2}  + {3'd0, row_m1_x1}  + {3'd0, line_history_q[1]} +
        {3'd0, row_now_x2} + {3'd0, row_now_x1} +
        {3'd0, foreground_hand_filter_d};

    always @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            row_m2_x2  <= 1'b0;
            row_m2_x1  <= 1'b0;
            row_m1_x2  <= 1'b0;
            row_m1_x1  <= 1'b0;
            row_now_x2 <= 1'b0;
            row_now_x1 <= 1'b0;
        end else if (pixel_valid_filter_d) begin
            if (pixel_x_filter_d == 11'd0) begin
                row_m2_x2  <= 1'b0;
                row_m1_x2  <= 1'b0;
                row_now_x2 <= 1'b0;
                row_m2_x1  <= line_history_q[0];
                row_m1_x1  <= line_history_q[1];
                row_now_x1 <= foreground_hand_filter_d;
            end else begin
                row_m2_x2  <= row_m2_x1;
                row_m1_x2  <= row_m1_x1;
                row_now_x2 <= row_now_x1;
                row_m2_x1  <= line_history_q[0];
                row_m1_x1  <= line_history_q[1];
                row_now_x1 <= foreground_hand_filter_d;
            end
        end
    end

    // HAND继续使用5/9完整mask和6/9严格mask。局部多数过滤先清除
    // 孤立像素，后续逐候选面积门禁再过滤仍然成团的小噪点。
    wire filtered_hand = pixel_valid_filter_d && (pixel_x_filter_d >= 11'd2) &&
                          (pixel_y_filter_d >= 11'd2) &&
                          (window_hits >= FILTER_MIN_HITS);
    wire fingertip_hand = pixel_valid_filter_d && (pixel_x_filter_d >= 11'd2) &&
                          (pixel_y_filter_d >= 11'd2) &&
                          (window_hits >= TIP_FILTER_MIN_HITS);

    // 单食指书写时手腕从画面下方进入。完整轮廓统计手部包围框和面积；
    // 严格轮廓另外提取顶部首行中心与连续窄行，用于排除上方噪点和拳关节。
    reg        frame_valid_filter_q;
    wire hand_frame_start = frame_valid_filter_d && !frame_valid_filter_q;
    wire hand_frame_end   = !frame_valid_filter_d && frame_valid_filter_q;

    // 与PEN一致，把互不连通的白色区域分成有限数量的空间候选。每个候选独立
    // 统计面积、包围框和顶部窄行；HAND_MIN_AREA现在真正作用于单个区域，而不是
    // 把整帧所有小噪点累加。已经闭合且面积不足门限的槽位可循环复用。
    localparam integer HAND_CANDIDATE_COUNT = 8;
    reg        candidate_used [0:HAND_CANDIDATE_COUNT-1];
    reg [19:0] candidate_area [0:HAND_CANDIDATE_COUNT-1];
    reg [10:0] candidate_x_min[0:HAND_CANDIDATE_COUNT-1];
    reg [10:0] candidate_x_max[0:HAND_CANDIDATE_COUNT-1];
    reg [10:0] candidate_y_min[0:HAND_CANDIDATE_COUNT-1];
    reg [10:0] candidate_y_max[0:HAND_CANDIDATE_COUNT-1];
    reg        candidate_finger_row_valid[0:HAND_CANDIDATE_COUNT-1];
    reg [10:0] candidate_finger_row_y[0:HAND_CANDIDATE_COUNT-1];
    reg [10:0] candidate_finger_row_x_min[0:HAND_CANDIDATE_COUNT-1];
    reg [10:0] candidate_finger_row_x_max[0:HAND_CANDIDATE_COUNT-1];
    reg        candidate_finger_run_open[0:HAND_CANDIDATE_COUNT-1];
    reg [7:0]  candidate_finger_narrow_rows[0:HAND_CANDIDATE_COUNT-1];
    reg [10:0] candidate_tip_x_min[0:HAND_CANDIDATE_COUNT-1];
    reg [10:0] candidate_tip_x_max[0:HAND_CANDIDATE_COUNT-1];
    reg [10:0] candidate_tip_y[0:HAND_CANDIDATE_COUNT-1];

    wire [HAND_CANDIDATE_COUNT-1:0] candidate_match_raw;
    wire [HAND_CANDIDATE_COUNT-1:0] candidate_free_raw;
    wire [HAND_CANDIDATE_COUNT-1:0] candidate_recycle_raw;
    genvar hand_candidate_gen;
    generate
        for (hand_candidate_gen = 0; hand_candidate_gen < HAND_CANDIDATE_COUNT;
             hand_candidate_gen = hand_candidate_gen + 1) begin : GEN_HAND_CANDIDATE_FLAGS
            assign candidate_free_raw[hand_candidate_gen] =
                !candidate_used[hand_candidate_gen];
            assign candidate_recycle_raw[hand_candidate_gen] =
                candidate_used[hand_candidate_gen] &&
                (candidate_area[hand_candidate_gen] < HAND_MIN_AREA) &&
                (pixel_y_filter_d > (candidate_y_max[hand_candidate_gen] + 1'b1));
            assign candidate_match_raw[hand_candidate_gen] =
                candidate_used[hand_candidate_gen] &&
                (pixel_y_filter_d <= (candidate_y_max[hand_candidate_gen] + 1'b1)) &&
                (pixel_x_filter_d + 1'b1 >= candidate_x_min[hand_candidate_gen]) &&
                (pixel_x_filter_d <= candidate_x_max[hand_candidate_gen] + 1'b1);
        end
    endgenerate

    // 八槽仍按最低索引优先。并行前缀OR替代取负加一的进位路径，
    // 不增加寄存器，不改变逐像素统计、候选选择顺序或任何形态门限。
    function [7:0] first_candidate;
        input [7:0] flags;
        begin
            first_candidate[0] = flags[0];
            first_candidate[1] = flags[1] && !flags[0];
            first_candidate[2] = flags[2] && !(|flags[1:0]);
            first_candidate[3] = flags[3] && !(|flags[2:0]);
            first_candidate[4] = flags[4] && !(|flags[3:0]);
            first_candidate[5] = flags[5] && !(|flags[4:0]);
            first_candidate[6] = flags[6] && !(|flags[5:0]);
            first_candidate[7] = flags[7] && !(|flags[6:0]);
        end
    endfunction
    wire [HAND_CANDIDATE_COUNT-1:0] candidate_match_first =
        first_candidate(candidate_match_raw);
    wire [HAND_CANDIDATE_COUNT-1:0] candidate_free_first =
        first_candidate(candidate_free_raw);
    wire [HAND_CANDIDATE_COUNT-1:0] candidate_recycle_first =
        first_candidate(candidate_recycle_raw);
    wire candidate_match_found = |candidate_match_raw;
    wire candidate_free_found = |candidate_free_raw;
    wire [HAND_CANDIDATE_COUNT-1:0] candidate_new_first =
        candidate_free_found ? candidate_free_first : candidate_recycle_first;

    integer hand_candidate_reset;
    always @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            frame_valid_filter_q <= 1'b0;
            for (hand_candidate_reset = 0;
                 hand_candidate_reset < HAND_CANDIDATE_COUNT;
                 hand_candidate_reset = hand_candidate_reset + 1) begin
                candidate_used[hand_candidate_reset] <= 1'b0;
                candidate_area[hand_candidate_reset] <= 20'd0;
                candidate_x_min[hand_candidate_reset] <= 11'd1279;
                candidate_x_max[hand_candidate_reset] <= 11'd0;
                candidate_y_min[hand_candidate_reset] <= 11'd719;
                candidate_y_max[hand_candidate_reset] <= 11'd0;
                candidate_finger_row_valid[hand_candidate_reset] <= 1'b0;
                candidate_finger_row_y[hand_candidate_reset] <= 11'd0;
                candidate_finger_row_x_min[hand_candidate_reset] <= 11'd1279;
                candidate_finger_row_x_max[hand_candidate_reset] <= 11'd0;
                candidate_finger_run_open[hand_candidate_reset] <= 1'b0;
                candidate_finger_narrow_rows[hand_candidate_reset] <= 8'd0;
                candidate_tip_x_min[hand_candidate_reset] <= 11'd1279;
                candidate_tip_x_max[hand_candidate_reset] <= 11'd0;
                candidate_tip_y[hand_candidate_reset] <= 11'd0;
            end
        end else begin
            frame_valid_filter_q <= frame_valid_filter_d;
            if (hand_frame_start) begin
                for (hand_candidate_reset = 0;
                     hand_candidate_reset < HAND_CANDIDATE_COUNT;
                     hand_candidate_reset = hand_candidate_reset + 1) begin
                    candidate_used[hand_candidate_reset] <= 1'b0;
                    candidate_area[hand_candidate_reset] <= 20'd0;
                    candidate_x_min[hand_candidate_reset] <= 11'd1279;
                    candidate_x_max[hand_candidate_reset] <= 11'd0;
                    candidate_y_min[hand_candidate_reset] <= 11'd719;
                    candidate_y_max[hand_candidate_reset] <= 11'd0;
                    candidate_finger_row_valid[hand_candidate_reset] <= 1'b0;
                    candidate_finger_row_y[hand_candidate_reset] <= 11'd0;
                    candidate_finger_row_x_min[hand_candidate_reset] <= 11'd1279;
                    candidate_finger_row_x_max[hand_candidate_reset] <= 11'd0;
                    candidate_finger_run_open[hand_candidate_reset] <= 1'b0;
                    candidate_finger_narrow_rows[hand_candidate_reset] <= 8'd0;
                    candidate_tip_x_min[hand_candidate_reset] <= 11'd1279;
                    candidate_tip_x_max[hand_candidate_reset] <= 11'd0;
                    candidate_tip_y[hand_candidate_reset] <= 11'd0;
                end
            end else if (filtered_hand) begin
                for (hand_candidate_reset = 0;
                     hand_candidate_reset < HAND_CANDIDATE_COUNT;
                     hand_candidate_reset = hand_candidate_reset + 1) begin
                    if (candidate_match_first[hand_candidate_reset]) begin
                        candidate_area[hand_candidate_reset] <=
                            candidate_area[hand_candidate_reset] + 1'b1;
                        if (pixel_x_filter_d < candidate_x_min[hand_candidate_reset])
                            candidate_x_min[hand_candidate_reset] <= pixel_x_filter_d;
                        if (pixel_x_filter_d > candidate_x_max[hand_candidate_reset])
                            candidate_x_max[hand_candidate_reset] <= pixel_x_filter_d;
                        if (pixel_y_filter_d > candidate_y_max[hand_candidate_reset])
                            candidate_y_max[hand_candidate_reset] <= pixel_y_filter_d;

                        // 6/9严格mask的顶部窄行统计跟随同一候选，避免远处噪点
                        // 抢占全局最小Y并把指尖中心拉走。
                        if (fingertip_hand) begin
                            if (!candidate_finger_row_valid[hand_candidate_reset]) begin
                                candidate_finger_row_valid[hand_candidate_reset] <= 1'b1;
                                candidate_finger_row_y[hand_candidate_reset] <= pixel_y_filter_d;
                                candidate_finger_row_x_min[hand_candidate_reset] <= pixel_x_filter_d;
                                candidate_finger_row_x_max[hand_candidate_reset] <= pixel_x_filter_d;
                                candidate_finger_run_open[hand_candidate_reset] <= 1'b1;
                                candidate_tip_x_min[hand_candidate_reset] <= pixel_x_filter_d;
                                candidate_tip_x_max[hand_candidate_reset] <= pixel_x_filter_d;
                                candidate_tip_y[hand_candidate_reset] <= pixel_y_filter_d;
                            end else if (pixel_y_filter_d !=
                                         candidate_finger_row_y[hand_candidate_reset]) begin
                                if (candidate_finger_run_open[hand_candidate_reset]) begin
                                    if ((pixel_y_filter_d <=
                                         (candidate_finger_row_y[hand_candidate_reset] + 11'd2)) &&
                                        ((candidate_finger_row_x_max[hand_candidate_reset] -
                                          candidate_finger_row_x_min[hand_candidate_reset] + 1'b1) <=
                                         FINGER_ROW_MAX_WIDTH))
                                        candidate_finger_narrow_rows[hand_candidate_reset] <=
                                            candidate_finger_narrow_rows[hand_candidate_reset] + 1'b1;
                                    else
                                        candidate_finger_run_open[hand_candidate_reset] <= 1'b0;
                                end
                                candidate_finger_row_y[hand_candidate_reset] <= pixel_y_filter_d;
                                candidate_finger_row_x_min[hand_candidate_reset] <= pixel_x_filter_d;
                                candidate_finger_row_x_max[hand_candidate_reset] <= pixel_x_filter_d;
                                if (candidate_finger_run_open[hand_candidate_reset] &&
                                    (candidate_finger_narrow_rows[hand_candidate_reset] < 8'd8)) begin
                                    if (pixel_x_filter_d < candidate_tip_x_min[hand_candidate_reset])
                                        candidate_tip_x_min[hand_candidate_reset] <= pixel_x_filter_d;
                                    if (pixel_x_filter_d > candidate_tip_x_max[hand_candidate_reset])
                                        candidate_tip_x_max[hand_candidate_reset] <= pixel_x_filter_d;
                                end
                            end else begin
                                if (pixel_x_filter_d <
                                    candidate_finger_row_x_min[hand_candidate_reset])
                                    candidate_finger_row_x_min[hand_candidate_reset] <= pixel_x_filter_d;
                                if (pixel_x_filter_d >
                                    candidate_finger_row_x_max[hand_candidate_reset])
                                    candidate_finger_row_x_max[hand_candidate_reset] <= pixel_x_filter_d;
                                if (candidate_finger_narrow_rows[hand_candidate_reset] < 8'd8) begin
                                    if (pixel_x_filter_d < candidate_tip_x_min[hand_candidate_reset])
                                        candidate_tip_x_min[hand_candidate_reset] <= pixel_x_filter_d;
                                    if (pixel_x_filter_d > candidate_tip_x_max[hand_candidate_reset])
                                        candidate_tip_x_max[hand_candidate_reset] <= pixel_x_filter_d;
                                end
                            end
                        end
                    end else if (!candidate_match_found &&
                                 candidate_new_first[hand_candidate_reset]) begin
                        candidate_used[hand_candidate_reset] <= 1'b1;
                        candidate_area[hand_candidate_reset] <= 20'd1;
                        candidate_x_min[hand_candidate_reset] <= pixel_x_filter_d;
                        candidate_x_max[hand_candidate_reset] <= pixel_x_filter_d;
                        candidate_y_min[hand_candidate_reset] <= pixel_y_filter_d;
                        candidate_y_max[hand_candidate_reset] <= pixel_y_filter_d;
                        candidate_finger_row_valid[hand_candidate_reset] <= fingertip_hand;
                        candidate_finger_row_y[hand_candidate_reset] <= pixel_y_filter_d;
                        candidate_finger_row_x_min[hand_candidate_reset] <= pixel_x_filter_d;
                        candidate_finger_row_x_max[hand_candidate_reset] <= pixel_x_filter_d;
                        candidate_finger_run_open[hand_candidate_reset] <= fingertip_hand;
                        candidate_finger_narrow_rows[hand_candidate_reset] <= 8'd0;
                        candidate_tip_x_min[hand_candidate_reset] <= pixel_x_filter_d;
                        candidate_tip_x_max[hand_candidate_reset] <= pixel_x_filter_d;
                        candidate_tip_y[hand_candidate_reset] <= pixel_y_filter_d;
                    end
                end
            end
        end
    end

    // 帧末在场消隐期依次检查8个候选。FETCH先锁存当前槽的有效性、面积、距离
    // 和指尖；COMPARE下一拍才与最佳候选比较，切断索引多路选择到最佳寄存器
    // 使能的长路径。槽顺序和择优规则不变，最终仍只在每帧末提交一次指尖。
    localparam [1:0] HAND_SELECT_IDLE = 2'd0;
    localparam [1:0] HAND_SELECT_FETCH = 2'd1;
    localparam [1:0] HAND_SELECT_COMPARE = 2'd2;
    localparam [1:0] HAND_SELECT_COMMIT = 2'd3;
    reg [1:0] hand_select_state;
    reg [2:0] hand_scan_index;
    reg       hand_scan_tracking;
    reg       hand_best_valid;
    reg [19:0] hand_best_area;
    reg [11:0] hand_best_distance;
    reg [10:0] hand_best_tip_x_min;
    reg [10:0] hand_best_tip_x_max;
    reg [10:0] hand_best_tip_y;
    reg        hand_eval_valid;
    reg        hand_eval_finger_like;
    reg        hand_finger_seen;
    reg        hand_multi_finger;
    reg [1:0]  hand_finger_count;
    reg [10:0] hand_first_tip_x;
    reg [10:0] hand_first_tip_y;
    reg        hand_v_pair_valid;
    reg        hand_large_blob_seen;
    localparam [2:0] GESTURE_NONE = 3'd0;
    localparam [2:0] GESTURE_UNKNOWN = 3'd1;
    localparam [2:0] GESTURE_INDEX = 3'd2;
    localparam [2:0] GESTURE_V = 3'd3;
    localparam [2:0] GESTURE_OPEN = 3'd4;
    localparam [2:0] GESTURE_FIST = 3'd5;
    // V手势的两个指尖须在同一只手的邻域内，且不能是单指开裂形成的近邻碎片。
    localparam [10:0] V_TIP_MIN_DX = 11'd32;
    localparam [10:0] V_TIP_MAX_DX = 11'd240;
    localparam [10:0] V_TIP_MAX_DY = 11'd96;
    reg [2:0] gesture_last_raw;
    reg [2:0] gesture_stable;
    reg [2:0] gesture_same_frames;
    reg       gesture_armed;
    reg [19:0] hand_eval_area;
    reg [11:0] hand_eval_distance;
    reg [10:0] hand_eval_tip_x_min;
    reg [10:0] hand_eval_tip_x_max;
    reg [10:0] hand_eval_tip_x;
    reg [10:0] hand_eval_tip_y;
    reg        hand_select_done;
    reg        hand_candidate_valid;
    reg [10:0] finger_tip_x_min;
    reg [10:0] finger_tip_x_max;
    reg [10:0] finger_tip_y;

    wire hand_scan_used = candidate_used[hand_scan_index];
    wire [19:0] hand_scan_area = candidate_area[hand_scan_index];
    wire [10:0] hand_scan_width = candidate_x_max[hand_scan_index] -
                                   candidate_x_min[hand_scan_index] + 1'b1;
    wire [10:0] hand_scan_height = candidate_y_max[hand_scan_index] -
                                    candidate_y_min[hand_scan_index] + 1'b1;
    wire [10:0] hand_scan_tip_width = candidate_tip_x_max[hand_scan_index] -
                                      candidate_tip_x_min[hand_scan_index] + 1'b1;
    wire [12:0] hand_scan_tip_width_x3 = {2'b0, hand_scan_tip_width} +
                                          {1'b0, hand_scan_tip_width, 1'b0};
    wire [12:0] hand_scan_width_ext = {2'b0, hand_scan_width};
    wire hand_scan_candidate_valid = hand_scan_used &&
                                     candidate_finger_row_valid[hand_scan_index] &&
                                     (hand_scan_area >= HAND_MIN_AREA) &&
                                     (hand_scan_area <= HAND_MAX_AREA) &&
                                     (hand_scan_width >= HAND_MIN_WIDTH) &&
                                     (hand_scan_height >= GLOVE_MIN_HEIGHT) &&
                                     (hand_scan_tip_width >= 11'd3) &&
                                     (hand_scan_tip_width <= TIP_MAX_WIDTH) &&
                                     (hand_scan_tip_width_x3 <= hand_scan_width_ext) &&
                                     (candidate_finger_narrow_rows[hand_scan_index] >=
                                      GLOVE_FINGER_MIN_ROWS);
    // 张掌的其他手指可能落在不同候选槽。只要出现第二个足够长的窄指段，
    // 本帧就不允许书写；面积门限低于手掌门限，以免漏掉独立的其他手指。
    wire hand_scan_finger_like = hand_scan_used &&
                                 (hand_scan_area >= 20'd600) &&
                                 (hand_scan_height >= 11'd40) &&
                                 (hand_scan_tip_width >= 11'd3) &&
                                 (hand_scan_tip_width <= TIP_MAX_WIDTH) &&
                                 (candidate_finger_narrow_rows[hand_scan_index] >= 8'd24);
    // 8槽仍是空间候选而非完整连通域。两槽计数只有通过指尖间距门禁才可
    // 判为V；含糊轮廓保持UNKNOWN，避免单指碎片直接确认并冻结轨迹。
    wire [2:0] gesture_frame_raw = !hand_large_blob_seen ? GESTURE_NONE :
                                    (hand_finger_count >= 2'd3) ? GESTURE_OPEN :
                                    (hand_finger_count == 2'd2) ?
                                    (hand_v_pair_valid ? GESTURE_V : GESTURE_UNKNOWN) :
                                    (hand_best_valid && (hand_finger_count == 2'd1) &&
                                     !hand_multi_finger) ? GESTURE_INDEX :
                                    (hand_finger_count == 2'd0) ? GESTURE_FIST :
                                    GESTURE_UNKNOWN;
    wire [11:0] hand_scan_tip_x_sum =
        {1'b0, candidate_tip_x_min[hand_scan_index]} +
        {1'b0, candidate_tip_x_max[hand_scan_index]};
    wire [10:0] hand_scan_tip_x = hand_scan_tip_x_sum[11:1];
    wire [10:0] hand_v_tip_dx = (hand_eval_tip_x >= hand_first_tip_x) ?
                                 (hand_eval_tip_x - hand_first_tip_x) :
                                 (hand_first_tip_x - hand_eval_tip_x);
    wire [10:0] hand_v_tip_dy = (hand_eval_tip_y >= hand_first_tip_y) ?
                                 (hand_eval_tip_y - hand_first_tip_y) :
                                 (hand_first_tip_y - hand_eval_tip_y);
    wire hand_v_pair_now = (hand_v_tip_dx >= V_TIP_MIN_DX) &&
                           (hand_v_tip_dx <= V_TIP_MAX_DX) &&
                           (hand_v_tip_dy <= V_TIP_MAX_DY);
    wire [10:0] hand_scan_tip_y_full = candidate_tip_y[hand_scan_index];
    wire [9:0] hand_scan_tip_y = hand_scan_tip_y_full[9:0];
    wire [10:0] hand_scan_dx = (hand_scan_tip_x >= fingertip_x) ?
                               (hand_scan_tip_x - fingertip_x) :
                               (fingertip_x - hand_scan_tip_x);
    wire [10:0] hand_scan_fingertip_y = {1'b0, fingertip_y};
    wire [10:0] hand_scan_tip_y_ext = {1'b0, hand_scan_tip_y};
    wire [10:0] hand_scan_dy = (hand_scan_tip_y_ext >= hand_scan_fingertip_y) ?
                               (hand_scan_tip_y_ext - hand_scan_fingertip_y) :
                               (hand_scan_fingertip_y - hand_scan_tip_y_ext);
    wire [11:0] hand_scan_distance = {1'b0, hand_scan_dx} +
                                      {1'b0, hand_scan_dy};
    wire hand_eval_better = hand_eval_valid &&
                            (!hand_best_valid ||
                             (hand_scan_tracking ?
                              ((hand_eval_distance < hand_best_distance) ||
                               ((hand_eval_distance == hand_best_distance) &&
                                (hand_eval_area > hand_best_area))) :
                              (hand_eval_area > hand_best_area)));

    always @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            hand_select_state <= HAND_SELECT_IDLE;
            hand_scan_index <= 3'd0;
            hand_scan_tracking <= 1'b0;
            hand_best_valid <= 1'b0;
            hand_best_area <= 20'd0;
            hand_best_distance <= 12'hfff;
            hand_best_tip_x_min <= 11'd0;
            hand_best_tip_x_max <= 11'd0;
            hand_best_tip_y <= 11'd0;
            hand_eval_valid <= 1'b0;
            hand_eval_finger_like <= 1'b0;
            hand_finger_seen <= 1'b0;
            hand_multi_finger <= 1'b0;
            hand_finger_count <= 2'd0;
            hand_first_tip_x <= 11'd0;
            hand_first_tip_y <= 11'd0;
            hand_v_pair_valid <= 1'b0;
            hand_large_blob_seen <= 1'b0;
            gesture_last_raw <= GESTURE_NONE;
            gesture_stable <= GESTURE_NONE;
            gesture_same_frames <= 3'd0;
            gesture_armed <= 1'b0;
            gesture_confirm_pulse <= 1'b0;
            gesture_clear_pulse <= 1'b0;
            hand_eval_area <= 20'd0;
            hand_eval_distance <= 12'd0;
            hand_eval_tip_x_min <= 11'd0;
            hand_eval_tip_x_max <= 11'd0;
            hand_eval_tip_x <= 11'd0;
            hand_eval_tip_y <= 11'd0;
            hand_select_done <= 1'b0;
            hand_candidate_valid <= 1'b0;
            finger_tip_x_min <= 11'd0;
            finger_tip_x_max <= 11'd0;
            finger_tip_y <= 11'd0;
        end else begin
            hand_select_done <= 1'b0;
            gesture_confirm_pulse <= 1'b0;
            gesture_clear_pulse <= 1'b0;
            case (hand_select_state)
                HAND_SELECT_IDLE: begin
                    if (hand_frame_end) begin
                        hand_scan_index <= 3'd0;
                        hand_scan_tracking <= fingertip_valid;
                        hand_best_valid <= 1'b0;
                        hand_best_area <= 20'd0;
                        hand_best_distance <= 12'hfff;
                        hand_finger_seen <= 1'b0;
                        hand_multi_finger <= 1'b0;
                        hand_finger_count <= 2'd0;
                        hand_first_tip_x <= 11'd0;
                        hand_first_tip_y <= 11'd0;
                        hand_v_pair_valid <= 1'b0;
                        hand_large_blob_seen <= 1'b0;
                        hand_select_state <= HAND_SELECT_FETCH;
                    end
                end
                HAND_SELECT_FETCH: begin
                    hand_eval_valid <= hand_scan_candidate_valid;
                    hand_eval_finger_like <= hand_scan_finger_like;
                    hand_eval_area <= hand_scan_area;
                    hand_eval_distance <= hand_scan_distance;
                    hand_eval_tip_x_min <= candidate_tip_x_min[hand_scan_index];
                    hand_eval_tip_x_max <= candidate_tip_x_max[hand_scan_index];
                    hand_eval_tip_x <= hand_scan_tip_x;
                    hand_eval_tip_y <= candidate_tip_y[hand_scan_index];
                    hand_select_state <= HAND_SELECT_COMPARE;
                end
                HAND_SELECT_COMPARE: begin
                    if (hand_eval_finger_like) begin
                        if (hand_finger_count < 2'd3)
                            hand_finger_count <= hand_finger_count + 1'b1;
                        if (hand_finger_seen)
                            hand_multi_finger <= 1'b1;
                        else begin
                            hand_finger_seen <= 1'b1;
                            hand_first_tip_x <= hand_eval_tip_x;
                            hand_first_tip_y <= hand_eval_tip_y;
                        end
                        // 第二槽必须像同一只手的另一根手指；远处噪点或近邻碎片
                        // 仍阻止本帧书写，但不能单凭槽数触发V确认。
                        if (hand_finger_count == 2'd1)
                            hand_v_pair_valid <= hand_v_pair_now;
                    end
                    // 大块手套只看面积，不能依赖单指有效位，否则握拳永远被当作无手。
                    if (hand_eval_area >= HAND_MIN_AREA)
                        hand_large_blob_seen <= 1'b1;
                    if (hand_eval_better) begin
                        hand_best_valid <= 1'b1;
                        hand_best_area <= hand_eval_area;
                        hand_best_distance <= hand_eval_distance;
                        hand_best_tip_x_min <= hand_eval_tip_x_min;
                        hand_best_tip_x_max <= hand_eval_tip_x_max;
                        hand_best_tip_y <= hand_eval_tip_y;
                    end
                    if (hand_scan_index == HAND_CANDIDATE_COUNT - 1)
                        hand_select_state <= HAND_SELECT_COMMIT;
                    else begin
                        hand_scan_index <= hand_scan_index + 1'b1;
                        hand_select_state <= HAND_SELECT_FETCH;
                    end
                end
                HAND_SELECT_COMMIT: begin
                    // 握拳的短关节由更长的窄行门限排除；张掌多指在此禁止采样。
                    hand_candidate_valid <= hand_best_valid && !hand_multi_finger;
                    if (!hand_mode_enable) begin
                        gesture_last_raw <= GESTURE_NONE;
                        gesture_stable <= GESTURE_NONE;
                        gesture_same_frames <= 3'd0;
                        gesture_armed <= 1'b0;
                    end else if (gesture_frame_raw == gesture_last_raw) begin
                        if (gesture_same_frames < 3'd6)
                            gesture_same_frames <= gesture_same_frames + 1'b1;
                        if (gesture_same_frames >= 3'd5) begin
                            gesture_stable <= gesture_frame_raw;
                            // 入HAND及每次动作后，必须连续6帧无手才重新武装。
                            // 姿势保持或直接换姿势不会重复清空/确认。
                            if (gesture_frame_raw == GESTURE_NONE)
                                gesture_armed <= 1'b1;
                            else if (gesture_armed && !fingertip_valid) begin
                                if (gesture_frame_raw == GESTURE_V) begin
                                    gesture_confirm_pulse <= 1'b1;
                                    gesture_armed <= 1'b0;
                                end else if (gesture_frame_raw == GESTURE_OPEN) begin
                                    gesture_clear_pulse <= 1'b1;
                                    gesture_armed <= 1'b0;
                                end
                            end
                        end
                    end else begin
                        gesture_last_raw <= gesture_frame_raw;
                        // 一帧轮廓变化只重启六帧消抖，不立即把绿色状态块刷红。
                        // 稳定UNKNOWN连续六帧后仍会显示红色，不掩盖持续误检。
                        gesture_same_frames <= 3'd1;
                    end
                    finger_tip_x_min <= hand_best_tip_x_min;
                    finger_tip_x_max <= hand_best_tip_x_max;
                    finger_tip_y <= hand_best_tip_y;
                    hand_select_done <= 1'b1;
                    hand_select_state <= HAND_SELECT_IDLE;
                end
                default: hand_select_state <= HAND_SELECT_IDLE;
            endcase
        end
    end

    wire [11:0] tip_x_sum = {1'b0, finger_tip_x_min} +
                             {1'b0, finger_tip_x_max};
    wire [10:0] raw_tip_x = tip_x_sum[11:1];
    wire [9:0] raw_tip_y = finger_tip_y[9:0];

    wire [10:0] tip_dx = (raw_tip_x >= fingertip_x) ?
                         (raw_tip_x - fingertip_x) : (fingertip_x - raw_tip_x);
    wire [10:0] fingertip_y_ext = {1'b0, fingertip_y};
    wire [10:0] raw_tip_y_ext = {1'b0, raw_tip_y};
    wire [10:0] tip_dy = (raw_tip_y_ext >= fingertip_y_ext) ?
                         (raw_tip_y_ext - fingertip_y_ext) :
                         (fingertip_y_ext - raw_tip_y_ext);
    wire tip_jump_small = (tip_dx <= TIP_TRACK_RADIUS) &&
                          (tip_dy <= TIP_TRACK_RADIUS);
    wire [11:0] smooth_tip_x_sum = {1'b0, fingertip_x} + {1'b0, raw_tip_x};
    wire [10:0] smooth_tip_y_sum = {1'b0, fingertip_y} + {1'b0, raw_tip_y};
    wire [10:0] accepted_tip_x = (fingertip_valid && tip_jump_small) ?
                                 smooth_tip_x_sum[11:1] : raw_tip_x;
    wire [9:0] accepted_tip_y = (fingertip_valid && tip_jump_small) ?
                                smooth_tip_y_sum[10:1] : raw_tip_y;

    // 首次捕获和超出正常跟踪半径的候选都先暂存；只有下一帧在相近位置
    // 再次出现才允许出点和写入轨迹，避免握拳快移的一帧误判留下孤立点。
    reg        tip_pending_valid;
    reg [10:0] tip_pending_x;
    reg [9:0]  tip_pending_y;
    reg [1:0]  tip_miss_count;
    wire [10:0] pending_dx = (raw_tip_x >= tip_pending_x) ?
                             (raw_tip_x - tip_pending_x) :
                             (tip_pending_x - raw_tip_x);
    wire [10:0] tip_pending_y_ext = {1'b0, tip_pending_y};
    wire [10:0] pending_dy = (raw_tip_y_ext >= tip_pending_y_ext) ?
                             (raw_tip_y_ext - tip_pending_y_ext) :
                             (tip_pending_y_ext - raw_tip_y_ext);
    wire pending_match = tip_pending_valid &&
                         (pending_dx <= TIP_CONFIRM_RADIUS) &&
                         (pending_dy <= TIP_CONFIRM_RADIUS);
    wire [11:0] confirmed_x_sum = {1'b0, tip_pending_x} + {1'b0, raw_tip_x};
    wire [10:0] confirmed_y_sum = {1'b0, tip_pending_y} + {1'b0, raw_tip_y};

    // 每帧结束时才更新最终坐标，因此下一帧整幅图使用同一圆点位置，不会产生撕裂。
    // 合法连续帧做1/2一阶平滑；超出160像素的跳变需连续两帧一致才建立新段。
    always @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            fingertip_valid            <= 1'b0;
            fingertip_x                <= 11'd0;
            fingertip_y                <= 10'd0;
            fingertip_sample_valid     <= 1'b0;
            fingertip_sample_connected <= 1'b0;
            fingertip_sample_x         <= 11'd0;
            fingertip_sample_y         <= 10'd0;
            tip_pending_valid           <= 1'b0;
            tip_pending_x               <= 11'd0;
            tip_pending_y               <= 10'd0;
            tip_miss_count              <= 2'd0;
        end else begin
            fingertip_sample_valid <= 1'b0;
            fingertip_sample_connected <= 1'b0;
            if (hand_select_done) begin
                if (hand_candidate_valid) begin
                    tip_miss_count <= 2'd0;
                    if (!fingertip_valid) begin
                        if (pending_match) begin
                            fingertip_valid        <= 1'b1;
                            fingertip_x            <= confirmed_x_sum[11:1];
                            fingertip_y            <= confirmed_y_sum[10:1];
                            fingertip_sample_valid <= 1'b1;
                            fingertip_sample_x     <= confirmed_x_sum[11:1];
                            fingertip_sample_y     <= confirmed_y_sum[10:1];
                            tip_pending_valid      <= 1'b0;
                        end else begin
                            tip_pending_valid <= 1'b1;
                            tip_pending_x     <= raw_tip_x;
                            tip_pending_y     <= raw_tip_y;
                        end
                    end else if (tip_jump_small) begin
                        fingertip_x                <= accepted_tip_x;
                        fingertip_y                <= accepted_tip_y;
                        fingertip_sample_valid     <= 1'b1;
                        fingertip_sample_connected <= 1'b1;
                        fingertip_sample_x         <= accepted_tip_x;
                        fingertip_sample_y         <= accepted_tip_y;
                        tip_pending_valid           <= 1'b0;
                    end else if (pending_match) begin
                        // 远处候选连续两帧一致才重捕获，并作为新轨迹段起点而不跨屏连线。
                        fingertip_x            <= confirmed_x_sum[11:1];
                        fingertip_y            <= confirmed_y_sum[10:1];
                        fingertip_sample_valid <= 1'b1;
                        fingertip_sample_x     <= confirmed_x_sum[11:1];
                        fingertip_sample_y     <= confirmed_y_sum[10:1];
                        tip_pending_valid      <= 1'b0;
                    end else begin
                        tip_pending_valid <= 1'b1;
                        tip_pending_x     <= raw_tip_x;
                        tip_pending_y     <= raw_tip_y;
                    end
                end else begin
                    tip_pending_valid <= 1'b0;
                    // 一两帧轮廓孔洞只保持圆点且不输出样本；连续三帧失配才真正解锁。
                    if (fingertip_valid && (tip_miss_count < 2'd2))
                        tip_miss_count <= tip_miss_count + 1'b1;
                    else begin
                        fingertip_valid <= 1'b0;
                        tip_miss_count  <= 2'd0;
                    end
                end
            end
        end
    end

    // 半径约6像素的分段圆形近似，不使用乘法器。圆点使用洋红色，既能与绿手套
    // 区分，也能在绿手套黑白调试画面上保持醒目。
    wire [10:0] dot_dx = (pixel_x_filter_d >= fingertip_x) ?
                         (pixel_x_filter_d - fingertip_x) :
                         (fingertip_x - pixel_x_filter_d);
    wire [10:0] dot_y = {1'b0, fingertip_y};
    wire [10:0] dot_dy = (pixel_y_filter_d >= dot_y) ?
                         (pixel_y_filter_d - dot_y) :
                         (dot_y - pixel_y_filter_d);
    wire on_fingertip_dot = fingertip_valid && pixel_valid_filter_d &&
                            (((dot_dy <= 11'd2) && (dot_dx <= 11'd6)) ||
                             ((dot_dy <= 11'd4) && (dot_dx <= 11'd5)) ||
                             ((dot_dy <= 11'd6) && (dot_dx <= 11'd2)));

    // HAND轨迹复用PEN已经验证的160×90单比特组织，每格对应8×8画面像素。
    // 指尖样本只在场消隐开始处产生，Bresenham连线可在下一帧有效像素到来前完成；
    // 公共确认与点缓存同拍冻结位图，避免已发送快照之外继续出现黄色轨迹；
    // 张掌或S1切换模式由公共clear脉冲擦除位图并解冻，S3/S4仍只调颜色阈值。
    localparam [13:0] TRAJECTORY_LAST_ADDR = 14'd14399;
    reg        trajectory_clearing;
    reg        trajectory_frozen;
    reg [13:0] trajectory_clear_addr;
    reg        trajectory_have_prev;
    reg [7:0]  trajectory_prev_x;
    reg [6:0]  trajectory_prev_y;
    reg        trajectory_line_busy;
    reg [7:0]  trajectory_line_x;
    reg [6:0]  trajectory_line_y;
    reg [7:0]  trajectory_line_target_x;
    reg [6:0]  trajectory_line_target_y;
    reg [7:0]  trajectory_line_dx;
    reg [6:0]  trajectory_line_dy;
    reg        trajectory_line_x_inc;
    reg        trajectory_line_y_inc;
    reg signed [9:0] trajectory_line_error;

    wire [7:0] trajectory_target_x = fingertip_sample_x[10:3];
    wire [6:0] trajectory_target_y = fingertip_sample_y[9:3];
    wire [7:0] trajectory_start_x = trajectory_have_prev ?
                                     trajectory_prev_x : trajectory_target_x;
    wire [6:0] trajectory_start_y = trajectory_have_prev ?
                                     trajectory_prev_y : trajectory_target_y;
    wire trajectory_connect_sample = trajectory_have_prev &&
                                     fingertip_sample_connected;
    wire [7:0] trajectory_new_dx = (trajectory_target_x >= trajectory_start_x) ?
                                    (trajectory_target_x - trajectory_start_x) :
                                    (trajectory_start_x - trajectory_target_x);
    wire [6:0] trajectory_new_dy = (trajectory_target_y >= trajectory_start_y) ?
                                    (trajectory_target_y - trajectory_start_y) :
                                    (trajectory_start_y - trajectory_target_y);
    wire signed [9:0] trajectory_new_error =
        $signed({2'b0, trajectory_new_dx}) - $signed({3'b0, trajectory_new_dy});
    wire signed [10:0] trajectory_error_x2 =
        $signed({trajectory_line_error[9], trajectory_line_error}) <<< 1;
    wire signed [10:0] trajectory_negative_dy =
        -$signed({4'b0, trajectory_line_dy});
    wire signed [10:0] trajectory_positive_dx =
        $signed({3'b0, trajectory_line_dx});
    wire trajectory_step_x = trajectory_error_x2 > trajectory_negative_dy;
    wire trajectory_step_y = trajectory_error_x2 < trajectory_positive_dx;

    wire [13:0] trajectory_line_addr =
        {trajectory_line_y, 7'b0} +
        {2'b0, trajectory_line_y, 5'b0} +
        {6'b0, trajectory_line_x};
    wire trajectory_write_enable = trajectory_clearing ||
                                   (hand_mode_enable && !trajectory_frozen &&
                                    !trajectory_confirm && trajectory_line_busy);
    wire [13:0] trajectory_write_addr = trajectory_clearing ?
                                         trajectory_clear_addr : trajectory_line_addr;
    wire trajectory_write_data = !trajectory_clearing;

    always @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            trajectory_clearing      <= 1'b1;
            trajectory_frozen        <= 1'b0;
            trajectory_clear_addr    <= 14'd0;
            trajectory_have_prev     <= 1'b0;
            trajectory_prev_x        <= 8'd0;
            trajectory_prev_y        <= 7'd0;
            trajectory_line_busy     <= 1'b0;
            trajectory_line_x        <= 8'd0;
            trajectory_line_y        <= 7'd0;
            trajectory_line_target_x <= 8'd0;
            trajectory_line_target_y <= 7'd0;
            trajectory_line_dx       <= 8'd0;
            trajectory_line_dy       <= 7'd0;
            trajectory_line_x_inc    <= 1'b1;
            trajectory_line_y_inc    <= 1'b1;
            trajectory_line_error    <= 10'sd0;
        end else if (trajectory_clear) begin
            trajectory_clearing   <= 1'b1;
            trajectory_frozen     <= 1'b0;
            trajectory_clear_addr <= 14'd0;
            trajectory_have_prev  <= 1'b0;
            trajectory_line_busy  <= 1'b0;
        end else if (trajectory_clearing) begin
            trajectory_line_busy <= 1'b0;
            trajectory_have_prev <= 1'b0;
            if (trajectory_clear_addr == TRAJECTORY_LAST_ADDR)
                trajectory_clearing <= 1'b0;
            else
                trajectory_clear_addr <= trajectory_clear_addr + 1'b1;
        end else if (trajectory_confirm) begin
            // 确认只冻结轨迹写入；指尖检测、圆点和姿势调试仍实时运行。
            trajectory_frozen    <= 1'b1;
            trajectory_line_busy <= 1'b0;
            trajectory_have_prev <= 1'b0;
        end else if (!hand_mode_enable || trajectory_frozen) begin
            trajectory_line_busy <= 1'b0;
            trajectory_have_prev <= 1'b0;
        end else begin
            if (trajectory_line_busy) begin
                if ((trajectory_line_x == trajectory_line_target_x) &&
                    (trajectory_line_y == trajectory_line_target_y)) begin
                    trajectory_line_busy <= 1'b0;
                end else begin
                    case ({trajectory_step_x, trajectory_step_y})
                        2'b10: trajectory_line_error <= trajectory_line_error -
                                                      $signed({3'b0, trajectory_line_dy});
                        2'b01: trajectory_line_error <= trajectory_line_error +
                                                      $signed({2'b0, trajectory_line_dx});
                        2'b11: trajectory_line_error <= trajectory_line_error -
                                                      $signed({3'b0, trajectory_line_dy}) +
                                                      $signed({2'b0, trajectory_line_dx});
                        default: trajectory_line_error <= trajectory_line_error;
                    endcase
                    if (trajectory_step_x)
                        trajectory_line_x <= trajectory_line_x_inc ?
                                             trajectory_line_x + 1'b1 :
                                             trajectory_line_x - 1'b1;
                    if (trajectory_step_y)
                        trajectory_line_y <= trajectory_line_y_inc ?
                                             trajectory_line_y + 1'b1 :
                                             trajectory_line_y - 1'b1;
                end
            end

            if (fingertip_sample_valid) begin
                // 断段样本只落一个起点；连续样本才从上一点连线，避免重捕获产生跨屏长线。
                trajectory_line_x        <= trajectory_connect_sample ?
                                            trajectory_prev_x : trajectory_target_x;
                trajectory_line_y        <= trajectory_connect_sample ?
                                            trajectory_prev_y : trajectory_target_y;
                trajectory_line_target_x <= trajectory_target_x;
                trajectory_line_target_y <= trajectory_target_y;
                trajectory_line_dx       <= trajectory_connect_sample ?
                                            trajectory_new_dx : 8'd0;
                trajectory_line_dy       <= trajectory_connect_sample ?
                                            trajectory_new_dy : 7'd0;
                trajectory_line_x_inc    <= trajectory_target_x >= trajectory_prev_x;
                trajectory_line_y_inc    <= trajectory_target_y >= trajectory_prev_y;
                trajectory_line_error    <= trajectory_connect_sample ?
                                            trajectory_new_error : 10'sd0;
                trajectory_line_busy     <= 1'b1;
                trajectory_prev_x        <= trajectory_target_x;
                trajectory_prev_y        <= trajectory_target_y;
                trajectory_have_prev     <= 1'b1;
            end
        end
    end

    wire [7:0] trajectory_read_x = pixel_x_filter_d[10:3];
    wire [6:0] trajectory_read_y = pixel_y_filter_d[9:3];
    wire [13:0] trajectory_read_addr =
        {trajectory_read_y, 7'b0} +
        {2'b0, trajectory_read_y, 5'b0} +
        {6'b0, trajectory_read_x};
    wire trajectory_read_bit;
    trajectory_bitmap_sdpb u_hand_trajectory_bitmap (
        .clka  (pclk),
        .cea   (trajectory_write_enable),
        .ada   (trajectory_write_addr),
        .din   (trajectory_write_data),
        .clkb  (pclk),
        .ceb   (pixel_valid_filter_d),
        .adb   (trajectory_read_addr),
        .oce   (1'b1),
        .reset (~reset_n),
        .dout  (trajectory_read_bit)
    );

    // 第三拍固定输出。两种HAND输入的S2调试画面都实时显示5/9完整mask，
    // 保持上一版直接观察颜色与空间过滤结果的调试行为。
    reg        frame_valid_out_r;
    reg        pixel_valid_out_r;
    reg [15:0] pixel_out_r;
    reg        fingertip_dot_r;
    reg        hand_mode_out_r;
    reg        debug_mask_out_r;
    always @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            frame_valid_out_r <= 1'b0;
            pixel_valid_out_r <= 1'b0;
            pixel_out_r       <= 16'd0;
            fingertip_dot_r   <= 1'b0;
            hand_mode_out_r   <= 1'b0;
            debug_mask_out_r  <= 1'b0;
        end else begin
            frame_valid_out_r <= frame_valid_filter_d;
            pixel_valid_out_r <= pixel_valid_filter_d;
            fingertip_dot_r   <= on_fingertip_dot;
            hand_mode_out_r   <= hand_mode_filter_d;
            debug_mask_out_r  <= debug_mask_filter_d;
            if (pixel_valid_filter_d) begin
                if (hand_mode_filter_d && debug_mask_filter_d) begin
                    // 左上角16×16状态块仅在S2调试画面显示，不参与mask或采样。
                    // 红=未知，绿=单食指，青=比耶，蓝=张掌，黄=握拳；黑=无手。
                    if ((pixel_x_filter_d < 11'd16) &&
                        (pixel_y_filter_d < 11'd16)) begin
                        case (gesture_stable)
                            GESTURE_INDEX: pixel_out_r <= 16'h07E0;
                            GESTURE_V:     pixel_out_r <= 16'h07FF;
                            GESTURE_OPEN:  pixel_out_r <= 16'h001F;
                            GESTURE_FIST:  pixel_out_r <= 16'hFFE0;
                            GESTURE_NONE:  pixel_out_r <= 16'h0000;
                            default:       pixel_out_r <= 16'hF800;
                        endcase
                    end else if (on_fingertip_dot)
                        pixel_out_r <= 16'hF81F;
                    else
                        pixel_out_r <= filtered_hand ? 16'hFFFF : 16'h0000;
                end else
                    pixel_out_r <= pixel_in_filter_d;
            end
        end
    end

    // 位图同步读晚一拍，最后一级同时延迟像素和有效信号。黑白调试画面只显示
    // mask与洋红色指尖圆点；黄色轨迹仅叠加到普通HAND原画，避免干扰前景调试。
    reg        frame_valid_final;
    reg        pixel_valid_final;
    reg [15:0] pixel_final;
    always @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            frame_valid_final <= 1'b0;
            pixel_valid_final <= 1'b0;
            pixel_final       <= 16'd0;
        end else begin
            frame_valid_final <= frame_valid_out_r;
            pixel_valid_final <= pixel_valid_out_r;
            if (pixel_valid_out_r) begin
                if (fingertip_dot_r)
                    pixel_final <= 16'hF81F;
                else if (hand_mode_out_r && !debug_mask_out_r && trajectory_read_bit)
                    pixel_final <= 16'hFFE0;
                else
                    pixel_final <= pixel_out_r;
            end
        end
    end

    assign frame_valid_out = frame_valid_final;
    assign pixel_valid_out = pixel_valid_final;
    assign pixel_out       = pixel_final;

endmodule
