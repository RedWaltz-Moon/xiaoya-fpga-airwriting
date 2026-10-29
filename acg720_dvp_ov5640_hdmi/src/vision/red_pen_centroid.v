`timescale 1ns / 1ps

// 红色圆笔头检测、3×3空间过滤、面积/包围框统计和质心叠加。
// 模块工作在OV5640 PCLK域；输出像素及有效信号相对输入延迟两个PCLK：
// 第一拍对齐3×3行缓存，第二拍对齐轨迹位图同步读，不改变RGB565原图颜色。
module red_pen_centroid #(
    parameter [7:0] R_MIN       = 8'd64,
    parameter [7:0] EDGE_R_MIN  = 8'd72,
    parameter [7:0] R_DIFF      = 8'd40,
    parameter [19:0] MIN_AREA   = 20'd1500,
    parameter [19:0] MAX_AREA   = 20'd6000,
    parameter [10:0] MAX_BOX_WIDTH  = 11'd128,
    parameter [9:0]  MAX_BOX_HEIGHT = 10'd128,
    parameter [3:0] FILTER_MIN_HITS = 4'd7,
    parameter [10:0] TRACK_RADIUS = 11'd160,
    parameter [19:0] TRACK_MIN_AREA = 20'd500,
    parameter [19:0] TRACK_MAX_AREA = 20'd8000,
    parameter [10:0] TRACK_MAX_BOX = 11'd160
) (
    input  wire        pclk,
    input  wire        reset_n,
    input  wire        frame_valid,
    input  wire        pixel_valid,
    input  wire [10:0] pixel_x,
    input  wire [10:0] pixel_y,
    input  wire [15:0] pixel_in,
    input  wire        debug_mask_enable,
    input  wire        pen_mode_enable,
    input  wire        trajectory_clear,
    input  wire        trajectory_confirm,
    output wire        frame_valid_out,
    output wire        pixel_valid_out,
    output wire [15:0] pixel_out,
    output reg         object_valid,
    output reg  [10:0] centroid_x,
    output reg  [9:0]  centroid_y,
    output reg  [19:0] object_area,
    output wire        trajectory_sample_valid,
    output wire        trajectory_sample_connected,
    output wire [10:0] trajectory_sample_x,
    output wire [9:0]  trajectory_sample_y
);

    // RGB565扩展到RGB888。为压制会自行游走并与笔头桥接的偏红背景，M3R把
    // 中央/边缘最低红色分别收紧到64/72，并把红绿、红蓝色差提高到40。
    // 橙色仍可能含有较高红分量，因此进一步要求R约大于2.5G；R>2B保持不变。
    wire [7:0] red8   = {pixel_in[15:11], pixel_in[15:13]};
    wire [7:0] green8 = {pixel_in[10:5],  pixel_in[10:9]};
    wire [7:0] blue8  = {pixel_in[4:0],   pixel_in[4:2]};
    // 2.5G用2G+G/2实现，避免引入乘法器；截断的半个最低位不影响RGB565量化级。
    wire [9:0] green_x2p5 = {1'b0, green8, 1'b0} + {3'b0, green8[7:1]};
    wire [8:0] blue_x2  = {blue8,  1'b0};
    wire edge_zone = (pixel_x < 11'd64) || (pixel_x >= 11'd1216) ||
                     (pixel_y < 11'd64) || (pixel_y >= 11'd656);
    wire [7:0] active_r_min = edge_zone ? EDGE_R_MIN : R_MIN;
    wire raw_red = pen_mode_enable && (red8 >= active_r_min) &&
                   ({1'b0, red8} > ({1'b0, green8} + {1'b0, R_DIFF})) &&
                   ({1'b0, red8} > ({1'b0, blue8}  + {1'b0, R_DIFF})) &&
                   ({2'b0, red8} > green_x2p5) && ({1'b0, red8} > blue_x2);

    // SDPB读数据晚一个PCLK到达，因此同步保存当前像素、坐标和分类结果。
    // DVP的DataValid允许间断：读口仅在输入有效时推进，写口及后续处理使用延迟后的有效信号。
    reg        pixel_valid_d;
    reg [10:0] pixel_x_d;
    reg [10:0] pixel_y_d;
    reg [15:0] pixel_in_d;
    reg        raw_red_d;
    reg frame_valid_d;
    wire frame_start = frame_valid && !frame_valid_d;
    wire frame_end   = !frame_valid && frame_valid_d;
    always @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            frame_valid_d <= 1'b0;
            pixel_valid_d <= 1'b0;
            pixel_x_d     <= 11'd0;
            pixel_y_d     <= 11'd0;
            pixel_in_d    <= 16'd0;
            raw_red_d     <= 1'b0;
        end else begin
            frame_valid_d <= frame_valid;
            pixel_valid_d <= pixel_valid;
            if (pixel_valid) begin
                pixel_x_d  <= pixel_x;
                pixel_y_d  <= pixel_y;
                pixel_in_d <= pixel_in;
                raw_red_d  <= raw_red;
            end
        end
    end
    // 每个X地址的bit1保存上一行mask，bit0保存上上行mask；写入当前分类结果时整体下移。
    // 前两行不使用滤波结果，因此无需依赖SDPB上电初值，扫描两行后历史数据自然被覆盖。
    wire [7:0] line_history_q;
    wire [7:0] line_history_write = {6'd0, raw_red_d, line_history_q[1]};
    mask_line_buffer_sdpb u_mask_line_buffer (
        .dout (line_history_q),
        .clka (pclk),
        .cea  (pixel_valid_d),
        .clkb (pclk),
        .ceb  (pixel_valid),
        .oce  (1'b1),
        .reset(~reset_n),
        .ada  (pixel_x_d),
        .din  (line_history_write),
        .adb  (pixel_x)
    );

    // 三行各保存前两个横向分类点，与本拍分类点组成3×3窗口。
    // 采用只看当前点左侧和上方的因果窗口，结果坐标仍对应本拍延迟像素；相比居中窗口仅有1像素偏置，
    // 但无需再缓存两整行RGB565原图。所有单比特均显式扩成4位，避免连加表达式发生位宽截断。
    reg row_m2_x2;
    reg row_m2_x1;
    reg row_m1_x2;
    reg row_m1_x1;
    reg row_now_x2;
    reg row_now_x1;
    wire [3:0] window_hits =
        {3'd0, row_m2_x2}  + {3'd0, row_m2_x1}  + {3'd0, line_history_q[0]} +
        {3'd0, row_m1_x2}  + {3'd0, row_m1_x1}  + {3'd0, line_history_q[1]} +
        {3'd0, row_now_x2} + {3'd0, row_now_x1} + {3'd0, raw_red_d};

    always @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            row_m2_x2  <= 1'b0;
            row_m2_x1  <= 1'b0;
            row_m1_x2  <= 1'b0;
            row_m1_x1  <= 1'b0;
            row_now_x2 <= 1'b0;
            row_now_x1 <= 1'b0;
        end else if (pixel_valid_d) begin
            if (pixel_x_d == 11'd0) begin
                row_m2_x2  <= 1'b0;
                row_m1_x2  <= 1'b0;
                row_now_x2 <= 1'b0;
                row_m2_x1  <= line_history_q[0];
                row_m1_x1  <= line_history_q[1];
                row_now_x1 <= raw_red_d;
            end else begin
                row_m2_x2  <= row_m2_x1;
                row_m1_x2  <= row_m1_x1;
                row_now_x2 <= row_now_x1;
                row_m2_x1  <= line_history_q[0];
                row_m1_x1  <= line_history_q[1];
                row_now_x1 <= raw_red_d;
            end
        end
    end

    // 在完整1280×720画面统计过滤后的mask；边缘两行/两列因窗口尚未形成而主动丢弃。
    wire        mask_red = pixel_valid_d && (pixel_x_d >= 11'd2) && (pixel_y_d >= 11'd2) &&
                           (window_hits >= FILTER_MIN_HITS);
    wire [10:0] mask_x   = pixel_x_d;
    wire [9:0]  mask_y   = pixel_y_d[9:0];

    // 首次未锁定时允许全画面搜索；取得有效笔头后，仅统计上一帧质心周围的320×320窗口。
    // 这会阻止远处固定区域内的闪烁噪声继续拉大全帧包围框，同时给快速移动保留足够余量。
    wire [10:0] track_x_min = (centroid_x > TRACK_RADIUS) ? centroid_x - TRACK_RADIUS : 11'd0;
    wire [10:0] track_x_max = (centroid_x < (11'd1279 - TRACK_RADIUS)) ?
                              centroid_x + TRACK_RADIUS : 11'd1279;
    wire [10:0] centroid_y_ext = {1'b0, centroid_y};
    wire [10:0] track_y_min = (centroid_y_ext > TRACK_RADIUS) ?
                              centroid_y_ext - TRACK_RADIUS : 11'd0;
    wire [10:0] track_y_max = (centroid_y_ext < (11'd719 - TRACK_RADIUS)) ?
                              centroid_y_ext + TRACK_RADIUS : 11'd719;
    wire in_track_window = (mask_x >= track_x_min) && (mask_x <= track_x_max) &&
                           ({1'b0, mask_y} >= track_y_min) && ({1'b0, mask_y} <= track_y_max);
    wire mask_selected = mask_red && (!object_valid || in_track_window);

    // 只保留8个当前仍可能延伸的空间候选。新像素加入与其横向相邻且行间连续的候选；
    // 已经离开当前扫描行的候选先参与最优目标比较，再循环复用其槽位。这样候选数量不再
    // 随整帧噪点数量增长，也不会简单地只保留画面最前面的8个区域。
    localparam integer CANDIDATE_COUNT = 8;
    reg        candidate_used [0:CANDIDATE_COUNT-1];
    reg [19:0] candidate_count[0:CANDIDATE_COUNT-1];
    reg [10:0] candidate_x_min[0:CANDIDATE_COUNT-1];
    reg [10:0] candidate_x_max[0:CANDIDATE_COUNT-1];
    reg [9:0]  candidate_y_min[0:CANDIDATE_COUNT-1];
    reg [9:0]  candidate_y_max[0:CANDIDATE_COUNT-1];

    // 八个槽位先并行产生匹配/空闲/可回收标志，再用最低有效位形成独热选择。
    // 相比原先在for循环中串行传播found和动态数组下标，这种写法保持“低编号优先”
    // 的功能不变，同时让每个候选寄存器的写使能只经过短的独热选择路径。
    wire [CANDIDATE_COUNT-1:0] candidate_match_raw;
    wire [CANDIDATE_COUNT-1:0] candidate_free_raw;
    wire [CANDIDATE_COUNT-1:0] candidate_recycle_raw;
    genvar candidate_gen;
    generate
        for (candidate_gen = 0; candidate_gen < CANDIDATE_COUNT; candidate_gen = candidate_gen + 1) begin : GEN_CANDIDATE_FLAGS
            assign candidate_free_raw[candidate_gen] = !candidate_used[candidate_gen];
            assign candidate_recycle_raw[candidate_gen] = candidate_used[candidate_gen] &&
                                                           (mask_y > (candidate_y_max[candidate_gen] + 1'b1));
            assign candidate_match_raw[candidate_gen] = candidate_used[candidate_gen] &&
                                                         (mask_y <= (candidate_y_max[candidate_gen] + 1'b1)) &&
                                                         (mask_x + 1'b1 >= candidate_x_min[candidate_gen]) &&
                                                         (mask_x <= candidate_x_max[candidate_gen] + 1'b1);
        end
    endgenerate

    // x & (-x)保留最低编号的一个有效位；8位加法便于综合器映射到快速进位链。
    wire [CANDIDATE_COUNT-1:0] candidate_match_first =
        candidate_match_raw & (~candidate_match_raw + 8'd1);
    wire [CANDIDATE_COUNT-1:0] candidate_free_first =
        candidate_free_raw & (~candidate_free_raw + 8'd1);
    wire [CANDIDATE_COUNT-1:0] candidate_recycle_first =
        candidate_recycle_raw & (~candidate_recycle_raw + 8'd1);
    wire match_found   = |candidate_match_raw;
    wire free_found    = |candidate_free_raw;
    wire recycle_found = |candidate_recycle_raw;
    wire [CANDIDATE_COUNT-1:0] candidate_new_first =
        free_found ? candidate_free_first : candidate_recycle_first;

    // 回收快照仍需要槽号；该索引只进入既有评估流水线，不再参与候选数组写使能。
    wire [2:0] recycle_index = candidate_recycle_first[0] ? 3'd0 :
                               candidate_recycle_first[1] ? 3'd1 :
                               candidate_recycle_first[2] ? 3'd2 :
                               candidate_recycle_first[3] ? 3'd3 :
                               candidate_recycle_first[4] ? 3'd4 :
                               candidate_recycle_first[5] ? 3'd5 :
                               candidate_recycle_first[6] ? 3'd6 : 3'd7;

    // 候选门禁只保留一套算术路径。活动画面内用于评估即将复用的旧候选；
    // 帧结束后再逐个扫描仍留在槽中的候选，避免为每个候选复制面积和长宽比乘法器。
    localparam [2:0] SELECT_IDLE  = 3'd0;
    localparam [2:0] SELECT_FLUSH = 3'd1;
    localparam [2:0] SELECT_INIT  = 3'd2;
    localparam [2:0] SELECT_SCAN  = 3'd3;
    localparam [2:0] SELECT_DRAIN = 3'd4;
    reg [2:0] select_state;
    reg [2:0] scan_index;
    reg       scan_tracking;
    reg [2:0] flush_count;
    reg       select_done;

    reg        completed_best_valid;
    reg [19:0] completed_best_count;
    reg [11:0] completed_best_distance;
    reg [10:0] completed_best_x_min;
    reg [10:0] completed_best_x_max;
    reg [9:0]  completed_best_y_min;
    reg [9:0]  completed_best_y_max;

    reg        selected_valid;
    reg [19:0] selected_count;
    reg [11:0] selected_distance;
    reg [10:0] selected_x_min;
    reg [10:0] selected_x_max;
    reg [9:0]  selected_y_min;
    reg [9:0]  selected_y_max;

    // M3S把候选评估拆成三段流水。活动画面回收槽位时先锁存旧候选快照，
    // 同一拍仍可用新像素复用槽位；后续计算不再读取已经被覆盖的候选数组。
    // 帧末扫描复用同一流水线，保持每拍一个候选的吞吐率。
    wire eval_feed_recycle = mask_selected && !match_found && !free_found && recycle_found;
    wire eval_feed_scan = (select_state == SELECT_SCAN);
    wire eval_feed_valid = eval_feed_recycle || eval_feed_scan;
    wire [2:0] eval_feed_index = eval_feed_scan ? scan_index : recycle_index;
    wire eval_feed_last = eval_feed_scan && (scan_index == CANDIDATE_COUNT - 1);

    reg        eval_s0_valid;
    reg        eval_s0_scan;
    reg        eval_s0_last;
    reg        eval_s0_tracking;
    reg        eval_s0_used;
    reg [19:0] eval_s0_count;
    reg [10:0] eval_s0_x_min;
    reg [10:0] eval_s0_x_max;
    reg [9:0]  eval_s0_y_min;
    reg [9:0]  eval_s0_y_max;

    wire [10:0] eval_s0_width = eval_s0_x_max - eval_s0_x_min + 11'd1;
    wire [9:0]  eval_s0_height = eval_s0_y_max - eval_s0_y_min + 10'd1;
    wire [11:0] eval_s0_center_x_sum = {1'b0, eval_s0_x_min} +
                                       {1'b0, eval_s0_x_max};
    wire [10:0] eval_s0_center_y_sum = {1'b0, eval_s0_y_min} +
                                       {1'b0, eval_s0_y_max};
    wire [10:0] eval_s0_center_x = eval_s0_center_x_sum[11:1];
    wire [9:0]  eval_s0_center_y = eval_s0_center_y_sum[10:1];
    wire [10:0] eval_s0_distance_x = (eval_s0_center_x >= centroid_x) ?
                                     (eval_s0_center_x - centroid_x) :
                                     (centroid_x - eval_s0_center_x);
    wire [9:0] eval_s0_distance_y = (eval_s0_center_y >= centroid_y) ?
                                    (eval_s0_center_y - centroid_y) :
                                    (centroid_y - eval_s0_center_y);

    reg        eval_s1_valid;
    reg        eval_s1_scan;
    reg        eval_s1_last;
    reg        eval_s1_tracking;
    reg        eval_s1_used;
    reg [19:0] eval_s1_count;
    reg [10:0] eval_s1_x_min;
    reg [10:0] eval_s1_x_max;
    reg [9:0]  eval_s1_y_min;
    reg [9:0]  eval_s1_y_max;
    reg [10:0] eval_s1_width;
    reg [9:0]  eval_s1_height;
    reg [11:0] eval_s1_distance;
    reg [20:0] eval_s1_box_area;

    wire [11:0] eval_s1_width_ext = {1'b0, eval_s1_width};
    wire [11:0] eval_s1_height_ext = {2'b0, eval_s1_height};
    wire [12:0] eval_s1_width_x2 = {eval_s1_width_ext, 1'b0};
    wire [12:0] eval_s1_height_x2 = {eval_s1_height_ext, 1'b0};
    wire [20:0] eval_s1_count_x2 = {eval_s1_count, 1'b0};
    wire [21:0] eval_s1_count_x3 = {2'b0, eval_s1_count} +
                                   {1'b0, eval_s1_count, 1'b0};
    wire eval_s1_area_ok = eval_s1_tracking ?
                           ((eval_s1_count >= TRACK_MIN_AREA) &&
                            (eval_s1_count <= TRACK_MAX_AREA)) :
                           ((eval_s1_count >= MIN_AREA) &&
                            (eval_s1_count <= MAX_AREA));
    wire eval_s1_size_ok = eval_s1_tracking ?
                           ((eval_s1_width <= TRACK_MAX_BOX) &&
                            (eval_s1_height <= TRACK_MAX_BOX[9:0])) :
                           ((eval_s1_width <= MAX_BOX_WIDTH) &&
                            (eval_s1_height <= MAX_BOX_HEIGHT));
    // 圆形笔头即使边缘检测不完整，包围框通常仍接近正方形且具有较高填充率。
    // 长宽比统一限制在2:1内；首次捕获要求至少1/2填充，跟踪时放宽到1/3。
    wire eval_s1_aspect_ok = ({1'b0, eval_s1_width_ext} <= eval_s1_height_x2) &&
                             ({1'b0, eval_s1_height_ext} <= eval_s1_width_x2);
    wire eval_s1_fill_ok = eval_s1_tracking ?
                           (eval_s1_count_x3 >= {1'b0, eval_s1_box_area}) :
                           (eval_s1_count_x2 >= eval_s1_box_area);

    reg        eval_s2_valid;
    reg        eval_s2_scan;
    reg        eval_s2_last;
    reg        eval_s2_ok;
    reg [19:0] eval_s2_count;
    reg [11:0] eval_s2_distance;
    reg [10:0] eval_s2_x_min;
    reg [10:0] eval_s2_x_max;
    reg [9:0]  eval_s2_y_min;
    reg [9:0]  eval_s2_y_max;

    integer candidate_reset;
    always @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            for (candidate_reset = 0; candidate_reset < CANDIDATE_COUNT; candidate_reset = candidate_reset + 1) begin
                candidate_used[candidate_reset]  <= 1'b0;
                candidate_count[candidate_reset] <= 20'd0;
                candidate_x_min[candidate_reset] <= 11'd1279;
                candidate_x_max[candidate_reset] <= 11'd0;
                candidate_y_min[candidate_reset] <= 10'd719;
                candidate_y_max[candidate_reset] <= 10'd0;
            end
        end else if (frame_start) begin
            for (candidate_reset = 0; candidate_reset < CANDIDATE_COUNT; candidate_reset = candidate_reset + 1) begin
                candidate_used[candidate_reset]  <= 1'b0;
                candidate_count[candidate_reset] <= 20'd0;
                candidate_x_min[candidate_reset] <= 11'd1279;
                candidate_x_max[candidate_reset] <= 11'd0;
                candidate_y_min[candidate_reset] <= 10'd719;
                candidate_y_max[candidate_reset] <= 10'd0;
            end
        end else if (mask_selected) begin
            for (candidate_reset = 0; candidate_reset < CANDIDATE_COUNT; candidate_reset = candidate_reset + 1) begin
                if (candidate_match_first[candidate_reset]) begin
                    candidate_count[candidate_reset] <= candidate_count[candidate_reset] + 1'b1;
                    if (mask_x < candidate_x_min[candidate_reset]) candidate_x_min[candidate_reset] <= mask_x;
                    if (mask_x > candidate_x_max[candidate_reset]) candidate_x_max[candidate_reset] <= mask_x;
                    if (mask_y < candidate_y_min[candidate_reset]) candidate_y_min[candidate_reset] <= mask_y;
                    if (mask_y > candidate_y_max[candidate_reset]) candidate_y_max[candidate_reset] <= mask_y;
                end else if (!match_found && candidate_new_first[candidate_reset]) begin
                    // 没有匹配候选时优先使用最低编号空槽；无空槽才复用最低编号闭合候选。
                    // 被回收候选已由评估流水线首级在本拍锁存，因此槽位可立即接收新区域。
                    candidate_used[candidate_reset]  <= 1'b1;
                    candidate_count[candidate_reset] <= 20'd1;
                    candidate_x_min[candidate_reset] <= mask_x;
                    candidate_x_max[candidate_reset] <= mask_x;
                    candidate_y_min[candidate_reset] <= mask_y;
                    candidate_y_max[candidate_reset] <= mask_y;
                end
            end
        end
    end

    // 候选评估流水：第一级锁存快照，第二级计算宽高/中心/距离/框面积，
    // 第三级登记门禁结果。三级间只传递寄存数据，切断动态索引到最优框的长组合路径。
    always @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            eval_s0_valid <= 1'b0;
            eval_s1_valid <= 1'b0;
            eval_s2_valid <= 1'b0;
        end else if (frame_start) begin
            eval_s0_valid <= 1'b0;
            eval_s1_valid <= 1'b0;
            eval_s2_valid <= 1'b0;
        end else begin
            eval_s0_valid <= eval_feed_valid;
            if (eval_feed_valid) begin
                eval_s0_scan     <= eval_feed_scan;
                eval_s0_last     <= eval_feed_last;
                eval_s0_tracking <= eval_feed_scan ? scan_tracking : object_valid;
                eval_s0_used     <= candidate_used[eval_feed_index];
                eval_s0_count    <= candidate_count[eval_feed_index];
                eval_s0_x_min    <= candidate_x_min[eval_feed_index];
                eval_s0_x_max    <= candidate_x_max[eval_feed_index];
                eval_s0_y_min    <= candidate_y_min[eval_feed_index];
                eval_s0_y_max    <= candidate_y_max[eval_feed_index];
            end

            eval_s1_valid <= eval_s0_valid;
            if (eval_s0_valid) begin
                eval_s1_scan     <= eval_s0_scan;
                eval_s1_last     <= eval_s0_last;
                eval_s1_tracking <= eval_s0_tracking;
                eval_s1_used     <= eval_s0_used;
                eval_s1_count    <= eval_s0_count;
                eval_s1_x_min    <= eval_s0_x_min;
                eval_s1_x_max    <= eval_s0_x_max;
                eval_s1_y_min    <= eval_s0_y_min;
                eval_s1_y_max    <= eval_s0_y_max;
                eval_s1_width    <= eval_s0_width;
                eval_s1_height   <= eval_s0_height;
                eval_s1_distance <= {1'b0, eval_s0_distance_x} +
                                    {2'b0, eval_s0_distance_y};
                eval_s1_box_area <= eval_s0_width * eval_s0_height;
            end

            eval_s2_valid <= eval_s1_valid;
            if (eval_s1_valid) begin
                eval_s2_scan     <= eval_s1_scan;
                eval_s2_last     <= eval_s1_last;
                eval_s2_ok       <= eval_s1_used && eval_s1_area_ok &&
                                    eval_s1_size_ok && eval_s1_aspect_ok &&
                                    eval_s1_fill_ok;
                eval_s2_count    <= eval_s1_count;
                eval_s2_distance <= eval_s1_distance;
                eval_s2_x_min    <= eval_s1_x_min;
                eval_s2_x_max    <= eval_s1_x_max;
                eval_s2_y_min    <= eval_s1_y_min;
                eval_s2_y_max    <= eval_s1_y_max;
            end
        end
    end

    // frame_end位于垂直消隐开始处。先等待评估流水完全排空，再初始化帧末最优值；
    // 随后连续送入8个活动候选，直到最后一个候选的结果提交才产生select_done。
    always @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            select_state  <= SELECT_IDLE;
            scan_index    <= 3'd0;
            scan_tracking <= 1'b0;
            flush_count   <= 3'd0;
        end else if (frame_start) begin
            select_state <= SELECT_IDLE;
            scan_index   <= 3'd0;
            flush_count  <= 3'd0;
        end else begin
            case (select_state)
                SELECT_IDLE: begin
                    if (frame_end) begin
                        scan_tracking <= object_valid;
                        flush_count   <= 3'd0;
                        select_state  <= SELECT_FLUSH;
                    end
                end
                SELECT_FLUSH: begin
                    if (flush_count == 3'd3) begin
                        select_state <= SELECT_INIT;
                    end else begin
                        flush_count <= flush_count + 1'b1;
                    end
                end
                SELECT_INIT: begin
                    scan_index   <= 3'd0;
                    select_state <= SELECT_SCAN;
                end
                SELECT_SCAN: begin
                    if (scan_index == CANDIDATE_COUNT - 1) begin
                        select_state <= SELECT_DRAIN;
                    end else begin
                        scan_index <= scan_index + 1'b1;
                    end
                end
                SELECT_DRAIN: begin
                    if (select_done) select_state <= SELECT_IDLE;
                end
                default: select_state <= SELECT_IDLE;
            endcase
        end
    end

    // 回收候选和帧末候选在流水末级分别更新各自最优值。所有比较均以快照数据为准，
    // 因而候选槽位的后续复用不会改变正在评估的面积、位置或形状。
    always @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            completed_best_valid <= 1'b0;
            completed_best_count <= 20'd0;
            completed_best_distance <= 12'hfff;
            completed_best_x_min <= 11'd0;
            completed_best_x_max <= 11'd0;
            completed_best_y_min <= 10'd0;
            completed_best_y_max <= 10'd0;
            select_done <= 1'b0;
            selected_valid <= 1'b0;
            selected_count <= 20'd0;
            selected_distance <= 12'hfff;
            selected_x_min <= 11'd0;
            selected_x_max <= 11'd0;
            selected_y_min <= 10'd0;
            selected_y_max <= 10'd0;
        end else begin
            select_done <= 1'b0;
            if (frame_start) begin
                completed_best_valid <= 1'b0;
                completed_best_count <= 20'd0;
                completed_best_distance <= 12'hfff;
                completed_best_x_min <= 11'd0;
                completed_best_x_max <= 11'd0;
                completed_best_y_min <= 10'd0;
                completed_best_y_max <= 10'd0;
            end else if (eval_s2_valid && !eval_s2_scan && eval_s2_ok &&
                         (!completed_best_valid ||
                          (object_valid ?
                           ((eval_s2_distance < completed_best_distance) ||
                            ((eval_s2_distance == completed_best_distance) &&
                             (eval_s2_count > completed_best_count))) :
                           (eval_s2_count > completed_best_count)))) begin
                completed_best_valid <= 1'b1;
                completed_best_count <= eval_s2_count;
                completed_best_distance <= eval_s2_distance;
                completed_best_x_min <= eval_s2_x_min;
                completed_best_x_max <= eval_s2_x_max;
                completed_best_y_min <= eval_s2_y_min;
                completed_best_y_max <= eval_s2_y_max;
            end

            if (select_state == SELECT_INIT) begin
                selected_valid <= completed_best_valid;
                selected_count <= completed_best_count;
                selected_distance <= completed_best_distance;
                selected_x_min <= completed_best_x_min;
                selected_x_max <= completed_best_x_max;
                selected_y_min <= completed_best_y_min;
                selected_y_max <= completed_best_y_max;
            end else if (eval_s2_valid && eval_s2_scan) begin
                if (eval_s2_ok && (!selected_valid ||
                    (scan_tracking ?
                     ((eval_s2_distance < selected_distance) ||
                      ((eval_s2_distance == selected_distance) &&
                       (eval_s2_count > selected_count))) :
                     (eval_s2_count > selected_count)))) begin
                    selected_valid <= 1'b1;
                    selected_count <= eval_s2_count;
                    selected_distance <= eval_s2_distance;
                    selected_x_min <= eval_s2_x_min;
                    selected_x_max <= eval_s2_x_max;
                    selected_y_min <= eval_s2_y_min;
                    selected_y_max <= eval_s2_y_max;
                end
                if (eval_s2_last) select_done <= 1'b1;
            end
        end
    end

    // 圆形笔头使用包围框中心作为跟踪点。框坐标已经能正确跟随目标，直接取中心可彻底
    // 避免坐标和除法异常把质心送到屏幕左侧，同时删除8组坐标和及两次32拍除法。
    // 锁定后新旧坐标各占1/2，抑制mask边缘逐帧变化造成的框尺寸与中心抖动。
    reg [10:0] bbox_x_min_display;
    reg [10:0] bbox_x_max_display;
    reg [9:0]  bbox_y_min_display;
    reg [9:0]  bbox_y_max_display;
    reg [2:0]  track_miss_count;

    wire [11:0] selected_center_x_sum = {1'b0, selected_x_min} +
                                        {1'b0, selected_x_max};
    wire [10:0] selected_center_y_sum = {1'b0, selected_y_min} +
                                        {1'b0, selected_y_max};
    wire [10:0] selected_center_x = selected_center_x_sum[11:1];
    wire [9:0]  selected_center_y = selected_center_y_sum[10:1];

    always @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            bbox_x_min_display     <= 11'd0;
            bbox_x_max_display     <= 11'd0;
            bbox_y_min_display     <= 10'd0;
            bbox_y_max_display     <= 10'd0;
            centroid_x             <= 11'd0;
            centroid_y             <= 10'd0;
            object_area            <= 20'd0;
            object_valid           <= 1'b0;
            track_miss_count       <= 3'd0;
        end else if (select_done) begin
            if (selected_valid) begin
                object_area <= selected_count;
                if (object_valid) begin
                    centroid_x <= ({1'b0, centroid_x} +
                                   {1'b0, selected_center_x}) >> 1;
                    centroid_y <= ({1'b0, centroid_y} +
                                   {1'b0, selected_center_y}) >> 1;
                    bbox_x_min_display <= ({1'b0, bbox_x_min_display} +
                                           {1'b0, selected_x_min}) >> 1;
                    bbox_x_max_display <= ({1'b0, bbox_x_max_display} +
                                           {1'b0, selected_x_max}) >> 1;
                    bbox_y_min_display <= ({1'b0, bbox_y_min_display} +
                                           {1'b0, selected_y_min}) >> 1;
                    bbox_y_max_display <= ({1'b0, bbox_y_max_display} +
                                           {1'b0, selected_y_max}) >> 1;
                end else begin
                    centroid_x         <= selected_center_x;
                    centroid_y         <= selected_center_y;
                    bbox_x_min_display <= selected_x_min;
                    bbox_x_max_display <= selected_x_max;
                    bbox_y_min_display <= selected_y_min;
                    bbox_y_max_display <= selected_y_max;
                end
                object_valid     <= 1'b1;
                track_miss_count <= 3'd0;
            end else begin
                object_area <= 20'd0;
                if (object_valid && (track_miss_count < 3'd2)) begin
                    track_miss_count <= track_miss_count + 1'b1;
                end else begin
                    object_valid     <= 1'b0;
                    track_miss_count <= 3'd0;
                end
            end
        end
    end

    // 轨迹采用160×90单比特网格，每个轨迹格映射到8×8画面像素。
    // 相邻有效中心在垂直消隐期用Bresenham逐点连接；连续3帧失配真正解锁后，
    // 下一次捕获从新点起笔，避免把两个独立笔画跨屏连接。M3R把直接连接上限
    // 放宽到12格（约96像素/帧），兼顾较快书写；更大跳变仍执行两帧确认。
    localparam [13:0] TRAJECTORY_LAST_ADDR = 14'd14399;
    localparam [7:0]  TRAJECTORY_MAX_STEP = 8'd12;
    localparam [7:0]  TRAJECTORY_CONFIRM_RADIUS = 8'd4;
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
    reg        trajectory_pending_valid;
    reg [7:0]  trajectory_pending_x;
    reg [6:0]  trajectory_pending_y;

    wire [11:0] trajectory_center_x_accum = {1'b0, centroid_x} +
                                             {1'b0, selected_center_x};
    wire [10:0] trajectory_center_y_accum = {1'b0, centroid_y} +
                                             {1'b0, selected_center_y};
    wire [10:0] trajectory_center_x_next = object_valid ?
                                             trajectory_center_x_accum[11:1] :
                                             selected_center_x;
    wire [9:0] trajectory_center_y_next = object_valid ?
                                            trajectory_center_y_accum[10:1] :
                                            selected_center_y;
    wire [7:0] trajectory_target_x = trajectory_center_x_next[10:3];
    wire [6:0] trajectory_target_y = trajectory_center_y_next[9:3];
    wire [7:0] trajectory_start_x = trajectory_have_prev ?
                                     trajectory_prev_x : trajectory_target_x;
    wire [6:0] trajectory_start_y = trajectory_have_prev ?
                                     trajectory_prev_y : trajectory_target_y;
    wire [7:0] trajectory_new_dx = (trajectory_target_x >= trajectory_start_x) ?
                                    (trajectory_target_x - trajectory_start_x) :
                                    (trajectory_start_x - trajectory_target_x);
    wire [6:0] trajectory_new_dy = (trajectory_target_y >= trajectory_start_y) ?
                                    (trajectory_target_y - trajectory_start_y) :
                                    (trajectory_start_y - trajectory_target_y);
    wire trajectory_jump_far = (trajectory_new_dx > TRAJECTORY_MAX_STEP) ||
                               ({1'b0, trajectory_new_dy} > TRAJECTORY_MAX_STEP);
    wire [7:0] trajectory_pending_dx =
        (trajectory_target_x >= trajectory_pending_x) ?
        (trajectory_target_x - trajectory_pending_x) :
        (trajectory_pending_x - trajectory_target_x);
    wire [6:0] trajectory_pending_dy =
        (trajectory_target_y >= trajectory_pending_y) ?
        (trajectory_target_y - trajectory_pending_y) :
        (trajectory_pending_y - trajectory_target_y);
    wire trajectory_pending_match =
        (trajectory_pending_dx <= TRAJECTORY_CONFIRM_RADIUS) &&
        ({1'b0, trajectory_pending_dy} <= TRAJECTORY_CONFIRM_RADIUS);
    // 有序点列只记录已经被轨迹门禁接受的平滑中心。两帧确认的大跳变作为
    // 新段起点保存但connected=0，后级统计弧长时不会把误差区间补成虚假长线。
    wire trajectory_sample_accepted = !trajectory_have_prev ||
                                      !trajectory_jump_far ||
                                      (trajectory_pending_valid && trajectory_pending_match);
    assign trajectory_sample_valid = select_done && selected_valid &&
                                     pen_mode_enable && !trajectory_clearing &&
                                     !trajectory_frozen && !trajectory_clear &&
                                     !trajectory_confirm && trajectory_sample_accepted;
    assign trajectory_sample_connected = trajectory_have_prev && !trajectory_jump_far;
    assign trajectory_sample_x = trajectory_center_x_next;
    assign trajectory_sample_y = trajectory_center_y_next;
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
                                   (pen_mode_enable && !trajectory_frozen &&
                                    !trajectory_confirm && trajectory_line_busy);
    wire [13:0] trajectory_write_addr = trajectory_clearing ?
                                         trajectory_clear_addr : trajectory_line_addr;
    wire trajectory_write_data = !trajectory_clearing;

    always @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            trajectory_clearing     <= 1'b1;
            trajectory_frozen       <= 1'b0;
            trajectory_clear_addr   <= 14'd0;
            trajectory_have_prev    <= 1'b0;
            trajectory_prev_x       <= 8'd0;
            trajectory_prev_y       <= 7'd0;
            trajectory_line_busy    <= 1'b0;
            trajectory_line_x       <= 8'd0;
            trajectory_line_y       <= 7'd0;
            trajectory_line_target_x <= 8'd0;
            trajectory_line_target_y <= 7'd0;
            trajectory_line_dx      <= 8'd0;
            trajectory_line_dy      <= 7'd0;
            trajectory_line_x_inc   <= 1'b1;
            trajectory_line_y_inc   <= 1'b1;
            trajectory_line_error   <= 10'sd0;
            trajectory_pending_valid <= 1'b0;
            trajectory_pending_x     <= 8'd0;
            trajectory_pending_y     <= 7'd0;
        end else if (trajectory_clear) begin
            // S3清空会从地址0重新擦除整张轨迹位图，同时解除S4确认后的冻结状态。
            trajectory_clearing      <= 1'b1;
            trajectory_frozen        <= 1'b0;
            trajectory_clear_addr    <= 14'd0;
            trajectory_have_prev     <= 1'b0;
            trajectory_line_busy     <= 1'b0;
            trajectory_pending_valid <= 1'b0;
        end else if (trajectory_clearing) begin
            trajectory_line_busy <= 1'b0;
            trajectory_have_prev <= 1'b0;
            trajectory_pending_valid <= 1'b0;
            if (trajectory_clear_addr == TRAJECTORY_LAST_ADDR) begin
                trajectory_clearing <= 1'b0;
            end else begin
                trajectory_clear_addr <= trajectory_clear_addr + 1'b1;
            end
        end else if (trajectory_confirm) begin
            // S4确认只冻结轨迹写入，不停止红笔检测和框/质心显示；S3清空后重新书写。
            trajectory_frozen        <= 1'b1;
            trajectory_line_busy     <= 1'b0;
            trajectory_have_prev     <= 1'b0;
            trajectory_pending_valid <= 1'b0;
        end else if (!pen_mode_enable || trajectory_frozen) begin
            // 手写模式与已确认状态均不得继续改变笔写轨迹，但已画位图保持不变。
            trajectory_line_busy     <= 1'b0;
            trajectory_have_prev     <= 1'b0;
            trajectory_pending_valid <= 1'b0;
        end else begin
            if (!object_valid && !(select_done && selected_valid)) begin
                trajectory_have_prev <= 1'b0;
                trajectory_pending_valid <= 1'b0;
            end

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
                    if (trajectory_step_x) begin
                        if (trajectory_line_x_inc)
                            trajectory_line_x <= trajectory_line_x + 1'b1;
                        else
                            trajectory_line_x <= trajectory_line_x - 1'b1;
                    end
                    if (trajectory_step_y) begin
                        if (trajectory_line_y_inc)
                            trajectory_line_y <= trajectory_line_y + 1'b1;
                        else
                            trajectory_line_y <= trajectory_line_y - 1'b1;
                    end
                end
            end

            if (select_done && selected_valid) begin
                if (!trajectory_have_prev) begin
                    trajectory_line_x        <= trajectory_target_x;
                    trajectory_line_y        <= trajectory_target_y;
                    trajectory_line_target_x <= trajectory_target_x;
                    trajectory_line_target_y <= trajectory_target_y;
                    trajectory_line_dx       <= 8'd0;
                    trajectory_line_dy       <= 7'd0;
                    trajectory_line_error    <= 10'sd0;
                    trajectory_line_busy     <= 1'b1;
                    trajectory_prev_x        <= trajectory_target_x;
                    trajectory_prev_y        <= trajectory_target_y;
                    trajectory_have_prev     <= 1'b1;
                    trajectory_pending_valid <= 1'b0;
                end else if (!trajectory_jump_far) begin
                    trajectory_line_x        <= trajectory_prev_x;
                    trajectory_line_y        <= trajectory_prev_y;
                    trajectory_line_target_x <= trajectory_target_x;
                    trajectory_line_target_y <= trajectory_target_y;
                    trajectory_line_dx       <= trajectory_new_dx;
                    trajectory_line_dy       <= trajectory_new_dy;
                    trajectory_line_x_inc    <= trajectory_target_x >= trajectory_prev_x;
                    trajectory_line_y_inc    <= trajectory_target_y >= trajectory_prev_y;
                    trajectory_line_error    <= trajectory_new_error;
                    trajectory_line_busy     <= 1'b1;
                    trajectory_prev_x        <= trajectory_target_x;
                    trajectory_prev_y        <= trajectory_target_y;
                    trajectory_pending_valid <= 1'b0;
                end else if (trajectory_pending_valid && trajectory_pending_match) begin
                    // 连续两帧都落在新位置时确认是真实移动，但从新点重新起笔，不画长分支。
                    trajectory_line_x        <= trajectory_target_x;
                    trajectory_line_y        <= trajectory_target_y;
                    trajectory_line_target_x <= trajectory_target_x;
                    trajectory_line_target_y <= trajectory_target_y;
                    trajectory_line_dx       <= 8'd0;
                    trajectory_line_dy       <= 7'd0;
                    trajectory_line_error    <= 10'sd0;
                    trajectory_line_busy     <= 1'b1;
                    trajectory_prev_x        <= trajectory_target_x;
                    trajectory_prev_y        <= trajectory_target_y;
                    trajectory_pending_valid <= 1'b0;
                end else begin
                    // 单帧大跳变只暂存，不更新上一轨迹点，也不写入永久位图。
                    trajectory_pending_valid <= 1'b1;
                    trajectory_pending_x     <= trajectory_target_x;
                    trajectory_pending_y     <= trajectory_target_y;
                end
            end
        end
    end

    // B口同步读取当前8×8轨迹格。读数据晚一个PCLK，因此最终RGB、框/中心标志
    // 以及frame_valid/pixel_valid都再延迟一拍，保证送往DDR的内容与写使能对齐。
    wire [7:0] trajectory_read_x = pixel_x_d[10:3];
    wire [6:0] trajectory_read_y = pixel_y_d[9:3];
    wire [13:0] trajectory_read_addr =
        {trajectory_read_y, 7'b0} +
        {2'b0, trajectory_read_y, 5'b0} +
        {6'b0, trajectory_read_x};
    wire trajectory_read_bit;
    trajectory_bitmap_sdpb u_trajectory_bitmap (
        .clka  (pclk),
        .cea   (trajectory_write_enable),
        .ada   (trajectory_write_addr),
        .din   (trajectory_write_data),
        .clkb  (pclk),
        .ceb   (pixel_valid_d),
        .adb   (trajectory_read_addr),
        .oce   (1'b1),
        .reset (~reset_n),
        .dout  (trajectory_read_bit)
    );

    // 检测坐标已经是完整1280×720画面坐标，可直接用于框和质心叠加。
    wire [10:0] box_x_min_full = bbox_x_min_display;
    wire [10:0] box_x_max_full = bbox_x_max_display;
    wire [10:0] box_y_min_full = {1'b0, bbox_y_min_display};
    wire [10:0] box_y_max_full = {1'b0, bbox_y_max_display};
    wire [10:0] center_x_full  = centroid_x;
    wire [10:0] center_y_full  = {1'b0, centroid_y};

    wire inside_box_x = (pixel_x_d >= box_x_min_full) && (pixel_x_d <= box_x_max_full);
    wire inside_box_y = (pixel_y_d >= box_y_min_full) && (pixel_y_d <= box_y_max_full);
    wire on_box = object_valid && pixel_valid_d && inside_box_x && inside_box_y &&
                  ((pixel_x_d == box_x_min_full) || (pixel_x_d == box_x_max_full) ||
                   (pixel_y_d == box_y_min_full) || (pixel_y_d == box_y_max_full));

    wire [10:0] center_x_lo = (center_x_full >= 11'd2) ? center_x_full - 11'd2 : 11'd0;
    wire [10:0] center_x_hi = (center_x_full <= 11'd1277) ? center_x_full + 11'd2 : 11'd1279;
    wire [10:0] center_y_lo = (center_y_full >= 11'd2) ? center_y_full - 11'd2 : 11'd0;
    wire [10:0] center_y_hi = (center_y_full <= 11'd717) ? center_y_full + 11'd2 : 11'd719;
    wire on_center = object_valid && pixel_valid_d &&
                     (pixel_x_d >= center_x_lo) && (pixel_x_d <= center_x_hi) &&
                     (pixel_y_d >= center_y_lo) && (pixel_y_d <= center_y_hi);

    // 手写模式从本模块输出原画；笔写调试显示过滤mask，笔写普通画面依次叠加
    // 白色中心、绿色框和黄色轨迹。所有分支保持相同两拍像素延迟。
    wire [15:0] pixel_before_trajectory =
        !pen_mode_enable  ? pixel_in_d :
        debug_mask_enable ? (mask_red ? 16'hF800 : pixel_in_d) :
        on_center         ? 16'hFFFF :
        on_box            ? 16'h07E0 :
                            pixel_in_d;
    reg [15:0] pixel_before_trajectory_d;
    reg        marker_d;
    reg        debug_mask_enable_d;
    reg        pen_mode_enable_d;
    reg        frame_valid_overlay_d;
    reg        pixel_valid_overlay_d;

    always @(posedge pclk or negedge reset_n) begin
        if (!reset_n) begin
            pixel_before_trajectory_d <= 16'd0;
            marker_d                  <= 1'b0;
            debug_mask_enable_d       <= 1'b0;
            pen_mode_enable_d         <= 1'b0;
            frame_valid_overlay_d     <= 1'b0;
            pixel_valid_overlay_d     <= 1'b0;
        end else begin
            frame_valid_overlay_d <= frame_valid_d;
            pixel_valid_overlay_d <= pixel_valid_d;
            debug_mask_enable_d   <= debug_mask_enable;
            pen_mode_enable_d     <= pen_mode_enable;
            marker_d              <= pen_mode_enable && (on_center || on_box);
            if (pixel_valid_d)
                pixel_before_trajectory_d <= pixel_before_trajectory;
        end
    end

    assign frame_valid_out = frame_valid_overlay_d;
    assign pixel_valid_out = pixel_valid_overlay_d;
    assign pixel_out = !pen_mode_enable_d  ? pixel_before_trajectory_d :
                       debug_mask_enable_d ? pixel_before_trajectory_d :
                       marker_d            ? pixel_before_trajectory_d :
                       trajectory_read_bit ? 16'hFFE0 :
                                             pixel_before_trajectory_d;

endmodule
