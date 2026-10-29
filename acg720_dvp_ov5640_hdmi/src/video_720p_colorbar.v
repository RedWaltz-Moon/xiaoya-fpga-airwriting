`timescale 1ns / 1ps

// 标准CEA-861 1280x720@60扫描时序与八色竖向色条发生器。
// 像素时钟为74.25 MHz；输出同步、数据有效和RGB数据均在像素时钟域寄存。
module video_720p_colorbar (
    input  wire       pixel_clk,
    input  wire       reset_n,
    output reg        hsync,
    output reg        vsync,
    output reg        de,
    output reg  [7:0] red,
    output reg  [7:0] green,
    output reg  [7:0] blue
);

    localparam [11:0] H_SYNC   = 12'd40;
    localparam [11:0] H_BACK   = 12'd220;
    localparam [11:0] H_ACTIVE = 12'd1280;
    localparam [11:0] H_TOTAL  = 12'd1650;
    localparam [11:0] V_SYNC   = 12'd5;
    localparam [11:0] V_BACK   = 12'd20;
    localparam [11:0] V_ACTIVE = 12'd720;
    localparam [11:0] V_TOTAL  = 12'd750;

    localparam [11:0] H_START = H_SYNC + H_BACK;
    localparam [11:0] H_END   = H_START + H_ACTIVE;
    localparam [11:0] V_START = V_SYNC + V_BACK;
    localparam [11:0] V_END   = V_START + V_ACTIVE;

    reg [11:0] h_count;
    reg [11:0] v_count;
    wire active_now = (h_count >= H_START) && (h_count < H_END) &&
                      (v_count >= V_START) && (v_count < V_END);
    wire [11:0] active_x = h_count - H_START;

    // 行场计数覆盖完整消隐区，计数回卷点决定精确的1650×750总周期。
    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            h_count <= 12'd0;
            v_count <= 12'd0;
        end else if (h_count == H_TOTAL - 1'b1) begin
            h_count <= 12'd0;
            if (v_count == V_TOTAL - 1'b1)
                v_count <= 12'd0;
            else
                v_count <= v_count + 1'b1;
        end else begin
            h_count <= h_count + 1'b1;
        end
    end

    // 720p采用正极性同步；每条160像素的竖条便于观察通道顺序、稳定性和边界。
    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            hsync <= 1'b0;
            vsync <= 1'b0;
            de    <= 1'b0;
            red   <= 8'd0;
            green <= 8'd0;
            blue  <= 8'd0;
        end else begin
            hsync <= (h_count < H_SYNC);
            vsync <= (v_count < V_SYNC);
            de    <= active_now;
            if (!active_now) begin
                {red, green, blue} <= 24'h000000;
            end else begin
                if (active_x < 12'd160)
                    {red, green, blue} <= 24'hFFFFFF;
                else if (active_x < 12'd320)
                    {red, green, blue} <= 24'hFFFF00;
                else if (active_x < 12'd480)
                    {red, green, blue} <= 24'h00FFFF;
                else if (active_x < 12'd640)
                    {red, green, blue} <= 24'h00FF00;
                else if (active_x < 12'd800)
                    {red, green, blue} <= 24'hFF00FF;
                else if (active_x < 12'd960)
                    {red, green, blue} <= 24'hFF0000;
                else if (active_x < 12'd1120)
                    {red, green, blue} <= 24'h0000FF;
                else
                    {red, green, blue} <= 24'h000000;
            end
        end
    end

endmodule
