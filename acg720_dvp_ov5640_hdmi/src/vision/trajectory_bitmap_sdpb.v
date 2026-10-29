`timescale 1ns / 1ps

// 16K×1双端口轨迹位图。
// A口在垂直消隐期写入/清除轨迹，B口随摄像头像素流同步读取；
// 目标器件为GW5AT-138C，地址宽度14位，对应SDPB的一位数据组织。
module trajectory_bitmap_sdpb (
    input  wire        clka,
    input  wire        cea,
    input  wire [13:0] ada,
    input  wire        din,
    input  wire        clkb,
    input  wire        ceb,
    input  wire [13:0] adb,
    input  wire        oce,
    input  wire        reset,
    output wire        dout
);

    wire [30:0] unused_dout;

    SDPB u_trajectory_sdpb (
        .DO      ({unused_dout, dout}),
        .CLKA    (clka),
        .CEA     (cea),
        .CLKB    (clkb),
        .CEB     (ceb),
        .OCE     (oce),
        .RESET   (reset),
        .BLKSELA (3'b000),
        .BLKSELB (3'b000),
        .ADA     (ada),
        .DI      ({31'd0, din}),
        .ADB     (adb)
    );

    defparam u_trajectory_sdpb.READ_MODE   = 1'b0;
    defparam u_trajectory_sdpb.BIT_WIDTH_0 = 1;
    defparam u_trajectory_sdpb.BIT_WIDTH_1 = 1;
    defparam u_trajectory_sdpb.BLK_SEL_0   = 3'b000;
    defparam u_trajectory_sdpb.BLK_SEL_1   = 3'b000;
    defparam u_trajectory_sdpb.RESET_MODE  = "SYNC";

endmodule
