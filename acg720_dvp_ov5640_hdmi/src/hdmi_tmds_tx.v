`timescale 1ns / 1ps

// HDMI视频+音频发送器：原三路视频TMDS编码/OSER10串化保持不变。
// 只在消隐区覆盖辅助码，辅助码同步延迟3拍，与原编码输出同像素对齐。
module hdmi_tmds_tx (
    input  wire       pixel_clk,
    input  wire       serial_clk,
    input  wire       reset_n,
    input  wire [7:0] red,
    input  wire [7:0] green,
    input  wire [7:0] blue,
    input  wire       hsync,
    input  wire       vsync,
    input  wire       de,
    input  wire       audio_sample_valid,
    input  wire [15:0] audio_sample_data,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_data_p,
    output wire [2:0] tmds_data_n
);

    wire [9:0] code_red;
    wire [9:0] code_green;
    wire [9:0] code_blue;

    wire auxiliary_selected;
    wire [9:0] auxiliary_blue;
    wire [9:0] auxiliary_green;
    wire [9:0] auxiliary_red;
    wire audio_fifo_overflow;
    hdmi_audio_island u_hdmi_audio_island (
        .pixel_clk(pixel_clk), .reset_n(reset_n),
        .hsync(hsync), .vsync(vsync), .de(de),
        .sample_valid(audio_sample_valid), .sample_data(audio_sample_data),
        .auxiliary_selected(auxiliary_selected), .auxiliary_blue(auxiliary_blue),
        .auxiliary_green(auxiliary_green), .auxiliary_red(auxiliary_red),
        .fifo_overflow(audio_fifo_overflow)
    );
    reg [2:0] auxiliary_select_pipe;
    reg [29:0] auxiliary_code0;
    reg [29:0] auxiliary_code1;
    reg [29:0] auxiliary_code2;
    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            auxiliary_select_pipe <= 3'b000;
            auxiliary_code0 <= 30'd0;
            auxiliary_code1 <= 30'd0;
            auxiliary_code2 <= 30'd0;
        end else begin
            auxiliary_select_pipe <= {auxiliary_select_pipe[1:0], auxiliary_selected};
            auxiliary_code0 <= {auxiliary_red, auxiliary_green, auxiliary_blue};
            auxiliary_code1 <= auxiliary_code0;
            auxiliary_code2 <= auxiliary_code1;
        end
    end
    wire [29:0] transmitted_code = auxiliary_select_pipe[2] ? auxiliary_code2 :
                                  {code_red, code_green, code_blue};

    tmds_encode u_encode_blue (
        .clk(pixel_clk), .reset_n(reset_n), .data(blue),
        .control0(hsync), .control1(vsync), .de(de), .code(code_blue)
    );
    tmds_encode u_encode_green (
        .clk(pixel_clk), .reset_n(reset_n), .data(green),
        .control0(1'b0), .control1(1'b0), .de(de), .code(code_green)
    );
    tmds_encode u_encode_red (
        .clk(pixel_clk), .reset_n(reset_n), .data(red),
        .control0(1'b0), .control1(1'b0), .de(de), .code(code_red)
    );

    tmds_serializer_4lane u_serializer (
        .pixel_clk (pixel_clk),
        .serial_clk(serial_clk),
        .reset_n   (reset_n),
        .lane0_code(transmitted_code[9:0]),
        .lane1_code(transmitted_code[19:10]),
        .lane2_code(transmitted_code[29:20]),
        .lane3_code(10'b1111100000),
        .lane_p    ({tmds_clk_p, tmds_data_p[2], tmds_data_p[1], tmds_data_p[0]}),
        .lane_n    ({tmds_clk_n, tmds_data_n[2], tmds_data_n[1], tmds_data_n[0]})
    );

endmodule

// TMDS编码先减少输入数据跳变，再根据累计直流偏差选择极性，保持链路直流平衡。
module tmds_encode (
    input  wire       clk,
    input  wire       reset_n,
    input  wire [7:0] data,
    input  wire       control0,
    input  wire       control1,
    input  wire       de,
    output reg  [9:0] code
);

    localparam [9:0] CONTROL_00 = 10'b1101010100;
    localparam [9:0] CONTROL_01 = 10'b0010101011;
    localparam [9:0] CONTROL_10 = 10'b0101010100;
    localparam [9:0] CONTROL_11 = 10'b1010101011;

    reg [3:0] ones_data;
    reg [7:0] data_d1;
    wire use_xnor = (ones_data > 4'd4) || ((ones_data == 4'd4) && !data_d1[0]);
    wire [8:0] transition_code;
    assign transition_code[0] = data_d1[0];
    assign transition_code[1] = use_xnor ? ~(transition_code[0] ^ data_d1[1]) : (transition_code[0] ^ data_d1[1]);
    assign transition_code[2] = use_xnor ? ~(transition_code[1] ^ data_d1[2]) : (transition_code[1] ^ data_d1[2]);
    assign transition_code[3] = use_xnor ? ~(transition_code[2] ^ data_d1[3]) : (transition_code[2] ^ data_d1[3]);
    assign transition_code[4] = use_xnor ? ~(transition_code[3] ^ data_d1[4]) : (transition_code[3] ^ data_d1[4]);
    assign transition_code[5] = use_xnor ? ~(transition_code[4] ^ data_d1[5]) : (transition_code[4] ^ data_d1[5]);
    assign transition_code[6] = use_xnor ? ~(transition_code[5] ^ data_d1[6]) : (transition_code[5] ^ data_d1[6]);
    assign transition_code[7] = use_xnor ? ~(transition_code[6] ^ data_d1[7]) : (transition_code[6] ^ data_d1[7]);
    assign transition_code[8] = ~use_xnor;

    reg [3:0] ones_transition;
    reg [3:0] zeros_transition;
    reg [1:0] de_pipe;
    reg [1:0] control0_pipe;
    reg [1:0] control1_pipe;
    reg [8:0] transition_d1;
    reg [4:0] disparity;
    wire balanced = (disparity == 0) || (ones_transition == zeros_transition);
    wire invert_for_balance = (!disparity[4] && (ones_transition > zeros_transition)) ||
                              ( disparity[4] && (zeros_transition > ones_transition));

    always @(posedge clk) begin
        data_d1  <= data;
        ones_data <= data[0] + data[1] + data[2] + data[3] +
                     data[4] + data[5] + data[6] + data[7];
        ones_transition  <= transition_code[0] + transition_code[1] + transition_code[2] + transition_code[3] +
                            transition_code[4] + transition_code[5] + transition_code[6] + transition_code[7];
        zeros_transition <= 4'd8 - (transition_code[0] + transition_code[1] + transition_code[2] + transition_code[3] +
                                    transition_code[4] + transition_code[5] + transition_code[6] + transition_code[7]);
        de_pipe       <= {de_pipe[0], de};
        control0_pipe <= {control0_pipe[0], control0};
        control1_pipe <= {control1_pipe[0], control1};
        transition_d1 <= transition_code;
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            code      <= 10'd0;
            disparity <= 5'd0;
        end else if (de_pipe[1]) begin
            if (balanced) begin
                code[9]   <= ~transition_d1[8];
                code[8]   <= transition_d1[8];
                code[7:0] <= transition_d1[8] ? transition_d1[7:0] : ~transition_d1[7:0];
                disparity <= transition_d1[8]
                           ? disparity + ones_transition - zeros_transition
                           : disparity + zeros_transition - ones_transition;
            end else if (invert_for_balance) begin
                code[9]   <= 1'b1;
                code[8]   <= transition_d1[8];
                code[7:0] <= ~transition_d1[7:0];
                disparity <= disparity + {transition_d1[8], 1'b0} + zeros_transition - ones_transition;
            end else begin
                code[9]   <= 1'b0;
                code[8]   <= transition_d1[8];
                code[7:0] <= transition_d1[7:0];
                disparity <= disparity - {~transition_d1[8], 1'b0} + ones_transition - zeros_transition;
            end
        end else begin
            disparity <= 5'd0;
            case ({control1_pipe[1], control0_pipe[1]})
                2'b00: code <= CONTROL_00;
                2'b01: code <= CONTROL_01;
                2'b10: code <= CONTROL_10;
                default: code <= CONTROL_11;
            endcase
        end
    end

endmodule

// 四通道10:1串化器。OSER10在像素时钟域装载10位字，并在5倍时钟双沿完成串行发送。
module tmds_serializer_4lane (
    input  wire       pixel_clk,
    input  wire       serial_clk,
    input  wire       reset_n,
    input  wire [9:0] lane0_code,
    input  wire [9:0] lane1_code,
    input  wire [9:0] lane2_code,
    input  wire [9:0] lane3_code,
    output wire [3:0] lane_p,
    output wire [3:0] lane_n
);

    wire [3:0] serialized_lane;

    // D0是每个TMDS字最先发送的最低位，RESET为高电平有效。
    // 每个差分管脚对共用一个IOL，只实例化一个OSER10，再由差分输出缓冲生成P/N。
    OSER10 u_oser_lane0 (
        .Q(serialized_lane[0]),
        .D0(lane0_code[0]), .D1(lane0_code[1]), .D2(lane0_code[2]), .D3(lane0_code[3]), .D4(lane0_code[4]),
        .D5(lane0_code[5]), .D6(lane0_code[6]), .D7(lane0_code[7]), .D8(lane0_code[8]), .D9(lane0_code[9]),
        .PCLK(pixel_clk), .FCLK(serial_clk), .RESET(~reset_n)
    );
    OSER10 u_oser_lane1 (
        .Q(serialized_lane[1]),
        .D0(lane1_code[0]), .D1(lane1_code[1]), .D2(lane1_code[2]), .D3(lane1_code[3]), .D4(lane1_code[4]),
        .D5(lane1_code[5]), .D6(lane1_code[6]), .D7(lane1_code[7]), .D8(lane1_code[8]), .D9(lane1_code[9]),
        .PCLK(pixel_clk), .FCLK(serial_clk), .RESET(~reset_n)
    );
    OSER10 u_oser_lane2 (
        .Q(serialized_lane[2]),
        .D0(lane2_code[0]), .D1(lane2_code[1]), .D2(lane2_code[2]), .D3(lane2_code[3]), .D4(lane2_code[4]),
        .D5(lane2_code[5]), .D6(lane2_code[6]), .D7(lane2_code[7]), .D8(lane2_code[8]), .D9(lane2_code[9]),
        .PCLK(pixel_clk), .FCLK(serial_clk), .RESET(~reset_n)
    );
    OSER10 u_oser_lane3 (
        .Q(serialized_lane[3]),
        .D0(lane3_code[0]), .D1(lane3_code[1]), .D2(lane3_code[2]), .D3(lane3_code[3]), .D4(lane3_code[4]),
        .D5(lane3_code[5]), .D6(lane3_code[6]), .D7(lane3_code[7]), .D8(lane3_code[8]), .D9(lane3_code[9]),
        .PCLK(pixel_clk), .FCLK(serial_clk), .RESET(~reset_n)
    );

    // TLVDS_OBUF占用同一差分IOL的A/B两脚；差分电气属性由器件原语确定，
    // CST只按板卡引脚表固定HDMI1信号名称和管脚位置。
    TLVDS_OBUF u_tlvds_lane0 (.I(serialized_lane[0]), .O(lane_p[0]), .OB(lane_n[0]));
    TLVDS_OBUF u_tlvds_lane1 (.I(serialized_lane[1]), .O(lane_p[1]), .OB(lane_n[1]));
    TLVDS_OBUF u_tlvds_lane2 (.I(serialized_lane[2]), .O(lane_p[2]), .OB(lane_n[2]));
    TLVDS_OBUF u_tlvds_lane3 (.I(serialized_lane[3]), .O(lane_p[3]), .OB(lane_n[3]));

endmodule
