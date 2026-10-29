`timescale 1ns / 1ps

// HDMI工程覆盖层仅译码字符/位置，字模仍复用原视频模块的两级流水。
// 左下CAM xx FPS统计输入摄像头VS，不是固定60Hz的HDMI刷新率。
// 开机详情在前10秒展示，任何故障保持展示；所有标志是内部证据，不证明外部屏幕成像。
module engineering_hud (
    input wire raster_active,
    input wire [11:0] x,
    input wire [11:0] y,
    input wire [27:0] health,
    output reg glyph_selected,
    output reg [7:0] ascii,
    output reg [5:0] bit_index,
    output reg [23:0] color,
    output wire badge_selected
);
    wire fps_area = raster_active && x >= 12'd8 && x < 12'd184 &&
        y >= 12'd680 && y < 12'd712;
    wire check_area = raster_active && health[27] &&
        x >= 12'd8 && x < 12'd272 && y >= 12'd64 && y < 12'd224;
    assign badge_selected = fps_area || check_area;
    reg [3:0] slot;
    reg [3:0] line_index;
    reg [2:0] column;
    reg [2:0] row;
    reg [5:0] row_base;
    reg [2:0] check_item;
    wire [7:0] passed = health[18:11];
    wire [7:0] failed = health[26:19];
    reg [127:0] label_text;
    reg pass_bit;
    reg fail_bit;

    always @(*) begin
        glyph_selected = 1'b0;
        ascii = 8'h20;
        color = 24'h00FFFF;
        // 仅在下方字形区域使用这些索引；原点16/72/688均按位对齐。
        // 窄位运算代替12位减法；索引不再经过区域使能门控，减少组合路径。
        slot = x[7:4] - 4'd1;
        column = x[3:1];
        line_index = y[7:4] - (y[3] ? 4'd4 : 4'd5);
        row = y[3:1] ^ (y[9] ? 3'd0 : 3'd4);
        check_item = line_index[2:0] - 3'd1;
        // 固定5列字模的行首用查表，避免常量乘法映射到DSP；区域外索引无效。
        case (row)
            3'd0: row_base = 6'd0;
            3'd1: row_base = 6'd5;
            3'd2: row_base = 6'd10;
            3'd3: row_base = 6'd15;
            3'd4: row_base = 6'd20;
            3'd5: row_base = 6'd25;
            3'd6: row_base = 6'd30;
            default: row_base = 6'd35;
        endcase
        bit_index = row_base + {3'd0, column};
        label_text = 128'd0;
        pass_bit = 1'b0;
        fail_bit = 1'b0;
        if (fps_area && x >= 12'd16 && y >= 12'd688 && y < 12'd702) begin
            case (slot)
                4'd0: ascii = "C";
                4'd1: ascii = "A";
                4'd2: ascii = "M";
                4'd4: ascii = health[8] ? (8'h30 + {4'd0, health[7:4]}) : "-";
                4'd5: ascii = health[8] ? (8'h30 + {4'd0, health[3:0]}) : "-";
                4'd7: ascii = "F";
                4'd8: ascii = "P";
                4'd9: ascii = "S";
                default: ascii = " ";
            endcase
            glyph_selected = column < 3'd5 && slot < 4'd10;
        end else if (check_area && x >= 12'd16 && y >= 12'd72 && y < 12'd216) begin
            if (line_index == 4'd0) begin
                label_text = health[10:9] == 2'd2 ? "SELF TEST: FAIL " :
                    health[10:9] == 2'd1 ? "SELF TEST: OK   " : "SELF TEST: CHECK";
                color = health[10:9] == 2'd2 ? 24'hFF4040 :
                    health[10:9] == 2'd1 ? 24'h00FF00 : 24'hFFB000;
            end else begin
                case (line_index)
                    4'd1: label_text = "CLOCK           ";
                    4'd2: label_text = "DDR CAL         ";
                    4'd3: label_text = "DDR RAM         ";
                    4'd4: label_text = "CAM INIT        ";
                    4'd5: label_text = "CAM VIDEO       ";
                    4'd6: label_text = "HDMI INT        ";
                    4'd7: label_text = "OLED ACK        ";
                    default: label_text = "UART            ";
                endcase
                pass_bit = passed[check_item];
                fail_bit = failed[check_item];
                label_text[47:0] = fail_bit ? "FAIL  " : pass_bit ? "OK    " : "WAIT  ";
                color = fail_bit ? 24'hFF4040 : pass_bit ? 24'h00FF00 : 24'hFFB000;
            end
            // 16字节从高位到低位显示：~slot恰好是4位的15-slot。
            // 7位字节起点直接选择8位，避免128位移位和隐式32位算术。
            ascii = label_text[{~slot, 3'b000} +: 8];
            // slot已经由4位和区域边界限制为0~15；不能写4'd16，
            // 否则常量会截断成0，导致整张自检页没有文字。
            glyph_selected = column < 3'd5 && row < 3'd7;
        end
    end
endmodule
