`timescale 1ns / 1ps

// 合成短喵ROM：12kHz、16位有符号单声道、6960点(0.58秒)。
// 每点保持4个48kHz样本，两声道复制在封包器完成。ROM同步预读，
// 播放完毕持续发零样本，保持显示器音频锁定；不占用DDR/摄像头时钟。
module meow_pcm_player (
    input wire pixel_clk,
    input wire reset_n,
    input wire play_start,
    output wire player_ready,
    output reg sample_valid,
    output reg [15:0] sample_data
);
    localparam [12:0] LAST_SAMPLE = 13'd6959;
    reg [15:0] pcm_rom [0:8191];
    reg [15:0] rom_value;
    reg [12:0] sample_address;
    reg [1:0] repeat_count;
    reg playing;
    reg [13:0] sample_phase;
    // 74.25MHz × 8/12375 = 48kHz；只有使能，不生成新的逻辑时钟。
    wire [13:0] phase_next = sample_phase + 14'd8;
    wire sample_tick = phase_next >= 14'd12375;
    assign player_ready = !playing;
    initial $readmemh("src/audio/meow_12k_s16.mem", pcm_rom);
    always @(posedge pixel_clk) rom_value <= pcm_rom[sample_address];
    always @(posedge pixel_clk or negedge reset_n) begin
        if (!reset_n) begin
            sample_phase <= 14'd0;
            sample_address <= 13'd0;
            repeat_count <= 2'd0;
            playing <= 1'b0;
            sample_valid <= 1'b0;
            sample_data <= 16'd0;
        end else begin
            sample_phase <= sample_tick ? phase_next - 14'd12375 : phase_next;
            sample_valid <= sample_tick;
            if (sample_tick) begin
                sample_data <= playing ? rom_value : 16'd0;
                if (playing) begin
                    if (repeat_count == 2'd3) begin
                        repeat_count <= 2'd0;
                        if (sample_address == LAST_SAMPLE) begin
                            playing <= 1'b0;
                            sample_address <= 13'd0;
                        end else sample_address <= sample_address + 1'b1;
                    end else repeat_count <= repeat_count + 1'b1;
                end
            end
            if (play_start && !playing) begin
                playing <= 1'b1;
                sample_address <= 13'd0;
                repeat_count <= 2'd0;
            end
        end
    end
endmodule
