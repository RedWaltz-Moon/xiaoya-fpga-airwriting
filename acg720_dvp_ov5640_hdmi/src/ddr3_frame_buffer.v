`timescale 1ns / 1ps

// 1280×720 RGB565 双帧缓冲控制器。
// 摄像头像素先通过异步非对称FIFO由16位拼成128位，DDR用户时钟域完成读写仲裁；
// DDR读回数据再通过另一只异步FIFO拆成16位，供HDMI像素时钟域连续读取。
// 写端只访问后台缓冲，读端在完整显示帧的数据流边界交换前后台缓冲，避免读写同帧撕裂。
module ddr3_frame_buffer (
    input  wire         reset_n,
    input  wire         ui_clk,
    input  wire         ui_reset,
    input  wire         init_calib_complete,

    input  wire         camera_clk,
    input  wire         camera_frame_valid,
    input  wire         camera_pixel_valid,
    input  wire [15:0]  camera_pixel,

    input  wire         video_clk,
    input  wire         video_pixel_read,
    output wire [15:0]  video_pixel,
    output wire         video_fifo_empty,

    input  wire         cmd_ready,
    input  wire         wr_data_ready,
    input  wire [127:0] rd_data,
    input  wire         rd_data_valid,
    output wire [2:0]   cmd,
    output wire         cmd_en,
    output wire [27:0]  addr,
    output wire [127:0] wr_data,
    output wire         wr_data_en,
    output wire         wr_data_end,

    output reg          frame_ready,
    output reg          camera_fifo_overflow,
    output reg          read_fifo_overflow
);

    // 每帧921600个16位像素；第二帧紧接第一帧存放，两个缓冲共占3.52 MiB。
    // DDR3 BL8、x16用户接口每次传输128位，即8个RGB565像素，用户地址相邻传输加8。
    localparam [27:0] FRAME0_BASE = 28'd0;
    localparam [27:0] FRAME1_BASE = 28'd921_600;
    localparam [27:0] FRAME0_LAST = 28'd921_592;
    localparam [27:0] FRAME1_LAST = 28'd1_843_192;
    localparam [27:0] ADDRESS_STEP = 28'd8;

    wire fifo_reset = ~reset_n;

    // ui_clk域每释放一个后台缓冲就翻转一次令牌；PCLK域只在下一帧起点消费令牌。
    // 若后台缓冲仍等待显示端交换，后续摄像头帧会整帧跳过，不会覆盖正在显示的前台缓冲。
    reg [1:0] calib_camera_sync;
    reg [1:0] write_slot_toggle_sync;
    reg       write_slot_toggle_seen;
    reg       write_slot_pending;
    reg       camera_frame_valid_d;
    reg       camera_frame_accept;
    reg       write_slot_toggle;
    always @(posedge camera_clk or negedge reset_n) begin
        if (!reset_n) begin
            calib_camera_sync      <= 2'b00;
            write_slot_toggle_sync <= 2'b00;
            write_slot_toggle_seen <= 1'b0;
            write_slot_pending     <= 1'b1;
            camera_frame_valid_d   <= 1'b0;
            camera_frame_accept    <= 1'b0;
        end else begin
            calib_camera_sync      <= {calib_camera_sync[0], init_calib_complete};
            write_slot_toggle_sync <= {write_slot_toggle_sync[0], write_slot_toggle};
            camera_frame_valid_d   <= camera_frame_valid;

            if (write_slot_toggle_sync[1] != write_slot_toggle_seen) begin
                write_slot_toggle_seen <= write_slot_toggle_sync[1];
                write_slot_pending     <= 1'b1;
            end

            if (camera_frame_valid && !camera_frame_valid_d) begin
                if (write_slot_pending && calib_camera_sync[1]) begin
                    camera_frame_accept <= 1'b1;
                    write_slot_pending  <= 1'b0;
                end else begin
                    camera_frame_accept <= 1'b0;
                end
            end else if (!camera_frame_valid) begin
                camera_frame_accept <= 1'b0;
            end
        end
    end

    wire         wr_fifo_full;
    wire         wr_fifo_empty;
    wire [127:0] wr_fifo_q;
    wire [11:0]  wr_fifo_wnum_unused;
    wire [8:0]   wr_fifo_rnum;
    wire         wr_fifo_read;
    wire camera_fifo_write = camera_frame_accept && camera_pixel_valid && !wr_fifo_full;

    // 满时禁止继续写入并锁存故障；正常带宽下该状态不应出现。
    always @(posedge camera_clk or negedge reset_n) begin
        if (!reset_n)
            camera_fifo_overflow <= 1'b0;
        else if (camera_frame_accept && camera_pixel_valid && wr_fifo_full)
            camera_fifo_overflow <= 1'b1;
    end

    wr_data_fifo u_wr_data_fifo (
        .Data  (camera_pixel),
        .Reset (fifo_reset),
        .WrClk (camera_clk),
        .RdClk (ui_clk),
        .WrEn  (camera_fifo_write),
        .RdEn  (wr_fifo_read),
        .Wnum  (wr_fifo_wnum_unused),
        .Rnum  (wr_fifo_rnum),
        .Q     (wr_fifo_q),
        .Empty (wr_fifo_empty),
        .Full  (wr_fifo_full)
    );

    wire         rd_fifo_full;
    wire [8:0]   rd_fifo_wnum;
    wire [11:0]  rd_fifo_rnum_unused;
    wire         rd_fifo_write = rd_data_valid && !rd_fifo_full;

    rd_data_fifo u_rd_data_fifo (
        .Data  (rd_data),
        .Reset (fifo_reset),
        .WrClk (ui_clk),
        .RdClk (video_clk),
        .WrEn  (rd_fifo_write),
        .RdEn  (video_pixel_read && !video_fifo_empty),
        .Wnum  (rd_fifo_wnum),
        .Rnum  (rd_fifo_rnum_unused),
        .Q     (video_pixel),
        .Empty (video_fifo_empty),
        .Full  (rd_fifo_full)
    );

    reg [27:0] write_addr;
    reg [27:0] read_addr;
    reg [8:0]  read_outstanding;
    reg        write_bank;
    reg        read_bank;
    reg        pending_bank;
    reg        pending_valid;
    reg        write_slot_active;
    reg        read_stream_started;

    wire [27:0] write_last_addr = write_bank ? FRAME1_LAST : FRAME0_LAST;
    wire [27:0] read_last_addr  = read_bank  ? FRAME1_LAST : FRAME0_LAST;
    wire [27:0] read_base_addr  = read_bank  ? FRAME1_BASE : FRAME0_BASE;

    // 写请求优先，防止摄像头不可暂停的数据流顶满FIFO；剩余周期用于预取显示数据。
    wire write_issue = init_calib_complete && write_slot_active && !wr_fifo_empty &&
                       cmd_ready && wr_data_ready;
    wire [9:0] read_reserved = {1'b0, rd_fifo_wnum} + {1'b0, read_outstanding};
    wire read_issue = init_calib_complete && read_stream_started && !write_issue &&
                      cmd_ready && !rd_fifo_full && (read_reserved < 10'd240);

    assign cmd         = read_issue ? 3'b001 : 3'b000;
    assign cmd_en      = write_issue | read_issue;
    assign addr        = read_issue ? read_addr : write_addr;
    assign wr_data     = wr_fifo_q;
    assign wr_data_en  = write_issue;
    assign wr_data_end = write_issue;
    assign wr_fifo_read = write_issue;

    // 读命令可先于返回数据连续提交；outstanding计数把在途数据计入FIFO容量预算。
    // DDR返回顺序由控制器保证。读地址每完成一帧才检查pending_bank，因此FIFO中的
    // 921600个像素边界始终与HDMI显示帧一致，不需要异步复位读FIFO。
    // 外部按键复位必须异步清除本域地址和双缓冲所有权；否则PLL先停时可能没有
    // ui_clk边沿执行同步清零，而两只FIFO已经复位，重启后会从旧帧中间继续读写。
    // 复位释放期间DDR IP仍保持ui_reset，最终退出仍由稳定的ui_clk同步完成。
    always @(posedge ui_clk or negedge reset_n) begin
        if (!reset_n || ui_reset) begin
            write_addr          <= FRAME0_BASE;
            read_addr           <= FRAME0_BASE;
            read_outstanding    <= 9'd0;
            write_bank          <= 1'b0;
            read_bank           <= 1'b0;
            pending_bank        <= 1'b0;
            pending_valid       <= 1'b0;
            write_slot_active   <= 1'b1;
            read_stream_started <= 1'b0;
            write_slot_toggle   <= 1'b0;
            frame_ready         <= 1'b0;
            read_fifo_overflow  <= 1'b0;
        end else begin
            if (write_issue) begin
                if (write_addr == write_last_addr) begin
                    if (!read_stream_started) begin
                        // 第一帧直接成为前台，同时立即把另一缓冲释放给摄像头。
                        read_bank           <= write_bank;
                        read_addr           <= write_bank ? FRAME1_BASE : FRAME0_BASE;
                        read_stream_started <= 1'b1;
                        frame_ready         <= 1'b1;
                        write_bank          <= ~write_bank;
                        write_addr          <= write_bank ? FRAME0_BASE : FRAME1_BASE;
                        write_slot_active   <= 1'b1;
                        write_slot_toggle   <= ~write_slot_toggle;
                    end else begin
                        // 后续完整帧先发布为pending，等待读数据流到达帧边界再交换。
                        pending_bank      <= write_bank;
                        pending_valid     <= 1'b1;
                        write_slot_active <= 1'b0;
                    end
                end else begin
                    write_addr <= write_addr + ADDRESS_STEP;
                end
            end

            if (read_issue) begin
                if (read_addr == read_last_addr) begin
                    if (pending_valid) begin
                        // 旧前台在此刻已经全部进入读FIFO，可安全转为下一帧的后台写缓冲。
                        read_bank         <= pending_bank;
                        read_addr         <= pending_bank ? FRAME1_BASE : FRAME0_BASE;
                        write_bank        <= read_bank;
                        write_addr        <= read_base_addr;
                        pending_valid     <= 1'b0;
                        write_slot_active <= 1'b1;
                        write_slot_toggle <= ~write_slot_toggle;
                    end else begin
                        // 没有新摄像头帧时重复显示当前前台帧，画面保持稳定。
                        read_addr <= read_base_addr;
                    end
                end else begin
                    read_addr <= read_addr + ADDRESS_STEP;
                end
            end

            case ({read_issue, rd_data_valid})
                2'b10: read_outstanding <= read_outstanding + 1'b1;
                2'b01: begin
                    if (read_outstanding != 0)
                        read_outstanding <= read_outstanding - 1'b1;
                end
                default: read_outstanding <= read_outstanding;
            endcase

            if (rd_data_valid && rd_fifo_full)
                read_fifo_overflow <= 1'b1;
        end
    end

endmodule
