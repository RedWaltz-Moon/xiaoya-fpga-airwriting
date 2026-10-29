`timescale 1ns / 1ps

// 标准CEA-861 1280×720@60扫描时序与RGB565摄像头画面输出。
// 第一帧DDR写完后等待新的HDMI扫描帧再开始取数，保证FIFO首像素对应屏幕左上角。
module video_720p_camera (
    input  wire        pixel_clk,
    input  wire        reset_n,
    input  wire        frame_ready,
    input  wire [15:0] pixel_data,
    input  wire        pixel_empty,
    input  wire        work_mode_async,
    input  wire        result_armed_async,
    input  wire        result_valid_async,
    input  wire [7:0]  result_ascii_async,
    input  wire [27:0] health_payload_async,
    input  wire        health_request_async,
    output reg         health_ack,
    output wire        pixel_read,
    output reg         underflow,
    output reg         hsync,
    output reg         vsync,
    output reg         de,
    output reg  [7:0]  red,
    output reg  [7:0]  green,
    output reg  [7:0]  blue
);

    localparam [11:0] H_SYNC   = 12'd40;
    localparam [11:0] H_BACK   = 12'd220;
    localparam [11:0] H_ACTIVE = 12'd1280;
    localparam [11:0] H_TOTAL  = 12'd1650;
    localparam [11:0] V_SYNC   = 12'd5;
    localparam [11:0] V_BACK   = 12'd20;
    localparam [11:0] V_ACTIVE = 12'd720;
    localparam [11:0] V_TOTAL  = 12'd750;
    localparam [11:0] H_START  = H_SYNC + H_BACK;
    localparam [11:0] H_END    = H_START + H_ACTIVE;
    localparam [11:0] V_START  = V_SYNC + V_BACK;
    localparam [11:0] V_END    = V_START + V_ACTIVE;

    reg [11:0] h_count;
    reg [11:0] v_count;
    reg horizontal_active;
    reg vertical_active;
    reg [1:0]  frame_ready_sync;
    reg        stream_active;
    reg [1:0]  work_mode_sync;
    reg [1:0]  result_armed_sync;
    reg [1:0]  result_valid_sync;
    reg [7:0]  result_ascii_sync0;
    reg [7:0]  result_ascii_sync1;
    reg        display_work_mode;
    reg        display_result_armed;
    reg        display_result_valid;
    reg [7:0]  display_result_ascii;
    reg [2:0] health_request_sync;
    reg [27:0] health_payload_sync0;
    reg [27:0] health_payload_sync1;
    reg [27:0] display_health;

    wire raster_now = horizontal_active && vertical_active;
    wire active_now = stream_active && raster_now;
    wire [11:0] active_x = h_count - H_START;
    wire [11:0] active_y = v_count - V_START;

    // 单字符5×7字模按16倍放大成80×112像素，水平居中放在画面顶部。
    // 结果字符在50 MHz域锁存并保持到S3清空，两级同步后再用于像素域显示。
    wire in_result_area = display_result_valid && active_now &&
                          (active_x >= 12'd600) && (active_x < 12'd680) &&
                          (active_y >= 12'd16)  && (active_y < 12'd128);
    wire [2:0] result_col = (active_x - 12'd600) >> 4;
    wire [2:0] result_row = (active_y - 12'd16) >> 4;
    wire [5:0] result_bit_index = (result_row * 6'd5) + result_col;

    function [34:0] glyph_5x7;
        input [7:0] ascii_in;
        begin
            // 每组从上到下共7行、每行从左到右5位；未支持字符显示为空白。
            case (ascii_in)
                8'h30: glyph_5x7 = {5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
                8'h31: glyph_5x7 = {5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                8'h32: glyph_5x7 = {5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
                8'h33: glyph_5x7 = {5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
                8'h34: glyph_5x7 = {5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
                8'h35: glyph_5x7 = {5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
                8'h36: glyph_5x7 = {5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
                8'h37: glyph_5x7 = {5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
                8'h38: glyph_5x7 = {5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
                8'h39: glyph_5x7 = {5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
                8'h2D: glyph_5x7 = {5'b00000,5'b00000,5'b00000,5'b11111,5'b00000,5'b00000,5'b00000};
                8'h3A: glyph_5x7 = {5'b00000,5'b00100,5'b00100,5'b00000,5'b00100,5'b00100,5'b00000};
                8'h41: glyph_5x7 = {5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                8'h42: glyph_5x7 = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
                8'h43: glyph_5x7 = {5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
                8'h44: glyph_5x7 = {5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
                8'h45: glyph_5x7 = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
                8'h46: glyph_5x7 = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
                8'h47: glyph_5x7 = {5'b01111,5'b10000,5'b10000,5'b10111,5'b10001,5'b10001,5'b01111};
                8'h48: glyph_5x7 = {5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                8'h49: glyph_5x7 = {5'b01110,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                8'h4A: glyph_5x7 = {5'b00111,5'b00010,5'b00010,5'b00010,5'b10010,5'b10010,5'b01100};
                8'h4B: glyph_5x7 = {5'b10001,5'b10010,5'b10100,5'b11000,5'b10100,5'b10010,5'b10001};
                8'h4C: glyph_5x7 = {5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
                8'h4D: glyph_5x7 = {5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
                8'h4E: glyph_5x7 = {5'b10001,5'b11001,5'b10101,5'b10011,5'b10001,5'b10001,5'b10001};
                8'h4F: glyph_5x7 = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                8'h50: glyph_5x7 = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
                8'h51: glyph_5x7 = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10101,5'b10010,5'b01101};
                8'h52: glyph_5x7 = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
                8'h53: glyph_5x7 = {5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
                8'h54: glyph_5x7 = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
                8'h55: glyph_5x7 = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                8'h56: glyph_5x7 = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100};
                8'h57: glyph_5x7 = {5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010};
                8'h58: glyph_5x7 = {5'b10001,5'b10001,5'b01010,5'b00100,5'b01010,5'b10001,5'b10001};
                8'h59: glyph_5x7 = {5'b10001,5'b10001,5'b01010,5'b00100,5'b00100,5'b00100,5'b00100};
                8'h5A: glyph_5x7 = {5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b10000,5'b11111};
                // 小写字母采用x-height和下伸笔画，确保与对应大写字形可见地区分。
                8'h61: glyph_5x7 = {5'b00000,5'b00000,5'b01110,5'b00001,5'b01111,5'b10001,5'b01111};
                8'h62: glyph_5x7 = {5'b10000,5'b10000,5'b10110,5'b11001,5'b10001,5'b10001,5'b11110};
                8'h63: glyph_5x7 = {5'b00000,5'b00000,5'b01111,5'b10000,5'b10000,5'b10000,5'b01111};
                8'h64: glyph_5x7 = {5'b00001,5'b00001,5'b01101,5'b10011,5'b10001,5'b10001,5'b01111};
                8'h65: glyph_5x7 = {5'b00000,5'b00000,5'b01110,5'b10001,5'b11111,5'b10000,5'b01110};
                8'h66: glyph_5x7 = {5'b00110,5'b01001,5'b01000,5'b11100,5'b01000,5'b01000,5'b01000};
                8'h67: glyph_5x7 = {5'b00000,5'b01111,5'b10001,5'b10001,5'b01111,5'b00001,5'b01110};
                8'h68: glyph_5x7 = {5'b10000,5'b10000,5'b10110,5'b11001,5'b10001,5'b10001,5'b10001};
                8'h69: glyph_5x7 = {5'b00100,5'b00000,5'b01100,5'b00100,5'b00100,5'b00100,5'b01110};
                8'h6A: glyph_5x7 = {5'b00010,5'b00000,5'b00110,5'b00010,5'b00010,5'b10010,5'b01100};
                8'h6B: glyph_5x7 = {5'b10000,5'b10000,5'b10010,5'b10100,5'b11000,5'b10100,5'b10010};
                8'h6C: glyph_5x7 = {5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                8'h6D: glyph_5x7 = {5'b00000,5'b00000,5'b11010,5'b10101,5'b10101,5'b10101,5'b10101};
                8'h6E: glyph_5x7 = {5'b00000,5'b00000,5'b10110,5'b11001,5'b10001,5'b10001,5'b10001};
                8'h6F: glyph_5x7 = {5'b00000,5'b00000,5'b01110,5'b10001,5'b10001,5'b10001,5'b01110};
                8'h70: glyph_5x7 = {5'b00000,5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000};
                8'h71: glyph_5x7 = {5'b00000,5'b01111,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001};
                8'h72: glyph_5x7 = {5'b00000,5'b00000,5'b10111,5'b11000,5'b10000,5'b10000,5'b10000};
                8'h73: glyph_5x7 = {5'b00000,5'b00000,5'b01111,5'b10000,5'b01110,5'b00001,5'b11110};
                8'h74: glyph_5x7 = {5'b01000,5'b01000,5'b11100,5'b01000,5'b01000,5'b01001,5'b00110};
                8'h75: glyph_5x7 = {5'b00000,5'b00000,5'b10001,5'b10001,5'b10001,5'b10011,5'b01101};
                8'h76: glyph_5x7 = {5'b00000,5'b00000,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100};
                8'h77: glyph_5x7 = {5'b00000,5'b00000,5'b10001,5'b10001,5'b10101,5'b10101,5'b01010};
                8'h78: glyph_5x7 = {5'b00000,5'b00000,5'b10001,5'b01010,5'b00100,5'b01010,5'b10001};
                8'h79: glyph_5x7 = {5'b00000,5'b10001,5'b10001,5'b10001,5'b01111,5'b00001,5'b01110};
                8'h7A: glyph_5x7 = {5'b00000,5'b00000,5'b11111,5'b00010,5'b00100,5'b01000,5'b11111};
                default: glyph_5x7 = 35'd0;
            endcase
        end
    endfunction

    // M6B只在画面上方增加两个小状态标识：左侧PEN/HAND，右侧DRAW/WAIT/DONE。
    // 文字按4倍放大，状态和结果均在帧起点锁存，避免一帧中途切换造成撕裂。
    wire mode_badge_area = active_now &&
                           (active_x >= 12'd8) && (active_x < 12'd116) &&
                           (active_y >= 12'd8) && (active_y < 12'd52);
    wire process_badge_area = active_now &&
                              (active_x >= 12'd1156) && (active_x < 12'd1264) &&
                              (active_y >= 12'd8) && (active_y < 12'd52);
    reg        status_char_selected;
    reg [7:0]  status_ascii;
    reg [11:0] status_origin_x;
    reg [23:0] status_color;
    wire status_text_y = active_now && (active_y >= 12'd16) && (active_y < 12'd44);

    always @(*) begin
        status_char_selected = 1'b0;
        status_ascii         = 8'h20;
        status_origin_x      = 12'd0;
        status_color         = 24'hFFFFFF;

        if (status_text_y) begin
            // 左上角模式标识与已接入的PEN/HAND画面选择一致，S1切换后同步更新。
            if ((active_x >= 12'd16) && (active_x < 12'd36)) begin
                status_char_selected = 1'b1;
                status_ascii = display_work_mode ? 8'h48 : 8'h50; // H / P
                status_origin_x = 12'd16;
                status_color = 24'h00FFFF;
            end else if ((active_x >= 12'd40) && (active_x < 12'd60)) begin
                status_char_selected = 1'b1;
                status_ascii = display_work_mode ? 8'h41 : 8'h45; // A / E
                status_origin_x = 12'd40;
                status_color = 24'h00FFFF;
            end else if ((active_x >= 12'd64) && (active_x < 12'd84)) begin
                status_char_selected = 1'b1;
                status_ascii = 8'h4E; // N
                status_origin_x = 12'd64;
                status_color = 24'h00FFFF;
            end else if (display_work_mode &&
                         (active_x >= 12'd88) && (active_x < 12'd108)) begin
                status_char_selected = 1'b1;
                status_ascii = 8'h44; // D
                status_origin_x = 12'd88;
                status_color = 24'h00FFFF;
            end else if ((active_x >= 12'd1164) && (active_x < 12'd1184)) begin
                status_char_selected = 1'b1;
                status_ascii = display_result_valid ? 8'h44 :
                               (display_result_armed ? 8'h57 : 8'h44); // D / W / D
                status_origin_x = 12'd1164;
                status_color = display_result_valid ? 24'h00FF00 :
                               (display_result_armed ? 24'hFFB000 : 24'hFFFFFF);
            end else if ((active_x >= 12'd1188) && (active_x < 12'd1208)) begin
                status_char_selected = 1'b1;
                status_ascii = display_result_valid ? 8'h4F :
                               (display_result_armed ? 8'h41 : 8'h52); // O / A / R
                status_origin_x = 12'd1188;
                status_color = display_result_valid ? 24'h00FF00 :
                               (display_result_armed ? 24'hFFB000 : 24'hFFFFFF);
            end else if ((active_x >= 12'd1212) && (active_x < 12'd1232)) begin
                status_char_selected = 1'b1;
                status_ascii = display_result_valid ? 8'h4E :
                               (display_result_armed ? 8'h49 : 8'h41); // N / I / A
                status_origin_x = 12'd1212;
                status_color = display_result_valid ? 24'h00FF00 :
                               (display_result_armed ? 24'hFFB000 : 24'hFFFFFF);
            end else if ((active_x >= 12'd1236) && (active_x < 12'd1256)) begin
                status_char_selected = 1'b1;
                status_ascii = display_result_valid ? 8'h45 :
                               (display_result_armed ? 8'h54 : 8'h57); // E / T / W
                status_origin_x = 12'd1236;
                status_color = display_result_valid ? 24'h00FF00 :
                               (display_result_armed ? 24'hFFB000 : 24'hFFFFFF);
            end
        end
    end

    wire [2:0] status_col = status_char_selected ?
                            ((active_x - status_origin_x) >> 2) : 3'd0;
    wire [2:0] status_row = status_text_y ? ((active_y - 12'd16) >> 2) : 3'd0;
    wire [5:0] status_bit_index = (status_row * 6'd5) + status_col;

    // 大字符与两侧状态标识在空间上互斥，先统一生成字符和位索引，后续流水共用字模。
    wire engineering_glyph_selected;
    wire [7:0] engineering_ascii;
    wire [5:0] engineering_bit_index;
    wire [23:0] engineering_color;
    wire engineering_badge_selected;
    engineering_hud u_engineering_hud (
        .raster_active(raster_now), .x(active_x), .y(active_y), .health(display_health),
        .glyph_selected(engineering_glyph_selected), .ascii(engineering_ascii),
        .bit_index(engineering_bit_index), .color(engineering_color),
        .badge_selected(engineering_badge_selected)
    );
    wire [7:0] glyph_ascii = in_result_area ? display_result_ascii :
        engineering_glyph_selected ? engineering_ascii : status_ascii;
    wire [5:0] glyph_bit_index = in_result_area ? result_bit_index :
        engineering_glyph_selected ? engineering_bit_index : status_bit_index;
    wire glyph_area_selected = in_result_area || status_char_selected || engineering_glyph_selected;
    wire badge_area_selected = mode_badge_area || process_badge_area || engineering_badge_selected;

    // M6C把HDMI覆盖层拆成两级内部流水：第一级锁存当前像素的区域、字符和底图，
    // 第二级完成字模译码，最终RGB寄存器只承担位选择与颜色复用。hsync/vsync/de和
    // 底图像素经过完全相同的两拍延迟，因此只增加固定管线延迟，不改变画面坐标关系。
    reg        pipe0_hsync;
    reg        pipe0_vsync;
    reg        pipe0_de;
    reg        pipe0_pixel_empty;
    reg [15:0] pipe0_pixel_data;
    reg        pipe0_glyph_selected;
    reg        pipe0_glyph_is_result;
    reg [7:0]  pipe0_glyph_ascii;
    reg [5:0]  pipe0_glyph_bit_index;
    reg [23:0] pipe0_status_color;
    reg        pipe0_badge_selected;

    reg        pipe1_hsync;
    reg        pipe1_vsync;
    reg        pipe1_de;
    reg        pipe1_pixel_empty;
    reg [15:0] pipe1_pixel_data;
    reg        pipe1_glyph_selected;
    reg        pipe1_glyph_is_result;
    reg [34:0] pipe1_glyph_bitmap;
    reg [5:0]  pipe1_glyph_bit_index;
    reg [23:0] pipe1_status_color;
    reg        pipe1_badge_selected;
    wire pipe1_glyph_pixel = pipe1_glyph_selected &&
                             pipe1_glyph_bitmap[6'd34 - pipe1_glyph_bit_index];

    // FWFT FIFO的Q在非空时已经有效；当前像素被显示的同一拍弹出，下一拍Q更新为后继像素。
    assign pixel_read = active_now && !pixel_empty;

    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            h_count          <= 12'd0;
            v_count          <= 12'd0;
            horizontal_active <= 1'b0;
            vertical_active <= 1'b0;
            frame_ready_sync <= 2'b00;
            stream_active    <= 1'b0;
            work_mode_sync   <= 2'b00;
            result_armed_sync <= 2'b00;
            result_valid_sync <= 2'b00;
            result_ascii_sync0 <= 8'd0;
            result_ascii_sync1 <= 8'd0;
            display_work_mode <= 1'b0;
            display_result_armed <= 1'b0;
            display_result_valid <= 1'b0;
            display_result_ascii <= 8'd0;
            health_request_sync <= 3'b000;
            health_payload_sync0 <= 28'd0;
            health_payload_sync1 <= 28'd0;
            display_health <= 28'h8000000;
            health_ack <= 1'b0;
        end else begin
            frame_ready_sync <= {frame_ready_sync[0], frame_ready};
            work_mode_sync <= {work_mode_sync[0], work_mode_async};
            result_armed_sync <= {result_armed_sync[0], result_armed_async};
            result_valid_sync <= {result_valid_sync[0], result_valid_async};
            result_ascii_sync0 <= result_ascii_async;
            result_ascii_sync1 <= result_ascii_sync0;
            health_request_sync <= {health_request_sync[1:0], health_request_async};
            health_payload_sync0 <= health_payload_async;
            health_payload_sync1 <= health_payload_sync0;

            if ((h_count == 12'd0) && (v_count == 12'd0)) begin
                display_work_mode    <= work_mode_sync[1];
                display_result_armed <= result_armed_sync[1];
                display_result_valid <= result_valid_sync[1];
                display_result_ascii <= result_ascii_sync1;
                // 源数据一直保持到本帧边界应答，翻转位多同步一拍，
                // 两位BCD和全套检查状态一次锁存，禁止跨帧/跨数位撕裂。
                if (health_request_sync[2] != health_ack) begin
                    display_health <= health_payload_sync1;
                    health_ack <= health_request_sync[2];
                end
            end
            if (!stream_active && frame_ready_sync[1] && h_count == 0 && v_count == 0)
                stream_active <= 1'b1;

            // 同一像素时钟内提前译码边界：标志与递增后的计数值对应，
            // 等价于原有效区比较，不给DE/FIFO读使能增加一拍延迟。
            // 异步复位和计数器一起清零，首行/末行、首列/末列均保持原位置。
            if (h_count == H_START - 1'b1)
                horizontal_active <= 1'b1;
            else if (h_count == H_END - 1'b1)
                horizontal_active <= 1'b0;
            if (h_count == H_TOTAL - 1'b1) begin
                if (v_count == V_START - 1'b1)
                    vertical_active <= 1'b1;
                else if (v_count == V_END - 1'b1)
                    vertical_active <= 1'b0;
            end

            if (h_count == H_TOTAL - 1'b1) begin
                h_count <= 12'd0;
                if (v_count == V_TOTAL - 1'b1)
                    v_count <= 12'd0;
                else
                    v_count <= v_count + 1'b1;
            end else begin
                h_count <= h_count + 1'b1;
            end
        end
    end

    // 下溢为粘滞故障；出现后画面缺失位置输出黑色，按复位键清除状态。
    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            underflow <= 1'b0;
            pipe0_hsync <= 1'b0;
            pipe0_vsync <= 1'b0;
            pipe0_de <= 1'b0;
            pipe0_pixel_empty <= 1'b1;
            pipe0_pixel_data <= 16'd0;
            pipe0_glyph_selected <= 1'b0;
            pipe0_glyph_is_result <= 1'b0;
            pipe0_glyph_ascii <= 8'h20;
            pipe0_glyph_bit_index <= 6'd0;
            pipe0_status_color <= 24'hFFFFFF;
            pipe0_badge_selected <= 1'b0;
            pipe1_hsync <= 1'b0;
            pipe1_vsync <= 1'b0;
            pipe1_de <= 1'b0;
            pipe1_pixel_empty <= 1'b1;
            pipe1_pixel_data <= 16'd0;
            pipe1_glyph_selected <= 1'b0;
            pipe1_glyph_is_result <= 1'b0;
            pipe1_glyph_bitmap <= 35'd0;
            pipe1_glyph_bit_index <= 6'd0;
            pipe1_status_color <= 24'hFFFFFF;
            pipe1_badge_selected <= 1'b0;
            hsync     <= 1'b0;
            vsync     <= 1'b0;
            de        <= 1'b0;
            red       <= 8'd0;
            green     <= 8'd0;
            blue      <= 8'd0;
        end else begin
            // 第一级：锁存当前扫描位置对应的所有显示信息，同时保存FIFO当前像素。
            pipe0_hsync <= (h_count < H_SYNC);
            pipe0_vsync <= (v_count < V_SYNC);
            // 摄像头或DDR失败时仍输出黑底诊断页；FIFO取数与下溢判据
            // 继续仅由原active_now控制，不因显示自检而访问空帧缓冲。
            pipe0_de <= raster_now;
            pipe0_pixel_empty <= !stream_active || pixel_empty;
            pipe0_pixel_data <= pixel_data;
            pipe0_glyph_selected <= glyph_area_selected;
            pipe0_glyph_is_result <= in_result_area;
            pipe0_glyph_ascii <= glyph_ascii;
            pipe0_glyph_bit_index <= glyph_bit_index;
            pipe0_status_color <= engineering_glyph_selected ? engineering_color : status_color;
            pipe0_badge_selected <= badge_area_selected;

            // 第二级：字模case只由已锁存ASCII驱动，切断计数器到RGB输出的长组合链。
            pipe1_hsync <= pipe0_hsync;
            pipe1_vsync <= pipe0_vsync;
            pipe1_de <= pipe0_de;
            pipe1_pixel_empty <= pipe0_pixel_empty;
            pipe1_pixel_data <= pipe0_pixel_data;
            pipe1_glyph_selected <= pipe0_glyph_selected;
            pipe1_glyph_is_result <= pipe0_glyph_is_result;
            pipe1_glyph_bitmap <= glyph_5x7(pipe0_glyph_ascii);
            pipe1_glyph_bit_index <= pipe0_glyph_bit_index;
            pipe1_status_color <= pipe0_status_color;
            pipe1_badge_selected <= pipe0_badge_selected;

            hsync <= pipe1_hsync;
            vsync <= pipe1_vsync;
            de    <= pipe1_de;

            if (active_now && pixel_empty)
                underflow <= 1'b1;

            if (pipe1_glyph_pixel) begin
                // 结果字符保持亮绿色；状态文字继续使用原有青色、白色、橙色或绿色。
                {red, green, blue} <= pipe1_glyph_is_result ? 24'h00FF00 : pipe1_status_color;
            end else if (pipe1_badge_selected) begin
                // 深色底块只占顶部两角，提升文字可读性且不遮挡主体书写区域。
                {red, green, blue} <= 24'h102030;
            end else if (pipe1_de && pipe1_pixel_empty) begin
                {red, green, blue} <= 24'h000000;
            end else if (pipe1_de) begin
                // RGB565扩展到RGB888时复制高位，避免简单补零造成最大亮度不足。
                red   <= {pipe1_pixel_data[15:11], pipe1_pixel_data[15:13]};
                green <= {pipe1_pixel_data[10:5],  pipe1_pixel_data[10:9]};
                blue  <= {pipe1_pixel_data[4:0],   pipe1_pixel_data[4:2]};
            end else begin
                {red, green, blue} <= 24'h000000;
            end
        end
    end

endmodule
