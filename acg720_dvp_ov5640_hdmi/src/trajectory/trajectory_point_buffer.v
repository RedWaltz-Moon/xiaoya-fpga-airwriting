`timescale 1ns / 1ps

// 单笔有序质心点缓存。写口工作在摄像头PCLK域，读口工作在50 MHz处理域。
// S4确认后冻结写入、锁存点数并翻转snapshot_toggle；点数和RAM内容随后保持稳定，
// 处理域可在检测链继续工作的同时安全读取完整快照。S3清空会重新允许采点。
module trajectory_point_buffer (
    input  wire        pclk,
    input  wire        pclk_reset_n,
    input  wire        trajectory_clear,
    input  wire        trajectory_confirm,
    input  wire        sample_valid,
    input  wire        sample_connected,
    input  wire [10:0] sample_x,
    input  wire [9:0]  sample_y,

    input  wire        read_clk,
    input  wire [7:0]  read_addr,
    output reg  [21:0] read_data,

    output reg         snapshot_toggle,
    output reg  [8:0]  snapshot_count
);

    // 每项保存“是否与前一点连续、X、Y”；256项写满后停止，不覆盖本笔开头。
    (* syn_ramstyle = "block_ram" *) reg [21:0] point_memory [0:255];
    reg [8:0] write_count;
    reg       capture_frozen;

    always @(posedge pclk or negedge pclk_reset_n) begin
        if (!pclk_reset_n) begin
            write_count     <= 9'd0;
            capture_frozen  <= 1'b0;
            snapshot_toggle <= 1'b0;
            snapshot_count  <= 9'd0;
        end else if (trajectory_clear) begin
            write_count    <= 9'd0;
            capture_frozen <= 1'b0;
            snapshot_count <= 9'd0;
        end else if (trajectory_confirm && !capture_frozen) begin
            // RAM内容先停止变化，再由翻转位通知50 MHz域；无需裸跨域读取活动数据。
            capture_frozen  <= 1'b1;
            snapshot_count  <= write_count;
            snapshot_toggle <= ~snapshot_toggle;
        end else if (sample_valid && !capture_frozen && (write_count < 9'd256)) begin
            point_memory[write_count[7:0]] <= {sample_connected, sample_x, sample_y};
            write_count <= write_count + 1'b1;
        end
    end

    // 同步读口延迟一个read_clk；轨迹处理状态机显式等待该延迟。
    always @(posedge read_clk) begin
        read_data <= point_memory[read_addr];
    end

endmodule
