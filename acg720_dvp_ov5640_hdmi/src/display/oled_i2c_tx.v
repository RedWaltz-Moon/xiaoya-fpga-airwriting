//=============================================================================
// 模块：oled_i2c_tx
// 功能：
//   用于地址为 0x3C 的 SSD1306，只实现 I2C 单字节写事务。
//   每次 `start` 请求发送：
//     START + 0x78 + ACK + 控制字节 + ACK + 负载字节 + ACK + STOP
//   控制字节为 0x00 时表示命令，为 0x40 时表示显示数据。
//
// 时序：
//   50 MHz 输入时钟除以 125，产生 400 kHz 的四分之一周期节拍。
//   每个 SCL 周期由四个相位组成，得到标称 100 kHz 的 I2C 时钟。
//   M7B只读采样ACK供开机诊断；缺ACK不改变原事务时序或自动重试。
//=============================================================================
module oled_i2c_tx (
    input  wire       clk,       // 50 MHz 系统时钟
    input  wire       rst_n,     // 异步低电平复位
    input  wire       start,     // 单周期请求；busy 期间会被忽略
    input  wire       is_data,   // 0：命令，1：显示缓存数据
    input  wire [7:0] data_byte, // 待发送的命令或显示数据字节
    output reg        busy,      // 整个 I2C 事务期间保持高电平
    output reg        done,      // 事务完成时输出一个时钟周期的脉冲
    output reg        ack_seen,  // 至少一次地址应答，保持到复位
    output reg        ack_error, // 任一地址/控制/数据缺应答，保持到复位
    output reg        scl,       // I2C 时钟输出
    inout  wire       sda        // I2C 开漏数据线
);

    // 事务状态。STOP 使用四个步骤：先保证 SDA 仅在 SCL 为低电平时变化，
    // 再在 SCL 为高电平时让 SDA 上升，以满足 I2C 规范。
    localparam IDLE=3'd0, START_A=3'd1, START_B=3'd2,
               SEND=3'd3, STOP_A=3'd4, STOP_B=3'd5, STOP_C=3'd6,
               STOP_D=3'd7;

    reg [6:0] divider;      // 0～124 的四分之一周期分频计数器
    reg [2:0] state;        // 事务状态
    reg [1:0] phase;        // 每个发送位包含四个相位
    reg [1:0] byte_index;   // 地址、控制、负载字节分别为 0、1、2
    reg [3:0] bit_index;    // 数据位 0～7，ACK 时隙为 8
    reg [7:0] address_byte;
    reg [7:0] control_byte;
    reg [7:0] payload_byte;
    reg       sda_drive_low; // 1：拉低 SDA；0：释放 SDA，由上拉电阻拉高
    reg [7:0] current_byte;
    reg [1:0] sda_sync;

    // SDA 永远不会被主动驱动为高电平，释放线路即可实现开漏行为。
    assign sda = sda_drive_low ? 1'b0 : 1'bz;

    // 外部应答先进入50MHz两级同步器；ACK高电平保持相位有125拍，
    // 在末尾读取时同步延迟已经过去，不改变总线相位或采样窗口。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sda_sync <= 2'b11;
        else sda_sync <= {sda_sync[0], sda};
    end

    // 选择当前正在移出的三个事务字节之一。
    always @(*) begin
        case (byte_index)
            2'd0: current_byte = address_byte;
            2'd1: current_byte = control_byte;
            default: current_byte = payload_byte;
        endcase
    end

    // I2C 事务状态机。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            divider       <= 7'd0;
            state         <= IDLE;
            phase         <= 2'd0;
            byte_index    <= 2'd0;
            bit_index     <= 4'd0;
            address_byte  <= 8'h78;
            control_byte  <= 8'h00;
            payload_byte  <= 8'h00;
            sda_drive_low <= 1'b0;
            scl           <= 1'b1;
            busy          <= 1'b0;
            done          <= 1'b0;
            ack_seen      <= 1'b0;
            ack_error     <= 1'b0;
        end else begin
            done <= 1'b0;

            if (state == IDLE) begin
                divider <= 7'd0;
                if (start) begin
                    // 锁存所有请求输入，使调用方可在 `start` 脉冲后立即改变输入。
                    address_byte  <= 8'h78;
                    control_byte  <= is_data ? 8'h40 : 8'h00;
                    payload_byte  <= data_byte;
                    busy          <= 1'b1;
                    state         <= START_A;
                end
            end else if (divider == 7'd124) begin
                divider <= 7'd0;
                case (state)
                    START_A: begin
                        // 总线空闲：两根线均为高电平。
                        scl           <= 1'b1;
                        sda_drive_low <= 1'b0;
                        state         <= START_B;
                    end
                    START_B: begin
                        // SCL 为高电平时 SDA 下降，产生 START 条件。
                        scl           <= 1'b1;
                        sda_drive_low <= 1'b1;
                        byte_index    <= 2'd0;
                        bit_index     <= 4'd0;
                        phase         <= 2'd0;
                        state         <= SEND;
                    end
                    SEND: begin
                        // 相位 0：拉低 SCL 并设置 SDA
                        // 相位 1：低电平保持时间
                        // 相位 2：拉高 SCL
                        // 相位 3：高电平保持，并推进到下一位/字节
                        case (phase)
                            2'd0: begin
                                scl <= 1'b0;
                                if (bit_index == 4'd8)
                                    // 释放 SDA，使 OLED 可以输出 ACK。
                                    sda_drive_low <= 1'b0;
                                else
                                    sda_drive_low <= ~current_byte[7-bit_index];
                                phase <= 2'd1;
                            end
                            2'd1: phase <= 2'd2;
                            2'd2: begin
                                scl   <= 1'b1;
                                phase <= 2'd3;
                            end
                            default: begin
                                if (bit_index == 4'd8) begin
                                    // 高电平保持相位末尾采样，SDA已释放一个完整
                                    // ACK时隙；只增加状态寄存器，不改变分频/边沿。
                                    if (!sda_sync[1]) begin
                                        if (byte_index == 2'd0) ack_seen <= 1'b1;
                                    end else ack_error <= 1'b1;
                                    bit_index <= 4'd0;
                                    if (byte_index == 2'd2)
                                        state <= STOP_A;
                                    else
                                        byte_index <= byte_index + 1'b1;
                                end else begin
                                    bit_index <= bit_index + 1'b1;
                                end
                                phase <= 2'd0;
                            end
                        endcase
                    end
                    STOP_A: begin
                        // 拉低 SDA 之前，先确保 SCL 为低电平。
                        scl           <= 1'b0;
                        sda_drive_low <= 1'b0;
                        state         <= STOP_B;
                    end
                    STOP_B: begin
                        scl           <= 1'b0;
                        sda_drive_low <= 1'b1;
                        state         <= STOP_C;
                    end
                    STOP_C: begin
                        // 保持 SDA 为低电平，同时拉高 SCL。
                        scl           <= 1'b1;
                        sda_drive_low <= 1'b1;
                        state         <= STOP_D;
                    end
                    STOP_D: begin
                        // SCL 为高电平时 SDA 上升，产生 STOP 条件。
                        scl           <= 1'b1;
                        sda_drive_low <= 1'b0;
                        busy          <= 1'b0;
                        done          <= 1'b1;
                        state         <= IDLE;
                    end
                    default: state <= IDLE;
                endcase
            end else begin
                divider <= divider + 1'b1;
            end
        end
    end

endmodule
