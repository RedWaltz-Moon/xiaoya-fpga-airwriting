`timescale 1ns / 1ps

module acg720_dvp_ov5640_hdmi (
    input  wire        clk50M,
    input  wire        key_s0_reset_n,
    input  wire        key_s1_mode_n,
    input  wire        key_s2_view_n,
    input  wire        key_s3_action_n,
    input  wire        key_s4_action_n,
    input  wire        ir_rx,
    output wire [3:0]  led,
    output wire        LED4,
    output wire        LED5,
    output wire        LED6,
    output wire        LED7,
    output wire        uart_tx,
    input  wire        uart_rx,
    output wire        printer_uart_tx,
    output wire        ws2812_dout,
    output wire        SEG7_DIO,
    output wire        SEG7_RCLK,
    output wire        SEG7_SCLK,
    inout  wire        oled_sda,
    output wire        oled_scl,

    output wire        COMS_RST,
    input  wire [7:0]  COMS_D,
    output wire        COMS_XCLK,
    input  wire        COMS_PCLK,
    input  wire        COMS_HREF,
    input  wire        COMS_VS,
    inout  wire        COMS_SDAT,
    output wire        COMS_SCLK,

    output wire [13:0] O_ddr_addr,
    output wire [2:0]  O_ddr_ba,
    output wire        O_ddr_cs_n,
    output wire        O_ddr_ras_n,
    output wire        O_ddr_cas_n,
    output wire        O_ddr_we_n,
    output wire        O_ddr_clk,
    output wire        O_ddr_clk_n,
    output wire        O_ddr_cke,
    output wire        O_ddr_odt,
    output wire        O_ddr_reset_n,
    output wire [1:0]  O_ddr_dqm,
    inout  wire [15:0] IO_ddr_dq,
    inout  wire [1:0]  IO_ddr_dqs,
    inout  wire [1:0]  IO_ddr_dqs_n,

    output wire        hdmi1_clk_p,
    output wire        hdmi1_clk_n,
    output wire [2:0]  hdmi1_dat_p,
    output wire [2:0]  hdmi1_dat_n,
    output wire        hdmi1_oe
);

    // 顶层端口保留板卡丝印编号和低有效后缀；模块内部继续使用通用复位名，
    // 避免把板级命名扩散到DDR、摄像头和HDMI各功能模块。
    wire reset_n = key_s0_reset_n;

    // 外部复位异步拉低、在板载 50 MHz 时钟域内同步释放。
    reg [1:0] reset_sync;
    always @(posedge clk50M or negedge reset_n) begin
        if (!reset_n)
            reset_sync <= 2'b00;
        else
            reset_sync <= {reset_sync[0], 1'b1};
    end
    wire system_reset_n = reset_sync[1];

    // M6C运行时间显示独占板载数码管的三根74HC595接口，不参与图像和UART时序。
    elapsed_time_sevenseg u_elapsed_time_sevenseg (
        .clk       (clk50M),
        .reset_n   (system_reset_n),
        .seg7_dio  (SEG7_DIO),
        .seg7_rclk (SEG7_RCLK),
        .seg7_sclk (SEG7_SCLK)
    );

    // S1至S4均为低电平按下，统一使用20 ms同步消抖。顶层物理名只说明
    // 板上按键位置，消抖后的功能事件再按当前工作模式分派，避免复用键语义混杂。
    localparam [19:0] KEY_DEBOUNCE_COUNT_MAX = 20'd999_999;
    localparam        WORK_MODE_PEN  = 1'b0;
    localparam        WORK_MODE_HAND = 1'b1;
    wire key_s1_pressed;
    wire key_s2_pressed;
    wire key_s3_pressed;
    wire key_s4_pressed;
    key_debounce #(.DEBOUNCE_COUNT_MAX(KEY_DEBOUNCE_COUNT_MAX)) u_key_s1_mode (
        .clk(clk50M), .reset_n(system_reset_n), .key_n(key_s1_mode_n),
        .pressed_pulse(key_s1_pressed)
    );
    key_debounce #(.DEBOUNCE_COUNT_MAX(KEY_DEBOUNCE_COUNT_MAX)) u_key_s2_view (
        .clk(clk50M), .reset_n(system_reset_n), .key_n(key_s2_view_n),
        .pressed_pulse(key_s2_pressed)
    );
    key_debounce #(.DEBOUNCE_COUNT_MAX(KEY_DEBOUNCE_COUNT_MAX)) u_key_s3_action (
        .clk(clk50M), .reset_n(system_reset_n), .key_n(key_s3_action_n),
        .pressed_pulse(key_s3_pressed)
    );
    key_debounce #(.DEBOUNCE_COUNT_MAX(KEY_DEBOUNCE_COUNT_MAX)) u_key_s4_action (
        .clk(clk50M), .reset_n(system_reset_n), .key_n(key_s4_action_n),
        .pressed_pulse(key_s4_pressed)
    );

    // 红外数字键1～4只在机械消抖之后并入S1～S4功能事件。
    // 这样保留物理按键原有电气、消抖和复位关系，也不改变后续模式与CDC链路。
    wire ir_s1_pressed;
    wire ir_s2_pressed;
    wire ir_s3_pressed;
    wire ir_s4_pressed;
    ht6221_remote_buttons u_ht6221_remote_buttons (
        .clk              (clk50M),
        .reset_n          (system_reset_n),
        .ir_rx            (ir_rx),
        .s1_pressed_pulse (ir_s1_pressed),
        .s2_pressed_pulse (ir_s2_pressed),
        .s3_pressed_pulse (ir_s3_pressed),
        .s4_pressed_pulse (ir_s4_pressed)
    );

    wire s1_action_pressed = key_s1_pressed | ir_s1_pressed;
    wire s2_action_pressed = key_s2_pressed | ir_s2_pressed;
    wire s3_action_pressed = key_s3_pressed | ir_s3_pressed;
    wire s4_action_pressed = key_s4_pressed | ir_s4_pressed;

    reg work_mode;
    reg pen_debug_enabled;
    reg hand_debug_enabled;
    reg hand_threshold_down_toggle;
    reg hand_threshold_up_toggle;
    reg trajectory_clear_toggle;
    reg trajectory_confirm_toggle;
    wire hand_gesture_confirm_pclk;
    wire hand_gesture_clear_pclk;
    reg hand_gesture_confirm_toggle_pclk;
    reg hand_gesture_clear_toggle_pclk;
    reg [2:0] hand_gesture_confirm_clk50_sync;
    reg [2:0] hand_gesture_clear_clk50_sync;
    wire hand_gesture_confirm_clk50 = hand_gesture_confirm_clk50_sync[2] ^
                                      hand_gesture_confirm_clk50_sync[1];
    wire hand_gesture_clear_clk50 = hand_gesture_clear_clk50_sync[2] ^
                                    hand_gesture_clear_clk50_sync[1];

    // HAND姿势事件先同步到50 MHz域，再与物理/红外按键合并；仅HAND在
    // 清空或切换模式同拍时压制确认，PEN原有S3/S4事件组合保持不变。
    wire mode_switch_clear_request = s1_action_pressed;
    wire trajectory_clear_request = (s3_action_pressed && (work_mode == WORK_MODE_PEN)) ||
                                    (hand_gesture_clear_clk50 && (work_mode == WORK_MODE_HAND)) ||
                                    mode_switch_clear_request;
    wire trajectory_confirm_request = (s4_action_pressed && (work_mode == WORK_MODE_PEN)) ||
                                      (hand_gesture_confirm_clk50 && (work_mode == WORK_MODE_HAND) &&
                                       !mode_switch_clear_request && !hand_gesture_clear_clk50);

    // PCLK单拍手势事件先翻转保持，再经50 MHz三级同步异或还原，避免丢脉冲。
    always @(posedge COMS_PCLK or negedge camera_capture_reset_n) begin
        if (!camera_capture_reset_n) begin
            hand_gesture_confirm_toggle_pclk <= 1'b0;
            hand_gesture_clear_toggle_pclk <= 1'b0;
        end else begin
            if (hand_gesture_confirm_pclk)
                hand_gesture_confirm_toggle_pclk <= ~hand_gesture_confirm_toggle_pclk;
            if (hand_gesture_clear_pclk)
                hand_gesture_clear_toggle_pclk <= ~hand_gesture_clear_toggle_pclk;
        end
    end
    always @(posedge clk50M or negedge system_reset_n) begin
        if (!system_reset_n) begin
            hand_gesture_confirm_clk50_sync <= 3'b000;
            hand_gesture_clear_clk50_sync <= 3'b000;
        end else begin
            hand_gesture_confirm_clk50_sync <=
                {hand_gesture_confirm_clk50_sync[1:0], hand_gesture_confirm_toggle_pclk};
            hand_gesture_clear_clk50_sync <=
                {hand_gesture_clear_clk50_sync[1:0], hand_gesture_clear_toggle_pclk};
        end
    end

    always @(posedge clk50M or negedge system_reset_n) begin
        if (!system_reset_n) begin
            work_mode                      <= WORK_MODE_PEN;
            pen_debug_enabled              <= 1'b0;
            hand_debug_enabled             <= 1'b0;
            hand_threshold_down_toggle    <= 1'b0;
            hand_threshold_up_toggle      <= 1'b0;
            trajectory_clear_toggle        <= 1'b0;
            trajectory_confirm_toggle      <= 1'b0;
        end else begin
            if (s1_action_pressed)
                work_mode <= ~work_mode;

            // 两种模式分别保存自己的调试开关，来回切换后仍恢复各自上次选择。
            if (s2_action_pressed) begin
                if (work_mode == WORK_MODE_PEN)
                    pen_debug_enabled <= ~pen_debug_enabled;
                else
                    hand_debug_enabled <= ~hand_debug_enabled;
            end

            // 单周期按键事件通过翻转位送往PCLK域，避免20 ns脉冲被异步采样遗漏。
            if (trajectory_clear_request)
                trajectory_clear_toggle <= ~trajectory_clear_toggle;
            if (trajectory_confirm_request)
                trajectory_confirm_toggle <= ~trajectory_confirm_toggle;

            // HAND仅识别蓝布前的绿手套。S3放宽、S4收紧三项绿色优势门限；
            // 按键事件用翻转位送往PCLK域，同时按下则不改变阈值。
            if (work_mode == WORK_MODE_HAND) begin
                if (s3_action_pressed && !s4_action_pressed)
                    hand_threshold_down_toggle <= ~hand_threshold_down_toggle;
                else if (s4_action_pressed && !s3_action_pressed)
                    hand_threshold_up_toggle <= ~hand_threshold_up_toggle;
            end
        end
    end

    // DDR3 IP 的高速存储器时钟必须由 PLL 的 CLKOUT2 输出。
    wire clk200M;
    wire pll_lock;
    wire pll_stop;
    wire pll_clkout0_unused;
    wire pll_clkout1_unused;

    Gowin_PLL u_ddr_pll (
        .clkin   (clk50M),
        .init_clk(clk50M),
        .enclk0  (1'b1),
        .enclk1  (1'b1),
        // 138K DDR3 校准期间会通过该信号暂停或恢复 CLKOUT2。
        .enclk2  (pll_stop),
        .clkout0 (pll_clkout0_unused),
        .clkout1 (pll_clkout1_unused),
        .clkout2 (clk200M),
        .lock    (pll_lock),
        .reset   (~reset_n)
    );

    // M7B开机自检先独占DDR用户接口，16KiB两轮反码写读完成后，
    // 同一ui_clk域的pass锁存只切换一次，将所有权永久交给原帧缓冲，直到复位。
    wire         ddr_ui_clk;
    wire         ddr_ui_reset;
    wire         init_calib_complete;
    wire         cmd_ready;
    wire [2:0]   ddr_cmd;
    wire         ddr_cmd_en;
    wire [27:0]  ddr_addr;
    wire         wr_data_ready;
    wire [127:0] wr_data;
    wire         wr_data_en;
    wire         wr_data_end;
    wire [127:0] rd_data;
    wire         rd_data_valid;
    wire         rd_data_end;
    wire         self_refresh_ack;
    wire         refresh_ack;

    wire [2:0] startup_cmd;
    wire startup_cmd_en;
    wire [27:0] startup_addr;
    wire [127:0] startup_wr_data;
    wire startup_wr_en;
    wire startup_wr_end;
    wire startup_test_pass;
    wire startup_test_failed;
    wire startup_test_timeout;
    wire [2:0] frame_cmd;
    wire frame_cmd_en;
    wire [27:0] frame_addr;
    wire [127:0] frame_wr_data;
    wire frame_wr_en;
    wire frame_wr_end;
    ddr3_self_test u_startup_ddr_test (
        .reset_n(system_reset_n), .ui_clk(ddr_ui_clk), .ui_reset(ddr_ui_reset),
        .init_calib_complete(init_calib_complete),
        .cmd_ready(cmd_ready), .wr_data_ready(wr_data_ready),
        .rd_data(rd_data), .rd_data_valid(rd_data_valid),
        .cmd(startup_cmd), .cmd_en(startup_cmd_en), .addr(startup_addr),
        .wr_data(startup_wr_data), .wr_data_en(startup_wr_en), .wr_data_end(startup_wr_end),
        .test_pass(startup_test_pass), .test_failed(startup_test_failed),
        .test_timeout(startup_test_timeout)
    );
    assign ddr_cmd = startup_test_pass ? frame_cmd : startup_cmd;
    assign ddr_cmd_en = startup_test_pass ? frame_cmd_en : startup_cmd_en;
    assign ddr_addr = startup_test_pass ? frame_addr : startup_addr;
    assign wr_data = startup_test_pass ? frame_wr_data : startup_wr_data;
    assign wr_data_en = startup_test_pass ? frame_wr_en : startup_wr_en;
    assign wr_data_end = startup_test_pass ? frame_wr_end : startup_wr_end;

    reg [1:0] startup_test_pass_sync;
    reg [1:0] startup_test_fail_sync;
    always @(posedge clk50M or negedge system_reset_n) begin
        if (!system_reset_n) begin
            startup_test_pass_sync <= 2'b00;
            startup_test_fail_sync <= 2'b00;
        end else begin
            startup_test_pass_sync <= {startup_test_pass_sync[0], startup_test_pass};
            startup_test_fail_sync <= {startup_test_fail_sync[0], startup_test_failed | startup_test_timeout};
        end
    end
    // 整个帧缓冲及其FIFO在最后一次自检读返回前保持复位，
    // 通过标志经50MHz两拍后释放，避免把自检返回数据当摄像头像素入FIFO。
    wire frame_buffer_reset_n = system_reset_n && startup_test_pass_sync[1];

    DDR3_Memory_Interface_Top u_ddr3 (
        // 控制器参考时钟使用板载连续 50 MHz，复位已在该时钟域同步释放。
        .clk                (clk50M),
        .pll_stop           (pll_stop),
        .memory_clk         (clk200M),
        .pll_lock           (pll_lock),
        .rst_n              (system_reset_n),
        .clk_out            (ddr_ui_clk),
        .ddr_rst            (ddr_ui_reset),
        .init_calib_complete(init_calib_complete),
        .cmd_ready          (cmd_ready),
        .cmd                (ddr_cmd),
        .cmd_en             (ddr_cmd_en),
        .addr               (ddr_addr),
        .wr_data_rdy        (wr_data_ready),
        .wr_data            (wr_data),
        .wr_data_en         (wr_data_en),
        .wr_data_end        (wr_data_end),
        .wr_data_mask       (16'h0000),
        .rd_data            (rd_data),
        .rd_data_valid      (rd_data_valid),
        .rd_data_end        (rd_data_end),
        .sr_req             (1'b0),
        .ref_req            (1'b0),
        .sr_ack             (self_refresh_ack),
        .ref_ack            (refresh_ack),
        .burst              (1'b1),
        .O_ddr_addr         (O_ddr_addr),
        .O_ddr_ba           (O_ddr_ba),
        .O_ddr_cs_n         (O_ddr_cs_n),
        .O_ddr_ras_n        (O_ddr_ras_n),
        .O_ddr_cas_n        (O_ddr_cas_n),
        .O_ddr_we_n         (O_ddr_we_n),
        .O_ddr_clk          (O_ddr_clk),
        .O_ddr_clk_n        (O_ddr_clk_n),
        .O_ddr_cke          (O_ddr_cke),
        .O_ddr_odt          (O_ddr_odt),
        .O_ddr_reset_n      (O_ddr_reset_n),
        .O_ddr_dqm          (O_ddr_dqm),
        .IO_ddr_dq          (IO_ddr_dq),
        .IO_ddr_dqs         (IO_ddr_dqs),
        .IO_ddr_dqs_n       (IO_ddr_dqs_n)
    );

    // 将 DDR 校准完成信号同步到板载 50 MHz 时钟域，供状态灯和超时计数使用。
    reg [1:0] calib_complete_sync;
    always @(posedge clk50M or negedge system_reset_n) begin
        if (!system_reset_n)
            calib_complete_sync <= 2'b00;
        else
            calib_complete_sync <= {calib_complete_sync[0], init_calib_complete};
    end

    // 帧缓冲完成和三类FIFO故障均为粘滞状态，跨域同步后统一送往板级LED。
    wire frame_buffer_ready;
    wire camera_fifo_overflow;
    wire read_fifo_overflow;
    wire video_fifo_underflow;
    reg [1:0] frame_buffer_ready_sync;
    reg [1:0] camera_fifo_overflow_sync;
    reg [1:0] read_fifo_overflow_sync;
    reg [1:0] video_fifo_underflow_sync;
    always @(posedge clk50M or negedge system_reset_n) begin
        if (!system_reset_n) begin
            frame_buffer_ready_sync   <= 2'b00;
            camera_fifo_overflow_sync <= 2'b00;
            read_fifo_overflow_sync   <= 2'b00;
            video_fifo_underflow_sync <= 2'b00;
        end else begin
            frame_buffer_ready_sync   <= {frame_buffer_ready_sync[0], frame_buffer_ready};
            camera_fifo_overflow_sync <= {camera_fifo_overflow_sync[0], camera_fifo_overflow};
            read_fifo_overflow_sync   <= {read_fifo_overflow_sync[0], read_fifo_overflow};
            video_fifo_underflow_sync <= {video_fifo_underflow_sync[0], video_fifo_underflow};
        end
    end

    // PLL 锁定后约 2 秒仍未完成校准，则锁存超时状态，按复位键可重新测试。
    localparam [26:0] CALIB_TIMEOUT_COUNT = 27'd99_999_999;
    reg [26:0] calib_timeout_counter;
    reg        calib_timeout;
    always @(posedge clk50M or negedge system_reset_n) begin
        if (!system_reset_n) begin
            calib_timeout_counter <= 27'd0;
            calib_timeout         <= 1'b0;
        end else if (!pll_lock) begin
            calib_timeout_counter <= 27'd0;
        end else if (!calib_complete_sync[1] && !calib_timeout) begin
            if (calib_timeout_counter == CALIB_TIMEOUT_COUNT)
                calib_timeout <= 1'b1;
            else
                calib_timeout_counter <= calib_timeout_counter + 1'b1;
        end
    end

    // ACG720板载LED为高电平点亮：PLL锁定、DDR校准、首帧写完、任一帧缓冲故障。
    assign led[0] = pll_lock;
    assign led[1] = calib_complete_sync[1];
    assign led[2] = frame_buffer_ready_sync[1];
    assign led[3] = calib_timeout | startup_test_fail_sync[1] | camera_fifo_overflow_sync[1] |
                    read_fifo_overflow_sync[1] | video_fifo_underflow_sync[1];

    // M2B摄像头基础门禁：第47章camera_pll实际输出25 MHz，直接由板载50 MHz二分频复现。
    // 该时钟只送到OV5640的XCLK输入，不参与DDR3或HDMI时钟链，便于保持M2A回归基线。
    reg camera_xclk_25m;
    always @(posedge clk50M or negedge system_reset_n) begin
        if (!system_reset_n)
            camera_xclk_25m <= 1'b0;
        else
            camera_xclk_25m <= ~camera_xclk_25m;
    end
    assign COMS_XCLK = camera_xclk_25m;

    // SCCB初始化使用50 MHz系统时钟和400 kHz总线；只有每笔寄存器写入收到ACK后才推进。
    // ACG720引脚表没有PWDN落脚，因此仅保留内部连接；模块硬件保持正常工作电平。
    wire camera_init_done;
    wire camera_pwdn_unused;
    camera_init #(
        .SYS_CLOCK       (50_000_000),
        .SCL_CLOCK       (400_000),
        .CAMERA_TYPE     ("ov5640"),
        .IMAGE_TYPE      (0),
        .IMAGE_WIDTH     (1280),
        .IMAGE_HEIGHT    (720),
        .IMAGE_FLIP_EN   (0),
        // 摄像头物理安装方向导致左右相反，在传感器源头镜像可让显示与视觉坐标一致。
        .IMAGE_MIRROR_EN (1)
    ) u_camera_init (
        .Clk          (clk50M),
        .Rst_n        (system_reset_n),
        .Init_Done    (camera_init_done),
        .camera_rst_n (COMS_RST),
        .camera_pwdn  (camera_pwdn_unused),
        .i2c_sclk     (COMS_SCLK),
        .i2c_sdat     (COMS_SDAT)
    );

    // 初始化完成信号来自50 MHz域；在摄像头像素时钟域中异步复位、连续两拍同步释放。
    // 这样DVP捕获模块不会把初始化期间的无效总线活动当成图像数据。
    wire camera_capture_async_reset_n = system_reset_n & camera_init_done;
    reg [1:0] camera_pclk_reset_sync;
    always @(posedge COMS_PCLK or negedge camera_capture_async_reset_n) begin
        if (!camera_capture_async_reset_n)
            camera_pclk_reset_sync <= 2'b00;
        else
            camera_pclk_reset_sync <= {camera_pclk_reset_sync[0], 1'b1};
    end
    wire camera_capture_reset_n = camera_pclk_reset_sync[1];

    // 模式和两套调试开关为慢速电平，连续两拍同步；按键事件通过翻转位
    // 跨域后异或还原成单PCLK脉冲，确保每次按键只执行一次。
    reg [1:0] work_mode_pclk_sync;
    reg [1:0] pen_debug_pclk_sync;
    reg [1:0] hand_debug_pclk_sync;
    reg [2:0] hand_threshold_down_pclk_sync;
    reg [2:0] hand_threshold_up_pclk_sync;
    reg [2:0] trajectory_clear_pclk_sync;
    reg [2:0] trajectory_confirm_pclk_sync;
    always @(posedge COMS_PCLK or negedge camera_capture_reset_n) begin
        if (!camera_capture_reset_n) begin
            work_mode_pclk_sync         <= 2'b00;
            pen_debug_pclk_sync         <= 2'b00;
            hand_debug_pclk_sync        <= 2'b00;
            hand_threshold_down_pclk_sync <= 3'b000;
            hand_threshold_up_pclk_sync <= 3'b000;
            trajectory_clear_pclk_sync  <= 3'b000;
            trajectory_confirm_pclk_sync <= 3'b000;
        end else begin
            work_mode_pclk_sync <= {work_mode_pclk_sync[0], work_mode};
            pen_debug_pclk_sync <= {pen_debug_pclk_sync[0], pen_debug_enabled};
            hand_debug_pclk_sync <= {hand_debug_pclk_sync[0], hand_debug_enabled};
            hand_threshold_down_pclk_sync <=
                {hand_threshold_down_pclk_sync[1:0], hand_threshold_down_toggle};
            hand_threshold_up_pclk_sync <=
                {hand_threshold_up_pclk_sync[1:0], hand_threshold_up_toggle};
            trajectory_clear_pclk_sync <=
                {trajectory_clear_pclk_sync[1:0], trajectory_clear_toggle};
            trajectory_confirm_pclk_sync <=
                {trajectory_confirm_pclk_sync[1:0], trajectory_confirm_toggle};
        end
    end
    reg  work_mode_pclk_active;
    wire mode_switch_pending_pclk =
        (work_mode_pclk_sync[1] != work_mode_pclk_active);
    wire pen_mode_enable_pclk = (work_mode_pclk_active == WORK_MODE_PEN);
    wire hand_mode_enable_pclk = !pen_mode_enable_pclk;
    wire pen_debug_enable_pclk = pen_mode_enable_pclk && pen_debug_pclk_sync[1];
    wire hand_debug_enable_pclk = hand_mode_enable_pclk && hand_debug_pclk_sync[1];
    wire hand_threshold_down_pclk = hand_threshold_down_pclk_sync[2] ^
                                    hand_threshold_down_pclk_sync[1];
    wire hand_threshold_up_pclk = hand_threshold_up_pclk_sync[2] ^
                                  hand_threshold_up_pclk_sync[1];
    wire trajectory_clear_pclk = trajectory_clear_pclk_sync[2] ^
                                 trajectory_clear_pclk_sync[1];
    wire trajectory_confirm_pclk = trajectory_confirm_pclk_sync[2] ^
                                   trajectory_confirm_pclk_sync[1];

    // 复用第47章DVP捕获逻辑，将两个8位字节组装为RGB565像素，并丢弃上电后的前10帧。
    // 本阶段不写DDR帧缓冲，只把真正的DataValid作为摄像头有效数据验收依据。
    wire        camera_image_state;
    wire        camera_data_valid;
    wire [15:0] camera_pixel_data;
    wire        camera_data_hs;
    wire        camera_data_vs;
    wire [10:0] camera_xaddr;
    wire [10:0] camera_yaddr;
    DVP_Capture u_dvp_capture (
        .Rst_n      (camera_capture_reset_n),
        .PCLK       (COMS_PCLK),
        .Vsync      (COMS_VS),
        .Href       (COMS_HREF),
        .Data       (COMS_D),
        .ImageState (camera_image_state),
        .DataValid  (camera_data_valid),
        .DataPixel  (camera_pixel_data),
        .DataHs     (camera_data_hs),
        .DataVs     (camera_data_vs),
        .Xaddr      (camera_xaddr),
        .Yaddr      (camera_yaddr)
    );

    // PEN与HAND视频流水分别约延迟2拍和4拍，不能在有效帧中直接切换，否则会向DDR
    // 写端制造伪帧结束并消耗后台缓冲令牌。请求模式只在原始场消隐连续16拍后生效，
    // 此时两条流水均已退出旧帧，后续像素、有效信号和帧同步按完整新帧成组选择。
    reg [3:0] work_mode_blank_count;
    always @(posedge COMS_PCLK or negedge camera_capture_reset_n) begin
        if (!camera_capture_reset_n) begin
            work_mode_pclk_active <= WORK_MODE_PEN;
            work_mode_blank_count <= 4'd0;
        end else if (camera_data_vs) begin
            work_mode_blank_count <= 4'd0;
        end else begin
            if (work_mode_blank_count != 4'hF)
                work_mode_blank_count <= work_mode_blank_count + 1'b1;
            else
                work_mode_pclk_active <= work_mode_pclk_sync[1];
        end
    end

    // M3R红笔检测参数保持不变。红笔与M5A手部mask并行处理同一原始像素；
    // 手部支路为改善肤色判定时序增加一级流水，各支路分别携带自身有效信号，
    // 最后按模式成组选择像素和有效信号后再写入DDR，不改变笔写检测与轨迹链路。
    wire [15:0] camera_pixel_overlay;
    wire        camera_frame_valid_filtered;
    wire        camera_pixel_valid_filtered;
    wire [15:0] pen_camera_pixel_overlay;
    wire        pen_camera_frame_valid;
    wire        pen_camera_pixel_valid;
    wire [15:0] hand_camera_pixel_overlay;
    wire        hand_camera_frame_valid;
    wire        hand_camera_pixel_valid;
    wire        hand_fingertip_valid;
    wire [10:0] hand_fingertip_x;
    wire [9:0]  hand_fingertip_y;
    wire        hand_fingertip_sample_valid;
    wire        hand_fingertip_sample_connected;
    wire [10:0] hand_fingertip_sample_x;
    wire [9:0]  hand_fingertip_sample_y;
    wire        red_pen_valid;
    wire [10:0] red_pen_centroid_x;
    wire [9:0]  red_pen_centroid_y;
    wire [19:0] red_pen_area;
    wire        red_pen_sample_valid;
    wire        red_pen_sample_connected;
    wire [10:0] red_pen_sample_x;
    wire [9:0]  red_pen_sample_y;
    red_pen_centroid #(
        .R_MIN      (8'd64),
        .EDGE_R_MIN (8'd72),
        .R_DIFF     (8'd40),
        .MIN_AREA   (20'd750),
        .MAX_AREA   (20'd6000),
        .MAX_BOX_WIDTH (11'd128),
        .MAX_BOX_HEIGHT(10'd128),
        .FILTER_MIN_HITS(4'd7),
        .TRACK_RADIUS(11'd160),
        .TRACK_MIN_AREA(20'd500),
        .TRACK_MAX_AREA(20'd8000),
        .TRACK_MAX_BOX(11'd160)
    ) u_red_pen_centroid (
        .pclk         (COMS_PCLK),
        .reset_n      (camera_capture_reset_n),
        .frame_valid  (camera_data_vs),
        .pixel_valid  (camera_data_valid),
        .pixel_x      (camera_xaddr),
        .pixel_y      (camera_yaddr),
        .pixel_in     (camera_pixel_data),
        .debug_mask_enable(pen_debug_enable_pclk),
        .pen_mode_enable(pen_mode_enable_pclk),
        .trajectory_clear(trajectory_clear_pclk),
        .trajectory_confirm(trajectory_confirm_pclk),
        .frame_valid_out(pen_camera_frame_valid),
        .pixel_valid_out(pen_camera_pixel_valid),
        .pixel_out    (pen_camera_pixel_overlay),
        .object_valid (red_pen_valid),
        .centroid_x   (red_pen_centroid_x),
        .centroid_y   (red_pen_centroid_y),
        .object_area  (red_pen_area),
        .trajectory_sample_valid(red_pen_sample_valid),
        .trajectory_sample_connected(red_pen_sample_connected),
        .trajectory_sample_x(red_pen_sample_x),
        .trajectory_sample_y(red_pen_sample_y)
    );

    // M5B仅识别蓝布前的绿手套，全帧绿色门禁后仍由逐候选面积及跟踪距离
    // 过滤噪点；S3/S4联动调绿色优势门限，不影响PEN或摄像头配置。
    hand_skin_mask #(
        .GLOVE_G_MIN(8'd32),
        .GLOVE_GREEN_EXCESS_MIN(9'd28),
        .GLOVE_MIN_HEIGHT(11'd72),
        .GLOVE_FINGER_MIN_ROWS(8'd40)
    ) u_hand_skin_mask (
        .pclk(COMS_PCLK),
        .reset_n(camera_capture_reset_n),
        .frame_valid(camera_data_vs),
        .pixel_valid(camera_data_valid),
        .pixel_x(camera_xaddr),
        .pixel_y(camera_yaddr),
        .pixel_in(camera_pixel_data),
        .hand_mode_enable(hand_mode_enable_pclk),
        .debug_mask_enable(hand_debug_enable_pclk),
        .threshold_decrease(hand_threshold_down_pclk),
        .threshold_increase(hand_threshold_up_pclk),
        .trajectory_clear(trajectory_clear_pclk),
        .trajectory_confirm(trajectory_confirm_pclk),
        .frame_valid_out(hand_camera_frame_valid),
        .pixel_valid_out(hand_camera_pixel_valid),
        .pixel_out(hand_camera_pixel_overlay),
        .fingertip_valid(hand_fingertip_valid),
        .fingertip_x(hand_fingertip_x),
        .fingertip_y(hand_fingertip_y),
        .fingertip_sample_valid(hand_fingertip_sample_valid),
        .fingertip_sample_connected(hand_fingertip_sample_connected),
        .fingertip_sample_x(hand_fingertip_sample_x),
        .fingertip_sample_y(hand_fingertip_sample_y),
        .gesture_confirm_pulse(hand_gesture_confirm_pclk),
        .gesture_clear_pulse(hand_gesture_clear_pclk)
    );

    // PEN与HAND只在此处选择唯一公共采样源，后端点缓存、64点重采样和UART不复制。
    // S1模式切换已经先清空公共轨迹与结果，因此不会把两种模式的点混在同一笔中。
    // 模式请求等待场消隐期间继续输出旧模式完整视频，但停止采点，避免清空后又把
    // 旧模式最后一帧写入公共轨迹；切换完成后的第一个有效点自然建立新段。
    wire        trajectory_sample_valid = !mode_switch_pending_pclk &&
                                          (pen_mode_enable_pclk ?
                                           red_pen_sample_valid :
                                           hand_fingertip_sample_valid);
    wire        trajectory_sample_connected = pen_mode_enable_pclk ?
                                               red_pen_sample_connected :
                                               hand_fingertip_sample_connected;
    wire [10:0] trajectory_sample_x = pen_mode_enable_pclk ?
                                      red_pen_sample_x : hand_fingertip_sample_x;
    wire [9:0] trajectory_sample_y = pen_mode_enable_pclk ?
                                     red_pen_sample_y : hand_fingertip_sample_y;

    assign camera_frame_valid_filtered = pen_mode_enable_pclk ?
                                         pen_camera_frame_valid : hand_camera_frame_valid;
    assign camera_pixel_valid_filtered = pen_mode_enable_pclk ?
                                         pen_camera_pixel_valid : hand_camera_pixel_valid;
    assign camera_pixel_overlay = pen_mode_enable_pclk ?
                                  pen_camera_pixel_overlay : hand_camera_pixel_overlay;

    // M4B在PCLK域按帧保存有序平滑中心。S4冻结快照后，RAM内容和点数保持不变；
    // 50 MHz域先完成64点等距归一化，再从板载UART TX=M15发送V1轨迹帧。
    wire        trajectory_snapshot_toggle;
    wire [8:0]  trajectory_snapshot_count;
    wire [7:0]  trajectory_raw_read_addr;
    wire [21:0] trajectory_raw_read_data;
    wire [5:0]  trajectory_normalized_read_addr;
    wire [15:0] trajectory_normalized_read_data;
    wire        trajectory_points_ready;
    wire        trajectory_frame_sent_pulse;
    wire [7:0]  trajectory_frame_sent_sequence;
    wire        recognition_result_armed;
    wire        recognition_result_valid;
    wire [7:0]  recognition_result_ascii;
    wire [1:0] boot_state;
    wire [7:0] boot_check_pass;
    wire [7:0] boot_check_fail;
    wire oled_initialized;
    wire oled_ack_seen;
    wire oled_ack_error;
    wire [27:0] health_display_payload;
    wire health_display_request;
    wire health_display_ack;

    trajectory_point_buffer u_trajectory_point_buffer (
        .pclk(COMS_PCLK),
        .pclk_reset_n(camera_capture_reset_n),
        .trajectory_clear(trajectory_clear_pclk),
        .trajectory_confirm(trajectory_confirm_pclk),
        .sample_valid(trajectory_sample_valid),
        .sample_connected(trajectory_sample_connected),
        .sample_x(trajectory_sample_x),
        .sample_y(trajectory_sample_y),
        .read_clk(clk50M),
        .read_addr(trajectory_raw_read_addr),
        .read_data(trajectory_raw_read_data),
        .snapshot_toggle(trajectory_snapshot_toggle),
        .snapshot_count(trajectory_snapshot_count)
    );

    trajectory_resampler #(
        .MIN_RAW_POINTS(9'd8),
        .MIN_STROKE_SPAN(11'd48),
        .MIN_STROKE_LENGTH(19'd64)
    ) u_trajectory_resampler (
        .clk(clk50M),
        .reset_n(system_reset_n),
        .snapshot_toggle_async(trajectory_snapshot_toggle),
        .snapshot_count_async(trajectory_snapshot_count),
        .raw_read_addr(trajectory_raw_read_addr),
        .raw_read_data(trajectory_raw_read_data),
        .point_read_addr(trajectory_normalized_read_addr),
        .point_read_data(trajectory_normalized_read_data),
        .points_ready(trajectory_points_ready)
    );

    wire trajectory_serial;
    wire trajectory_serial_busy;
    wire trajectory_allow_start;
    wire host_result_packet_valid;
    wire [7:0] host_result_sequence;
    wire [7:0] host_result_ascii;
    wire host_result_cancel;
    wire printer_active;

    // M7D仅在隔离工程接入打印：原主机UART按整帧仲裁，打印机独占GPIO0_3。
    host_uart_bridge u_host_uart_bridge (
        .clk(clk50M), .reset_n(system_reset_n), .uart_rx(uart_rx), .uart_tx(uart_tx),
        .printer_uart_tx(printer_uart_tx), .trajectory_serial(trajectory_serial),
        .trajectory_busy(trajectory_serial_busy), .trajectory_allow_start(trajectory_allow_start),
        .result_cancel(host_result_cancel), .result_packet_valid(host_result_packet_valid),
        .result_sequence(host_result_sequence), .result_ascii(host_result_ascii),
        .printer_active(printer_active)
    );

    trajectory_uart_packet_tx u_trajectory_uart_packet_tx (
        .clk(clk50M),
        .reset_n(system_reset_n),
        .points_ready(trajectory_points_ready),
        .allow_start(trajectory_allow_start),
        .frame_busy(trajectory_serial_busy),
        .point_read_addr(trajectory_normalized_read_addr),
        .point_read_data(trajectory_normalized_read_data),
        .frame_sent_pulse(trajectory_frame_sent_pulse),
        .frame_sent_sequence(trajectory_frame_sent_sequence),
        .uart_tx(trajectory_serial)
    );

    // 电脑从J21回传单字符识别结果；PEN S4或HAND比耶先登记确认，
    // 仅完整上行轨迹发完后开放接收窗口，并要求回传序号匹配该帧。
    // PEN S3、HAND张掌或模式切换会撤销显示和待发确认。
    result_packet_window u_result_uart_packet_rx (
        .clk(clk50M),
        .reset_n(system_reset_n),
        .packet_valid(host_result_packet_valid),
        .packet_sequence(host_result_sequence),
        .packet_ascii(host_result_ascii),
        .packet_cancel(host_result_cancel),
        .confirm_request(trajectory_confirm_request),
        .clear_request(trajectory_clear_request),
        .trajectory_sent_pulse(trajectory_frame_sent_pulse),
        .trajectory_sent_sequence(trajectory_frame_sent_sequence),
        .result_armed(recognition_result_armed),
        .result_valid(recognition_result_valid),
        .result_ascii(recognition_result_ascii)
    );

    // 外接十六灯仅只读板端50MHz状态，不增添CDC或反馈到摄像头/轨迹/UART。
    // 合法回传灯色不表示游戏正误；GPIO0_2/A15经适当电平匹配接灯环DIN。
    ws2812_status_ring u_ws2812_status_ring (
        .clk(clk50M), .reset_n(system_reset_n), .boot_state(boot_state),
        .hand_mode(work_mode), .result_armed(recognition_result_armed),
        .result_valid(recognition_result_valid), .clear_request(trajectory_clear_request),
        .printer_active(printer_active), .dout(ws2812_dout)
    );

    // OLED与按键、结果接收器同属50 MHz域，状态由独立低速I²C读取。
    // OLED独占两个GPIO0排针：SCL主动输出、SDA开漏，不复用摄像头SCCB。
    ssd1306_status_i2c u_ssd1306_status_i2c (
        .clk(clk50M),
        .reset_n(system_reset_n),
        .hand_mode(work_mode),
        .result_armed(recognition_result_armed),
        .result_valid(recognition_result_valid),
        .boot_state(boot_state),
        .check_pass(boot_check_pass),
        .check_fail(boot_check_fail),
        .initialized(oled_initialized),
        .ack_seen(oled_ack_seen),
        .ack_error(oled_ack_error),
        .oled_sda(oled_sda),
        .oled_scl(oled_scl)
    );

    // 在PCLK域累计帧同步，每16帧翻转一次，形成肉眼可见的帧活动指示。
    // 有效像素标志为粘滞状态，只有经过DVP模块组帧并跳过前10帧后才置位。
    reg       camera_vsync_d;
    reg [3:0] camera_frame_div;
    reg       camera_frame_heartbeat;
    reg       camera_data_seen;
    always @(posedge COMS_PCLK or negedge camera_capture_reset_n) begin
        if (!camera_capture_reset_n) begin
            camera_vsync_d          <= 1'b0;
            camera_frame_div        <= 4'd0;
            camera_frame_heartbeat  <= 1'b0;
            camera_data_seen        <= 1'b0;
        end else begin
            camera_vsync_d <= COMS_VS;
            if (!camera_vsync_d && COMS_VS) begin
                camera_frame_div <= camera_frame_div + 1'b1;
                if (camera_frame_div == 4'd15)
                    camera_frame_heartbeat <= ~camera_frame_heartbeat;
            end
            if (camera_data_valid)
                camera_data_seen <= 1'b1;
        end
    end

    // 跨时钟域状态先同步到50 MHz域，再驱动LED和超时判定，避免状态灯毛刺。
    reg [1:0] camera_frame_heartbeat_sync;
    reg [1:0] camera_data_seen_sync;
    always @(posedge clk50M or negedge system_reset_n) begin
        if (!system_reset_n) begin
            camera_frame_heartbeat_sync <= 2'b00;
            camera_data_seen_sync       <= 2'b00;
        end else begin
            camera_frame_heartbeat_sync <= {camera_frame_heartbeat_sync[0], camera_frame_heartbeat};
            camera_data_seen_sync       <= {camera_data_seen_sync[0], camera_data_seen};
        end
    end

    // 复位释放5秒后仍未完成SCCB初始化或仍无有效RGB565像素，则锁存摄像头故障。
    // 故障灯只能通过复位清除，便于观察间歇性的初始化或数据链路问题。
    localparam [27:0] CAMERA_TIMEOUT_COUNT = 28'd249_999_999;
    reg [27:0] camera_timeout_counter;
    reg        camera_timeout_fault;
    always @(posedge clk50M or negedge system_reset_n) begin
        if (!system_reset_n) begin
            camera_timeout_counter <= 28'd0;
            camera_timeout_fault   <= 1'b0;
        end else if (camera_init_done && camera_data_seen_sync[1]) begin
            camera_timeout_counter <= camera_timeout_counter;
        end else if (!camera_timeout_fault) begin
            if (camera_timeout_counter == CAMERA_TIMEOUT_COUNT)
                camera_timeout_fault <= 1'b1;
            else
                camera_timeout_counter <= camera_timeout_counter + 1'b1;
        end
    end

    // LED4~7继续保留M2B摄像头门禁，DDR帧缓冲故障集中显示在LED3。
    assign LED4 = camera_init_done;
    assign LED5 = camera_frame_heartbeat_sync[1];
    assign LED6 = camera_data_seen_sync[1];
    assign LED7 = camera_timeout_fault;

    // M2A使用独立PLL产生371.25 MHz串行时钟，再由CLKDIV同源分频出74.25 MHz像素时钟。
    // HDMI时钟链与DDR PLL彼此独立，新增显示逻辑不会改变已经通过实测的DDR时序关系。
    wire hdmi_serial_clk;
    wire hdmi_pixel_clk;
    wire hdmi_pll_lock;
    hdmi_pll u_hdmi_pll (
        .clkin   (clk50M),
        .dt0     (4'd0),
        .init_clk(clk50M),
        .clkout0 (hdmi_serial_clk),
        .lock    (hdmi_pll_lock),
        .reset   (~reset_n)
    );

    CLKDIV u_hdmi_clkdiv (
        .RESETN(hdmi_pll_lock & system_reset_n),
        .HCLKIN(hdmi_serial_clk),
        .CLKOUT(hdmi_pixel_clk),
        .CALIB (1'b1)
    );
    defparam u_hdmi_clkdiv.DIV_MODE = "5";

    // HDMI PLL未锁定或系统复位时异步拉低，锁定后只在像素时钟沿连续两拍同步释放。
    // PLL lock不再进入同步器D端组合条件，避免50 MHz初始化域到74.25 MHz像素域的功能性CDC路径。
    wire hdmi_async_reset_n = system_reset_n & hdmi_pll_lock;
    reg [1:0] hdmi_reset_sync;
    always @(posedge hdmi_pixel_clk or negedge hdmi_async_reset_n) begin
        if (!hdmi_async_reset_n)
            hdmi_reset_sync <= 2'b00;
        else
            hdmi_reset_sync <= {hdmi_reset_sync[0], 1'b1};
    end
    wire hdmi_reset_n = hdmi_reset_sync[1];

    wire [15:0] video_pixel_rgb565;
    wire        video_pixel_read;
    wire        video_pixel_empty;

    // 帧缓冲控制器直接连接已经通过M1A/M1B实测的DDR3用户接口。
    // M2D采用双缓冲：摄像头写后台帧，HDMI读前台帧，只在完整显示帧的数据流边界交换。
    ddr3_frame_buffer u_ddr3_frame_buffer (
        .reset_n              (frame_buffer_reset_n),
        .ui_clk               (ddr_ui_clk),
        .ui_reset             (ddr_ui_reset),
        .init_calib_complete  (init_calib_complete),
        .camera_clk           (COMS_PCLK),
        .camera_frame_valid   (camera_frame_valid_filtered),
        .camera_pixel_valid   (camera_pixel_valid_filtered),
        .camera_pixel         (camera_pixel_overlay),
        .video_clk            (hdmi_pixel_clk),
        .video_pixel_read     (video_pixel_read),
        .video_pixel          (video_pixel_rgb565),
        .video_fifo_empty     (video_pixel_empty),
        .cmd_ready            (cmd_ready),
        .wr_data_ready        (wr_data_ready),
        .rd_data              (rd_data),
        .rd_data_valid        (rd_data_valid && startup_test_pass && frame_buffer_reset_n),
        .cmd                  (frame_cmd),
        .cmd_en               (frame_cmd_en),
        .addr                 (frame_addr),
        .wr_data              (frame_wr_data),
        .wr_data_en           (frame_wr_en),
        .wr_data_end          (frame_wr_end),
        .frame_ready          (frame_buffer_ready),
        .camera_fifo_overflow (camera_fifo_overflow),
        .read_fifo_overflow   (read_fifo_overflow)
    );

    wire       video_hsync;
    wire       video_vsync;
    wire       video_de;
    wire [7:0] video_red;
    wire [7:0] video_green;
    wire [7:0] video_blue;

    video_720p_camera u_video_720p_camera (
        .pixel_clk  (hdmi_pixel_clk),
        .reset_n    (hdmi_reset_n),
        .frame_ready(frame_buffer_ready),
        .pixel_data (video_pixel_rgb565),
        .pixel_empty(video_pixel_empty),
        .work_mode_async(work_mode),
        .result_armed_async(recognition_result_armed),
        .result_valid_async(recognition_result_valid),
        .result_ascii_async(recognition_result_ascii),
        .health_payload_async(health_display_payload),
        .health_request_async(health_display_request),
        .health_ack(health_display_ack),
        .pixel_read (video_pixel_read),
        .underflow  (video_fifo_underflow),
        .hsync      (video_hsync),
        .vsync      (video_vsync),
        .de         (video_de),
        .red        (video_red),
        .green      (video_green),
        .blue       (video_blue)
    );

    // 自检诊断独立于图像/动作状态机；只消费同步后的粘滞状态。
    // UART没有开机握手协议，因此只在第一次合法回传后标记验证完成。
    board_health_monitor u_board_health_monitor (
        .clk(clk50M), .reset_n(system_reset_n),
        .camera_clk(COMS_PCLK), .camera_reset_n(camera_capture_reset_n), .camera_vs(COMS_VS),
        .hdmi_clk(hdmi_pixel_clk), .hdmi_reset_n(hdmi_reset_n), .hdmi_vs(video_vsync),
        .ddr_pll_locked(pll_lock), .hdmi_pll_locked(hdmi_pll_lock),
        .ddr_calibrated(calib_complete_sync[1]),
        .ddr_test_pass(startup_test_pass_sync[1]), .ddr_test_failed(startup_test_fail_sync[1]),
        .camera_initialized(camera_init_done), .camera_pixels_seen(camera_data_seen_sync[1]),
        .frame_ready(frame_buffer_ready_sync[1]),
        .buffer_fault(camera_fifo_overflow_sync[1] | read_fifo_overflow_sync[1] | video_fifo_underflow_sync[1]),
        .oled_initialized(oled_initialized), .oled_ack_seen(oled_ack_seen), .oled_ack_error(oled_ack_error),
        .result_valid(recognition_result_valid), .display_ack_async(health_display_ack),
        .display_payload(health_display_payload), .display_request(health_display_request),
        .boot_state(boot_state), .check_pass(boot_check_pass), .check_fail(boot_check_fail)
    );

    // M7C短喵：只由50MHz域合法回传有效上升沿入队，翻转握手到像素域。
    // HDMI PLL失锁同时清空音频队列/播放；原DONE/显示状态不被音频修改。
    wire audio_play_start;
    wire audio_player_ready;
    wire audio_sample_valid;
    wire [15:0] audio_sample_data;
    wire audio_queue_overflow;
    result_audio_event u_result_audio_event (
        .source_clk(clk50M), .source_reset_n(hdmi_async_reset_n),
        .result_valid(recognition_result_valid),
        .pixel_clk(hdmi_pixel_clk), .pixel_reset_n(hdmi_reset_n),
        .player_ready(audio_player_ready), .play_start(audio_play_start),
        .queue_overflow(audio_queue_overflow)
    );
    meow_pcm_player u_meow_pcm_player (
        .pixel_clk(hdmi_pixel_clk), .reset_n(hdmi_reset_n), .play_start(audio_play_start),
        .player_ready(audio_player_ready), .sample_valid(audio_sample_valid),
        .sample_data(audio_sample_data)
    );
    hdmi_tmds_tx u_hdmi_tmds_tx (
        .pixel_clk  (hdmi_pixel_clk),
        .serial_clk (hdmi_serial_clk),
        .reset_n    (hdmi_reset_n),
        .red        (video_red),
        .green      (video_green),
        .blue       (video_blue),
        .hsync      (video_hsync),
        .vsync      (video_vsync),
        .de         (video_de),
        .audio_sample_valid(audio_sample_valid),
        .audio_sample_data(audio_sample_data),
        .tmds_clk_p (hdmi1_clk_p),
        .tmds_clk_n (hdmi1_clk_n),
        .tmds_data_p(hdmi1_dat_p),
        .tmds_data_n(hdmi1_dat_n)
    );

    // HDMI1_OE按引脚表命名；高电平使能板载HDMI1输出通道。
    assign hdmi1_oe = 1'b1;

endmodule
