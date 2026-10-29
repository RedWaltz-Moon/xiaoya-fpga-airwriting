`timescale 1ns / 1ps

// M7B只读健康监测：50 MHz参考域统计摄像头VS帧数、汇总开机检查。
// 本模块不复位外设、不发送串口数据，也不向图像管线提供反压。
// check位：0时钟锁定、1DDR校准、2DDR写读比较、3相机初始化、
// 4相机有效视频、5HDMI内部扫描、6OLED应答、7有效UART回传。
// UART需要外部主机/真实书写验证，不作为开机必过项；HDMI项不证明屏幕已连接。
module board_health_monitor #(
    parameter [25:0] SECOND_LAST = 26'd49_999_999,
    parameter [3:0] BOOT_SECONDS = 4'd8,
    parameter [3:0] SHOW_SECONDS = 4'd10
) (
    input wire clk,
    input wire reset_n,
    input wire camera_clk,
    input wire camera_reset_n,
    input wire camera_vs,
    input wire hdmi_clk,
    input wire hdmi_reset_n,
    input wire hdmi_vs,
    input wire ddr_pll_locked,
    input wire hdmi_pll_locked,
    input wire ddr_calibrated,
    input wire ddr_test_pass,
    input wire ddr_test_failed,
    input wire camera_initialized,
    input wire camera_pixels_seen,
    input wire frame_ready,
    input wire buffer_fault,
    input wire oled_initialized,
    input wire oled_ack_seen,
    input wire oled_ack_error,
    input wire result_valid,
    // 多位状态通过保持数据+请求/应答翻转位传给HDMI，禁止裸同步BCD数位。
    input wire display_ack_async,
    output reg [27:0] display_payload,
    output reg display_request,
    output wire [1:0] boot_state,
    output wire [7:0] check_pass,
    output reg [7:0] check_fail
);
    reg camera_vs_d;
    reg camera_frame_toggle;
    always @(posedge camera_clk or negedge camera_reset_n) begin
        if (!camera_reset_n) begin
            camera_vs_d <= 1'b0;
            camera_frame_toggle <= 1'b0;
        end else begin
            camera_vs_d <= camera_vs;
            if (camera_vs && !camera_vs_d)
                camera_frame_toggle <= ~camera_frame_toggle;
        end
    end

    reg hdmi_vs_d;
    reg hdmi_frame_toggle;
    always @(posedge hdmi_clk or negedge hdmi_reset_n) begin
        if (!hdmi_reset_n) begin
            hdmi_vs_d <= 1'b0;
            hdmi_frame_toggle <= 1'b0;
        end else begin
            hdmi_vs_d <= hdmi_vs;
            if (hdmi_vs && !hdmi_vs_d)
                hdmi_frame_toggle <= ~hdmi_frame_toggle;
        end
    end

    reg [2:0] camera_toggle_sync;
    reg [2:0] hdmi_toggle_sync;
    reg [1:0] display_ack_sync;
    reg [1:0] ddr_lock_sync;
    reg [1:0] hdmi_lock_sync;
    wire camera_frame_event = camera_toggle_sync[2] ^ camera_toggle_sync[1];
    wire hdmi_frame_event = hdmi_toggle_sync[2] ^ hdmi_toggle_sync[1];
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            camera_toggle_sync <= 3'b000;
            hdmi_toggle_sync <= 3'b000;
            display_ack_sync <= 2'b00;
            ddr_lock_sync <= 2'b00;
            hdmi_lock_sync <= 2'b00;
        end else begin
            camera_toggle_sync <= {camera_toggle_sync[1:0], camera_frame_toggle};
            hdmi_toggle_sync <= {hdmi_toggle_sync[1:0], hdmi_frame_toggle};
            display_ack_sync <= {display_ack_sync[0], display_ack_async};
            ddr_lock_sync <= {ddr_lock_sync[0], ddr_pll_locked};
            hdmi_lock_sync <= {hdmi_lock_sync[0], hdmi_pll_locked};
        end
    end

    reg [25:0] second_counter;
    wire second_tick = second_counter == SECOND_LAST;
    reg [3:0] startup_seconds;
    reg [3:0] frame_tens;
    reg [3:0] frame_units;
    reg [7:0] fps_bcd;
    reg camera_ever_seen;
    reg camera_live;
    reg hdmi_window_seen;
    reg hdmi_live;
    reg uart_verified;
    // 本秒边界上的帧计入刚结束的一秒，不丢边界事件；超过99饱和显示。
    wire [3:0] next_units = !camera_frame_event ? frame_units :
        ((frame_tens == 4'd9 && frame_units == 4'd9) ? 4'd9 :
         (frame_units == 4'd9 ? 4'd0 : frame_units + 1'b1));
    wire [3:0] next_tens = !camera_frame_event ? frame_tens :
        ((frame_units == 4'd9 && frame_tens != 4'd9) ? frame_tens + 1'b1 : frame_tens);

    assign check_pass = {uart_verified,
        (oled_initialized && oled_ack_seen && !oled_ack_error),
        (hdmi_lock_sync[1] && hdmi_live),
        (camera_initialized && camera_pixels_seen && frame_ready && camera_live),
        camera_initialized, ddr_test_pass, ddr_calibrated,
        (ddr_lock_sync[1] && hdmi_lock_sync[1])};
    wire required_ready = &check_pass[6:0];
    wire any_failure = |check_fail[6:0];
    assign boot_state = any_failure ? 2'd2 : required_ready ? 2'd1 : 2'd0;

    // 输出payload位布局：27自检页显示，26:19失败，18:11通过，
    // 10:9总状态(CHECK/OK/FAIL)，8已观察到VS，7:0两位BCD摄像头FPS。
    // 数据只在应答空闲时更新并保持到像素域消费；最大每秒发布一次。
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            second_counter <= 26'd0;
            startup_seconds <= 4'd0;
            frame_tens <= 4'd0;
            frame_units <= 4'd0;
            fps_bcd <= 8'd0;
            camera_ever_seen <= 1'b0;
            camera_live <= 1'b0;
            hdmi_window_seen <= 1'b0;
            hdmi_live <= 1'b0;
            uart_verified <= 1'b0;
            check_fail <= 8'd0;
            display_payload <= 28'h8000000;
            display_request <= 1'b0;
        end else begin
            if (camera_frame_event) camera_ever_seen <= 1'b1;
            if (hdmi_frame_event) hdmi_window_seen <= 1'b1;
            if (result_valid) uart_verified <= 1'b1;

            // 真实DDR比较失败、OLED缺应答和原FIFO故障立即锁存到复位。
            if (ddr_test_failed) check_fail[2] <= 1'b1;
            if (oled_ack_error) check_fail[6] <= 1'b1;
            if (buffer_fault) check_fail[4] <= 1'b1;

            if (second_tick) begin
                second_counter <= 26'd0;
                if (startup_seconds < SHOW_SECONDS)
                    startup_seconds <= startup_seconds + 1'b1;
                fps_bcd <= {next_tens, next_units};
                camera_live <= (next_tens != 4'd0 || next_units != 4'd0);
                hdmi_live <= hdmi_window_seen || hdmi_frame_event;
                hdmi_window_seen <= 1'b0;
                frame_tens <= 4'd0;
                frame_units <= 4'd0;
                // 开机8秒后检查尚未通过项；后续每秒继续观察链路，
                // 不因一次历史活动永久掩盖停帧/失锁。故障不自动复位系统。
                if (startup_seconds >= BOOT_SECONDS - 1'b1) begin
                    check_fail[6:0] <= check_fail[6:0] | ~check_pass[6:0] |
                        {oled_ack_error, !(hdmi_window_seen || hdmi_frame_event),
                         (buffer_fault || (next_tens == 0 && next_units == 0)),
                         1'b0, ddr_test_failed, 2'b00};
                end
            end else begin
                second_counter <= second_counter + 1'b1;
                frame_tens <= next_tens;
                frame_units <= next_units;
            end
            if (second_tick && display_ack_sync[1] == display_request) begin
                // 发布上一个已锁存的完整监测周期，故显示可有约一秒延迟。
                display_payload <= {(startup_seconds < SHOW_SECONDS || any_failure),
                    check_fail, check_pass, boot_state, camera_ever_seen, fps_bcd};
                display_request <= ~display_request;
            end
        end
    end
endmodule
