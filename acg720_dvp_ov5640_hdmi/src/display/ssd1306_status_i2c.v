`timescale 1ns / 1ps

// 128x64 SSD1306状态屏。全部逻辑留在板载50 MHz域，约100 kHz I²C
// 独立刷新；只读模式和结果接收状态，不向摄像头、HDMI或UART提供反压。
// 发送时序复用已上板跑通的电子琴例程：SCL主动输出、SDA开漏，
// 每个命令或显示数据字节使用独立的START/地址/控制/负载/STOP事务。
module ssd1306_status_i2c (
    input  wire clk,
    input  wire reset_n,
    input  wire hand_mode,
    input  wire result_armed,
    input  wire result_valid,
    input  wire [1:0] boot_state,
    input  wire [7:0] check_pass,
    input  wire [7:0] check_fail,
    output reg initialized,
    output wire ack_seen,
    output wire ack_error,
    inout  wire oled_sda,
    output wire oled_scl
);

    // SSD1306使用7位地址0x3C，写方向的总线地址字节为0x78。
    // 0x00表示后续为命令，0x40表示后续为显示数据。
    function [7:0] init_command;
        input [4:0] index;
        begin
            case (index)
                5'd0:  init_command = 8'hAE;
                5'd1:  init_command = 8'hD5;
                5'd2:  init_command = 8'h80;
                5'd3:  init_command = 8'hA8;
                5'd4:  init_command = 8'h3F;
                5'd5:  init_command = 8'hD3;
                5'd6:  init_command = 8'h00;
                5'd7:  init_command = 8'h40;
                5'd8:  init_command = 8'h8D;
                5'd9:  init_command = 8'h14;
                5'd10: init_command = 8'h20;
                5'd11: init_command = 8'h00; // 与已跑通例程一致，使用水平寻址
                // 棱镜成像保留上下反向，再将整屏左右镜像；文字与猫图一起翻转。
                5'd12: init_command = 8'hA1;
                5'd13: init_command = 8'hC0;
                5'd14: init_command = 8'hDA;
                5'd15: init_command = 8'h12;
                5'd16: init_command = 8'h81;
                5'd17: init_command = 8'hCF;
                5'd18: init_command = 8'hD9;
                5'd19: init_command = 8'hF1;
                5'd20: init_command = 8'hDB;
                5'd21: init_command = 8'h40;
                5'd22: init_command = 8'hA4;
                5'd23: init_command = 8'hA6;
                default: init_command = 8'hAF;
            endcase
        end
    endfunction

    // BMP.h中的rainbow_cat共6帧，每帧128x64。保留含猫与彩虹主体的
    // 原图第2～5页(Y16～47)，1:1显示在OLED第4～7页；上下星点略去。
    // 字节按帧/页/列顺序存于工程内的相对路径文件。
    // 同步读专用ROM只增加OLED发字节前的一拍，不改I²C发送节拍。
    reg [7:0] cat_rom [0:3071] /* synthesis syn_romstyle = "block_rom" */;
    initial $readmemh("src/display/rainbow_cat_128x32.mem", cat_rom);
    reg [7:0] cat_byte;
    reg [2:0] cat_frame;
    // 有效回传从0变1只触发一次：锁存到接下来6轮整屏刷新，
    // 页面3显示MEOW并加快原猫帧切换。重复回传保持valid，不重复触发。
    reg result_valid_d;
    reg [2:0] reaction_remaining;
    reg reaction_snapshot;
    // 开机8项各占一页，一屏展示全部检查；至少完成10轮整屏刷新，
    // 且最后一屏已显示OK/FAIL终态后返回正常页。UART WAIT不阻塞退出。
    // 页面选择与检查结果一起锁存，写屏途中不混入猫图或正常状态。
    reg startup_page;
    reg startup_snapshot;
    reg [3:0] startup_screen_count;
    reg [1:0] boot_snapshot;
    reg [7:0] check_pass_snapshot;
    reg [7:0] check_fail_snapshot;
    wire reaction_event = result_valid && !result_valid_d;

    // 水平寻址覆盖完整128列、8页，与已跑通例程的初始化后写屏顺序一致。
    function [7:0] address_command;
        input [2:0] index;
        begin
            case (index)
                3'd0: address_command = 8'h21;
                3'd1: address_command = 8'h00;
                3'd2: address_command = 8'h7F;
                3'd3: address_command = 8'h22;
                3'd4: address_command = 8'h00;
                default: address_command = 8'h07;
            endcase
        end
    endfunction

    // 与已验收的HDMI状态栏使用同一DRAW/WAIT/DONE语义。
    // 每字符8列，其中5列字形、3列留白；彩虹猫由下方4页ROM覆盖。
    function [7:0] status_char;
        input [2:0] page;
        input [3:0] slot;
        input mode;
        input armed;
        input valid;
        input startup;
        input [7:0] passed;
        input [7:0] failed;
        input reaction;
        reg [127:0] diagnostic_text;
        begin
            status_char = 8'h20;
            if (startup) begin
                case (page)
                    3'd0: diagnostic_text = "CLOCK           ";
                    3'd1: diagnostic_text = "DDR CAL         ";
                    3'd2: diagnostic_text = "DDR RAM         ";
                    3'd3: diagnostic_text = "CAM INIT        ";
                    3'd4: diagnostic_text = "CAM VIDEO       ";
                    3'd5: diagnostic_text = "HDMI INT        ";
                    3'd6: diagnostic_text = "OLED ACK        ";
                    default: diagnostic_text = "UART            ";
                endcase
                diagnostic_text[47:0] = failed[page] ? "FAIL  " : passed[page] ? "OK    " : "WAIT  ";
                status_char = diagnostic_text >> ((15-slot) * 8);
            end else if (page == 3'd0) begin
                case (slot)
                    4'd0: status_char = "M";
                    4'd1: status_char = "O";
                    4'd2: status_char = "D";
                    4'd3: status_char = "E";
                    4'd4: status_char = ":";
                    4'd6: status_char = mode ? "H" : "P";
                    4'd7: status_char = mode ? "A" : "E";
                    4'd8: status_char = "N";
                    4'd9: if (mode) status_char = "D";
                    default: status_char = 8'h20;
                endcase
            end else if (page == 3'd2) begin
                case (slot)
                    4'd0: status_char = "S";
                    4'd1: status_char = "T";
                    4'd2: status_char = "A";
                    4'd3: status_char = "T";
                    4'd4: status_char = "E";
                    4'd5: status_char = ":";
                    4'd7: status_char = valid ? "D" : armed ? "W" : "D";
                    4'd8: status_char = valid ? "O" : armed ? "A" : "R";
                    4'd9: status_char = valid ? "N" : armed ? "I" : "A";
                    4'd10: status_char = valid ? "E" : armed ? "T" : "W";
                    default: status_char = 8'h20;
                endcase
            end else if (page == 3'd3 && reaction) begin
                diagnostic_text = "MEOW!           ";
                status_char = diagnostic_text >> ((15-slot) * 8);
            end
        end
    endfunction

    function [34:0] glyph_5x7;
        input [7:0] ch;
        begin
            case (ch)
                "A": glyph_5x7 = {5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "B": glyph_5x7 = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
                "C": glyph_5x7 = {5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
                "F": glyph_5x7 = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
                "K": glyph_5x7 = {5'b10001,5'b10010,5'b10100,5'b11000,5'b10100,5'b10010,5'b10001};
                "L": glyph_5x7 = {5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
                "V": glyph_5x7 = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100};
                "U": glyph_5x7 = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "!": glyph_5x7 = {5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00000,5'b00100};
                "D": glyph_5x7 = {5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
                "E": glyph_5x7 = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
                "H": glyph_5x7 = {5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "I": glyph_5x7 = {5'b01110,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                "M": glyph_5x7 = {5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
                "N": glyph_5x7 = {5'b10001,5'b11001,5'b10101,5'b10011,5'b10001,5'b10001,5'b10001};
                "O": glyph_5x7 = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "P": glyph_5x7 = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
                "R": glyph_5x7 = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
                "S": glyph_5x7 = {5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
                "T": glyph_5x7 = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
                "W": glyph_5x7 = {5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010};
                ":": glyph_5x7 = {5'b00000,5'b00100,5'b00100,5'b00000,5'b00100,5'b00100,5'b00000};
                default: glyph_5x7 = 35'd0;
            endcase
        end
    endfunction

    function [7:0] page_byte;
        input [2:0] page;
        input [6:0] column;
        input mode;
        input armed;
        input valid;
        input startup;
        input [7:0] passed;
        input [7:0] failed;
        input reaction;
        reg [34:0] glyph;
        integer row;
        begin
            page_byte = 8'd0;
            if (column[2:0] < 3'd5) begin
                glyph = glyph_5x7(status_char(page, column[6:3], mode, armed, valid,
                    startup, passed, failed, reaction));
                for (row = 0; row < 7; row = row + 1)
                    page_byte[row] = glyph[34 - row * 5 - column[2:0]];
            end
        end
    endfunction

    // 已跑通的底层发送器每次完成一条命令或数据事务。SCL为推挽输出，
    // SDA只下拉或释放，ACK时隙交给OLED应答；发送完成脉冲推进上层状态。
    reg       tx_start;
    reg       tx_is_data;
    reg [7:0] tx_data;
    wire      tx_busy;
    wire      tx_done;
    oled_i2c_tx u_oled_i2c_tx (
        .clk(clk),
        .rst_n(reset_n),
        .start(tx_start),
        .is_data(tx_is_data),
        .data_byte(tx_data),
        .busy(tx_busy),
        .done(tx_done),
        .ack_seen(ack_seen),
        .ack_error(ack_error),
        .scl(oled_scl),
        .sda(oled_sda)
    );

    localparam [3:0] Q_POWER     = 4'd0,
                     Q_INIT_PREP = 4'd1,
                     Q_INIT_WAIT = 4'd2,
                     Q_ADDR_PREP = 4'd3,
                     Q_ADDR_WAIT = 4'd4,
                     Q_DATA_PREP = 4'd5,
                     Q_DATA_SEND = 4'd6,
                     Q_DATA_WAIT = 4'd7,
                     Q_PAUSE     = 4'd8;
    reg [3:0]  queue_state;
    reg [4:0]  init_index;
    reg [2:0]  addr_index;
    reg [9:0]  pixel_index;
    wire [11:0] cat_addr = {cat_frame, pixel_index[8:0]};
    reg [23:0] delay_count;
    reg        mode_snapshot;
    reg        armed_snapshot;
    reg        valid_snapshot;

    // 只在整屏边界消费反应计数，避免猫图写到一半换帧；与I²C队列分开，
    // 即使回传发生在一轮刷新中途，也会保留到下一次完整显示。
    // 开机检查页不显示互动、不扣次数，待恢复正常页后再播放。
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            result_valid_d <= 1'b0;
            reaction_remaining <= 3'd0;
        end else begin
            result_valid_d <= result_valid;
            if (reaction_event) reaction_remaining <= 3'd6;
            else if (queue_state == Q_DATA_WAIT && tx_done &&
                     pixel_index == 10'd1023 && reaction_snapshot && reaction_remaining != 0)
                reaction_remaining <= reaction_remaining - 1'b1;
        end
    end

    // 复位后等待100 ms再初始化；初始化命令与完整屏幕寻址完全沿用
    // 电子琴例程。每轮发送1024字节后切换猫动画帧、暂停200 ms，
    // 再锁存状态并重画全屏。M7B回传反应阶段缩短暂停到40ms，
    // 但完整1024字节仍按原速发送，实际动画频率受I²C传输时间限制。
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            queue_state    <= Q_POWER;
            init_index     <= 5'd0;
            addr_index     <= 3'd0;
            pixel_index    <= 10'd0;
            delay_count    <= 24'd0;
            mode_snapshot  <= 1'b0;
            armed_snapshot <= 1'b0;
            valid_snapshot <= 1'b0;
            initialized    <= 1'b0;
            reaction_snapshot <= 1'b0;
            startup_page <= 1'b1;
            startup_snapshot <= 1'b1;
            startup_screen_count <= 4'd0;
            boot_snapshot <= 2'd0;
            check_pass_snapshot <= 8'd0;
            check_fail_snapshot <= 8'd0;
            cat_frame      <= 3'd0;
            cat_byte       <= 8'd0;
            tx_start       <= 1'b0;
            tx_is_data     <= 1'b0;
            tx_data        <= 8'h00;
        end else begin
            tx_start <= 1'b0;
            case (queue_state)
                Q_POWER: begin
                    if (delay_count == 24'd4_999_999) begin
                        delay_count <= 24'd0;
                        queue_state <= Q_INIT_PREP;
                    end else delay_count <= delay_count + 1'b1;
                end
                Q_INIT_PREP: if (!tx_busy) begin
                    tx_is_data <= 1'b0;
                    tx_data <= init_command(init_index);
                    tx_start <= 1'b1;
                    queue_state <= Q_INIT_WAIT;
                end
                Q_INIT_WAIT: if (tx_done) begin
                    if (init_index == 5'd24) begin
                        initialized <= 1'b1;
                        mode_snapshot  <= hand_mode;
                        armed_snapshot <= result_armed;
                        valid_snapshot <= result_valid;
                        boot_snapshot <= boot_state;
                        check_pass_snapshot <= check_pass;
                        check_fail_snapshot <= check_fail;
                        startup_snapshot <= startup_page;
                        reaction_snapshot <= !startup_page && (reaction_remaining != 0 || reaction_event);
                        addr_index <= 3'd0;
                        queue_state <= Q_ADDR_PREP;
                    end else begin
                        init_index <= init_index + 1'b1;
                        queue_state <= Q_INIT_PREP;
                    end
                end
                Q_ADDR_PREP: if (!tx_busy) begin
                    tx_is_data <= 1'b0;
                    tx_data <= address_command(addr_index);
                    tx_start <= 1'b1;
                    queue_state <= Q_ADDR_WAIT;
                end
                Q_ADDR_WAIT: if (tx_done) begin
                    if (addr_index == 3'd5) begin
                        pixel_index <= 10'd0;
                        queue_state <= Q_DATA_PREP;
                    end else begin
                        addr_index <= addr_index + 1'b1;
                        queue_state <= Q_ADDR_PREP;
                    end
                end
                Q_DATA_PREP: if (!tx_busy) begin
                    cat_byte <= cat_rom[cat_addr];
                    queue_state <= Q_DATA_SEND;
                end
                Q_DATA_SEND: begin
                    tx_is_data <= 1'b1;
                    // 启动时8页全为诊断字模，正常时下4页恢复原猫ROM。
                    tx_data <= !startup_snapshot && pixel_index[9] ? cat_byte :
                               page_byte(pixel_index[9:7], pixel_index[6:0],
                                         mode_snapshot, armed_snapshot, valid_snapshot,
                                         startup_snapshot,
                                         check_pass_snapshot, check_fail_snapshot, reaction_snapshot);
                    tx_start <= 1'b1;
                    queue_state <= Q_DATA_WAIT;
                end
                Q_DATA_WAIT: if (tx_done) begin
                    if (pixel_index == 10'd1023) begin
                        // 回传互动时0/2/4三帧加速循环，结束后恢复原6帧动画。
                        cat_frame <= reaction_snapshot ?
                            (cat_frame >= 3'd4 ? 3'd0 : cat_frame + 3'd2) :
                            (cat_frame == 3'd5 ? 3'd0 : cat_frame + 1'b1);
                        // 只在整屏写完后退出；计数饱和，等待监测终态时不回绕。
                        // FAIL也返回正常页，故障详情继续由原HDMI诊断保持。
                        if (startup_snapshot) begin
                            if (startup_screen_count < 4'd9)
                                startup_screen_count <= startup_screen_count + 1'b1;
                            if (startup_screen_count >= 4'd9 && boot_snapshot != 2'd0)
                                startup_page <= 1'b0;
                        end
                        delay_count <= 24'd0;
                        queue_state <= Q_PAUSE;
                    end else begin
                        pixel_index <= pixel_index + 1'b1;
                        queue_state <= Q_DATA_PREP;
                    end
                end
                Q_PAUSE: begin
                    if (delay_count >= (!startup_page && reaction_remaining != 0 ? 24'd1_999_999 : 24'd9_999_999)) begin
                        delay_count <= 24'd0;
                        addr_index <= 3'd0;
                        mode_snapshot  <= hand_mode;
                        armed_snapshot <= result_armed;
                        valid_snapshot <= result_valid;
                        boot_snapshot <= boot_state;
                        check_pass_snapshot <= check_pass;
                        check_fail_snapshot <= check_fail;
                        startup_snapshot <= startup_page;
                        reaction_snapshot <= !startup_page && (reaction_remaining != 0 || reaction_event);
                        queue_state <= Q_ADDR_PREP;
                    end else delay_count <= delay_count + 1'b1;
                end
                default: queue_state <= Q_POWER;
            endcase
        end
    end
endmodule
