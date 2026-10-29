`timescale 1ns / 1ps

// 720p60/74.25MHz专用HDMI辅助数据：只在原视频消隐区插入一个32像素包。
// 数据岛：64..71前导、72..73保护、74..105包、106..107尾保护；
// 有效行视频：250..257前导、258..259保护、260起原视频。视频编码不改。
// 基于原输入HS/VS重新对齐扫描位置；控制/TERC4与原视频共用3拍编码延迟。
// 协议按HDMI 1.3第5/7/8章核对；48kHz双声道16位PCM，N=6144/CTS=74250。
module hdmi_audio_island (
    input wire pixel_clk,
    input wire reset_n,
    input wire hsync,
    input wire vsync,
    input wire de,
    input wire sample_valid,
    input wire [15:0] sample_data,
    output reg auxiliary_selected,
    output reg [9:0] auxiliary_blue,
    output reg [9:0] auxiliary_green,
    output reg [9:0] auxiliary_red,
    output reg fifo_overflow
);
    reg hsync_d;
    reg vsync_d;
    reg scan_locked;
    reg [11:0] line_cycle;
    reg [9:0] line_number;
    wire hsync_rise = hsync && !hsync_d;
    wire vsync_rise = vsync && !vsync_d;
    // 输入的视频本来经过覆盖层流水，锁在其HS上而非另起未对齐的计数器。
    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            hsync_d <= 1'b0;
            vsync_d <= 1'b0;
            scan_locked <= 1'b0;
            line_cycle <= 12'd0;
            line_number <= 10'd0;
        end else begin
            hsync_d <= hsync;
            vsync_d <= vsync;
            if (hsync_rise) begin
                scan_locked <= 1'b1;
                line_cycle <= 12'd1;
            end else if (line_cycle == 12'd1649) line_cycle <= 12'd0;
            else line_cycle <= line_cycle + 1'b1;
            if (vsync_rise) line_number <= 10'd0;
            // 行尾回卷时同步推进行号，避免HS上升沿被下一拍采到时行号晚一像素。
            else if (scan_locked && line_cycle == 12'd1649)
                line_number <= line_number == 10'd749 ? 10'd0 : line_number + 1'b1;
        end
    end

    reg [15:0] sample_fifo [0:15];
    reg [3:0] write_pointer;
    reg [3:0] read_pointer;
    reg [4:0] fifo_count;
    reg [7:0] frame_counter;
    reg avi_pending;
    reg info_pending;
    reg [5:0] acr_lines;
    wire choose_packet = scan_locked && line_cycle == 12'd48;
    wire choose_acr = choose_packet && acr_lines >= 6'd44;
    wire choose_avi = choose_packet && !choose_acr && avi_pending;
    wire choose_info = choose_packet && !choose_acr && !avi_pending && info_pending;
    wire pop_four = choose_packet && !choose_acr && !avi_pending && !info_pending && fifo_count >= 5'd4;
    wire push_one = sample_valid && (fifo_count < 5'd16 || pop_four);
    wire [3:0] read_one = read_pointer + 4'd1;
    wire [3:0] read_two = read_pointer + 4'd2;
    wire [3:0] read_three = read_pointer + 4'd3;
    // 四帧样本一起发送；帧号0..191携带IEC60958状态/起块位。
    // 16点环形缓冲留出元数据连续占线的余量，不靠独立音频时钟CDC。
    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            write_pointer <= 4'd0;
            read_pointer <= 4'd0;
            fifo_count <= 5'd0;
            frame_counter <= 8'd0;
            fifo_overflow <= 1'b0;
            avi_pending <= 1'b1;
            info_pending <= 1'b1;
            acr_lines <= 6'd44;
        end else begin
            if (push_one) begin
                sample_fifo[write_pointer] <= sample_data;
                write_pointer <= write_pointer + 1'b1;
            end
            if (sample_valid && !push_one) fifo_overflow <= 1'b1;
            if (pop_four) begin
                read_pointer <= read_pointer + 4'd4;
                frame_counter <= frame_counter == 8'd188 ? 8'd0 : frame_counter + 8'd4;
            end
            case ({push_one, pop_four})
                2'b10: fifo_count <= fifo_count + 1'b1;
                2'b01: fifo_count <= fifo_count - 5'd4;
                2'b11: fifo_count <= fifo_count - 5'd3;
                default: fifo_count <= fifo_count;
            endcase
            if (hsync_rise && acr_lines < 6'd44) acr_lines <= acr_lines + 1'b1;
            if (choose_acr) acr_lines <= 6'd0;
            if (choose_avi) avi_pending <= 1'b0;
            if (choose_info) info_pending <= 1'b0;
            if (vsync_rise) begin
                avi_pending <= 1'b1;
                info_pending <= 1'b1;
            end
        end
    end

    function [55:0] audio_subpacket;
        input [15:0] sample;
        input [7:0] frame;
        reg c_left;
        reg c_right;
        reg p_left;
        reg p_right;
        begin
            // 消费级LPCM/无强调/允许复制；左1右2，48kHz，16位字长。
            // 24位样本高16位有效、低8位补0，VU=0；P使每声道偶校验。
            c_left = frame == 8'd2 || frame == 8'd20 || frame == 8'd25 || frame == 8'd33;
            c_right = frame == 8'd2 || frame == 8'd21 || frame == 8'd25 || frame == 8'd33;
            p_left = (^sample) ^ c_left;
            p_right = (^sample) ^ c_right;
            audio_subpacket = {p_right, c_right, 2'b00, p_left, c_left, 2'b00,
                               sample, 8'd0, sample, 8'd0};
        end
    endfunction
    reg [23:0] packet_header;
    reg [55:0] packet_sub0;
    reg [55:0] packet_sub1;
    reg [55:0] packet_sub2;
    reg [55:0] packet_sub3;
    // h=48装载快照；在前导/包期间绝不改动，随后逐拍生成BCH而非大组合循环。
    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            packet_header <= 24'd0;
            packet_sub0 <= 56'd0;
            packet_sub1 <= 56'd0;
            packet_sub2 <= 56'd0;
            packet_sub3 <= 56'd0;
        end else if (choose_packet) begin
            packet_header <= 24'd0;
            packet_sub0 <= 56'd0;
            packet_sub1 <= 56'd0;
            packet_sub2 <= 56'd0;
            packet_sub3 <= 56'd0;
            if (choose_acr) begin
                packet_header <= 24'h000001;
                // SB0保留0，SB1..3大端CTS，SB4..6大端N；各子包相同。
                packet_sub0 <= 56'h0018000A220100;
                packet_sub1 <= 56'h0018000A220100;
                packet_sub2 <= 56'h0018000A220100;
                packet_sub3 <= 56'h0018000A220100;
            end else if (choose_avi) begin
                packet_header <= 24'h0D0282;
                // RGB全范围/16:9/VIC4(720p60)，PB0=0x3B校验，其他字节0。
                packet_sub0 <= 56'h0000040828003B;
            end else if (choose_info) begin
                packet_header <= 24'h0A0184;
                // 双声道(通道数减一=1)，采样/位宽由音频流头说明，PB0=0x70。
                packet_sub0 <= 56'h00000000000170;
            end else if (pop_four) begin
                packet_header <= frame_counter == 8'd0 ? 24'h100F02 : 24'h000F02;
                packet_sub0 <= audio_subpacket(sample_fifo[read_pointer], frame_counter);
                packet_sub1 <= audio_subpacket(sample_fifo[read_one], frame_counter + 8'd1);
                packet_sub2 <= audio_subpacket(sample_fifo[read_two], frame_counter + 8'd2);
                packet_sub3 <= audio_subpacket(sample_fifo[read_three], frame_counter + 8'd3);
            end
        end
    end

    wire island_body = scan_locked && line_cycle >= 12'd74 && line_cycle < 12'd106;
    wire [4:0] packet_index = line_cycle[4:0] - 5'd10;
    wire [5:0] even_bit = {packet_index, 1'b0};
    wire [5:0] odd_bit = {packet_index, 1'b1};
    reg [7:0] ecc_header;
    reg [7:0] ecc0;
    reg [7:0] ecc1;
    reg [7:0] ecc2;
    reg [7:0] ecc3;
    function [7:0] ecc_step;
        input [7:0] state;
        input data_bit;
        begin
            // HDMI BCH生成多项式的LSB先行形式，数据24/56位后发送8位校验。
            ecc_step = {1'b0, state[7:1]} ^ ((state[0] ^ data_bit) ? 8'h83 : 8'd0);
        end
    endfunction
    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            ecc_header <= 8'd0; ecc0 <= 8'd0; ecc1 <= 8'd0; ecc2 <= 8'd0; ecc3 <= 8'd0;
        end else if (!island_body) begin
            ecc_header <= 8'd0; ecc0 <= 8'd0; ecc1 <= 8'd0; ecc2 <= 8'd0; ecc3 <= 8'd0;
        end else begin
            if (packet_index < 5'd24) ecc_header <= ecc_step(ecc_header, packet_header[packet_index]);
            if (packet_index < 5'd28) begin
                ecc0 <= ecc_step(ecc_step(ecc0, packet_sub0[even_bit]), packet_sub0[odd_bit]);
                ecc1 <= ecc_step(ecc_step(ecc1, packet_sub1[even_bit]), packet_sub1[odd_bit]);
                ecc2 <= ecc_step(ecc_step(ecc2, packet_sub2[even_bit]), packet_sub2[odd_bit]);
                ecc3 <= ecc_step(ecc_step(ecc3, packet_sub3[even_bit]), packet_sub3[odd_bit]);
            end
        end
    end
    wire [31:0] bch_header = {ecc_header, packet_header};
    wire [63:0] bch0 = {ecc0, packet_sub0};
    wire [63:0] bch1 = {ecc1, packet_sub1};
    wire [63:0] bch2 = {ecc2, packet_sub2};
    wire [63:0] bch3 = {ecc3, packet_sub3};
    function [9:0] terc4;
        input [3:0] value;
        begin
            case (value)
                4'h0: terc4 = 10'b1010011100;
                4'h1: terc4 = 10'b1001100011;
                4'h2: terc4 = 10'b1011100100;
                4'h3: terc4 = 10'b1011100010;
                4'h4: terc4 = 10'b0101110001;
                4'h5: terc4 = 10'b0100011110;
                4'h6: terc4 = 10'b0110001110;
                4'h7: terc4 = 10'b0100111100;
                4'h8: terc4 = 10'b1011001100;
                4'h9: terc4 = 10'b0100111001;
                4'hA: terc4 = 10'b0110011100;
                4'hB: terc4 = 10'b1011000110;
                4'hC: terc4 = 10'b1010001110;
                4'hD: terc4 = 10'b1001110001;
                4'hE: terc4 = 10'b0101100011;
                default: terc4 = 10'b1011000011;
            endcase
        end
    endfunction
    function [9:0] control_code;
        input [1:0] value;
        begin
            case (value)
                2'b00: control_code = 10'b1101010100;
                2'b01: control_code = 10'b0010101011;
                2'b10: control_code = 10'b0101010100;
                default: control_code = 10'b1010101011;
            endcase
        end
    endfunction
    wire active_line = line_number >= 10'd25 && line_number < 10'd745;
    always @(*) begin
        auxiliary_selected = 1'b0;
        auxiliary_blue = control_code({vsync, hsync});
        auxiliary_green = control_code(2'b00);
        auxiliary_red = control_code(2'b00);
        // DE有绝对优先级；辅助插入仅允许消隐，保持原有效像素/时钟/分辨率。
        if (scan_locked && !de) begin
            if (line_cycle >= 12'd64 && line_cycle < 12'd72) begin
                auxiliary_selected = 1'b1;
                auxiliary_green = control_code(2'b01);
                auxiliary_red = control_code(2'b01);
            end else if ((line_cycle >= 12'd72 && line_cycle < 12'd74) ||
                         (line_cycle >= 12'd106 && line_cycle < 12'd108)) begin
                auxiliary_selected = 1'b1;
                auxiliary_blue = terc4({2'b11, vsync, hsync});
                auxiliary_green = 10'b0100110011;
                auxiliary_red = 10'b0100110011;
            end else if (island_body) begin
                auxiliary_selected = 1'b1;
                auxiliary_blue = terc4({1'b1, bch_header[packet_index], vsync, hsync});
                // 四子包的偶数位进通道1，奇数位进通道2；都按子包0先行。
                auxiliary_green = terc4({bch3[even_bit], bch2[even_bit], bch1[even_bit], bch0[even_bit]});
                auxiliary_red = terc4({bch3[odd_bit], bch2[odd_bit], bch1[odd_bit], bch0[odd_bit]});
            end else if (active_line && line_cycle >= 12'd250 && line_cycle < 12'd258) begin
                auxiliary_selected = 1'b1;
                auxiliary_green = control_code(2'b01);
            end else if (active_line && line_cycle >= 12'd258 && line_cycle < 12'd260) begin
                auxiliary_selected = 1'b1;
                auxiliary_blue = 10'b1011001100;
                auxiliary_green = 10'b0100110011;
                auxiliary_red = 10'b1011001100;
            end
        end
    end
endmodule
