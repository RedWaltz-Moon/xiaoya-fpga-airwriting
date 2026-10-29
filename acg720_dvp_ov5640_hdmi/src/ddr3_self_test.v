`timescale 1ns / 1ps

// DDR3最小写读自检：先写满一组测试地址，再逐项读回比较。
// 两轮数据互为反码，可同时覆盖数据线的高、低电平以及地址相关数据变化。
module ddr3_self_test #(
    // 正常用户时钟约50MHz、五秒超时；仿真可缩短计数，不改变上板默认值。
    parameter [27:0] TIMEOUT_COUNT = 28'd249_999_999
) (
    input  wire         reset_n,
    input  wire         ui_clk,
    input  wire         ui_reset,
    input  wire         init_calib_complete,
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

    output reg          test_pass,
    output reg          test_failed,
    output reg          test_timeout
);

    localparam [2:0] STATE_WAIT_CALIB = 3'd0;
    localparam [2:0] STATE_WRITE      = 3'd1;
    localparam [2:0] STATE_READ_CMD   = 3'd2;
    localparam [2:0] STATE_READ_DATA  = 3'd3;
    localparam [2:0] STATE_PASS       = 3'd4;
    localparam [2:0] STATE_FAIL       = 3'd5;

    // 1024个突发对应16 KiB；BL8、x16配置下，相邻128位突发地址相差8。
    localparam [9:0]  LAST_TEST_INDEX = 10'd1023;
    localparam [27:0] ADDRESS_STEP     = 28'd8;

    reg [2:0]  state;
    reg        pattern_phase;
    reg [9:0]  test_index;
    reg [27:0] current_addr;
    reg [27:0] timeout_counter;

    // 使用显式组合线网生成地址相关数据，避免旧版综合器映射宽函数时不稳定。
    wire [15:0] index_pattern;
    wire [15:0] inverse_index_pattern;
    wire [127:0] base_test_data;
    wire [127:0] expected_test_data;
    assign index_pattern         = {6'd0, test_index};
    assign inverse_index_pattern = ~index_pattern;
    assign base_test_data        = {
        16'hA5A5,
        index_pattern,
        16'h5A5A,
        inverse_index_pattern,
        16'h0000,
        index_pattern,
        16'hFFFF,
        inverse_index_pattern
    };
    assign expected_test_data = pattern_phase ? ~base_test_data : base_test_data;

    // 同板参考例程在两个ready同时有效时，同周期提交写命令和写数据。
    wire write_accept;
    wire read_accept;
    assign write_accept = (state == STATE_WRITE) && cmd_ready && wr_data_ready;
    assign read_accept  = (state == STATE_READ_CMD) && cmd_ready;

    assign cmd         = (state == STATE_READ_CMD) ? 3'b001 : 3'b000;
    assign cmd_en      = write_accept | read_accept;
    assign addr        = current_addr;
    assign wr_data     = expected_test_data;
    assign wr_data_en  = write_accept;
    assign wr_data_end = write_accept;

    // M7B外部复位异步清除，包括PLL先停而ui_clk没有边沿的情况。
    // 否则旧test_pass可能在下次上电路径中提前放行帧缓冲。
    // DDR内部ui_reset仍同步执行，测试地址/数据算法与原M1B保持一致。
    always @(posedge ui_clk or negedge reset_n) begin
        if (!reset_n || ui_reset) begin
            state           <= STATE_WAIT_CALIB;
            pattern_phase   <= 1'b0;
            test_index      <= 10'd0;
            current_addr    <= 28'd0;
            timeout_counter <= 28'd0;
            test_pass       <= 1'b0;
            test_failed     <= 1'b0;
            test_timeout    <= 1'b0;
        end else if ((state != STATE_PASS) &&
                     (state != STATE_FAIL) &&
                     (timeout_counter == TIMEOUT_COUNT)) begin
            state        <= STATE_FAIL;
            test_failed  <= 1'b1;
            test_timeout <= 1'b1;
        end else begin
            if ((state != STATE_PASS) && (state != STATE_FAIL))
                timeout_counter <= timeout_counter + 1'b1;

            case (state)
                STATE_WAIT_CALIB: begin
                    if (init_calib_complete) begin
                        pattern_phase <= 1'b0;
                        test_index    <= 10'd0;
                        current_addr  <= 28'd0;
                        state         <= STATE_WRITE;
                    end
                end

                STATE_WRITE: begin
                    if (write_accept) begin
                        if (test_index == LAST_TEST_INDEX) begin
                            test_index   <= 10'd0;
                            current_addr <= 28'd0;
                            state        <= STATE_READ_CMD;
                        end else begin
                            test_index   <= test_index + 1'b1;
                            current_addr <= current_addr + ADDRESS_STEP;
                        end
                    end
                end

                STATE_READ_CMD: begin
                    if (read_accept)
                        state <= STATE_READ_DATA;
                end

                STATE_READ_DATA: begin
                    if (rd_data_valid) begin
                        if (rd_data != expected_test_data) begin
                            test_failed <= 1'b1;
                            state       <= STATE_FAIL;
                        end else if (test_index == LAST_TEST_INDEX) begin
                            if (pattern_phase == 1'b0) begin
                                // 第一轮正确后，用整组反码覆盖同一地址并再次读回。
                                pattern_phase <= 1'b1;
                                test_index    <= 10'd0;
                                current_addr  <= 28'd0;
                                state         <= STATE_WRITE;
                            end else begin
                                test_pass <= 1'b1;
                                state     <= STATE_PASS;
                            end
                        end else begin
                            test_index   <= test_index + 1'b1;
                            current_addr <= current_addr + ADDRESS_STEP;
                            state        <= STATE_READ_CMD;
                        end
                    end
                end

                STATE_PASS: begin
                    state <= STATE_PASS;
                end

                STATE_FAIL: begin
                    state <= STATE_FAIL;
                end

                default: begin
                    test_failed <= 1'b1;
                    state       <= STATE_FAIL;
                end
            endcase
        end
    end

endmodule
