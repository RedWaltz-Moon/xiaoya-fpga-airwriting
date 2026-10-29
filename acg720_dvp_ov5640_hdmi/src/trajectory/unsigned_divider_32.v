`timescale 1ns / 1ps

// 32位无符号逐位除法器。每次start后固定32个clk完成，供轨迹处理状态机复用；
// 这样归一化与插值不会在50 MHz域形成大规模组合除法器。
module unsigned_divider_32 (
    input  wire        clk,
    input  wire        reset_n,
    input  wire        start,
    input  wire [31:0] dividend,
    input  wire [31:0] divisor,
    output reg         busy,
    output reg         done,
    output reg  [31:0] quotient,
    output reg  [31:0] remainder
);

    reg [31:0] dividend_work;
    reg [31:0] divisor_latched;
    reg [32:0] remainder_work;
    reg [31:0] quotient_work;
    reg [5:0]  iteration;

    wire [32:0] shifted_remainder =
        {remainder_work[31:0], dividend_work[31]};
    wire quotient_bit = shifted_remainder >= {1'b0, divisor_latched};
    wire [32:0] next_remainder = quotient_bit ?
        shifted_remainder - {1'b0, divisor_latched} : shifted_remainder;
    wire [31:0] next_quotient = {quotient_work[30:0], quotient_bit};

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            busy            <= 1'b0;
            done            <= 1'b0;
            quotient        <= 32'd0;
            remainder       <= 32'd0;
            dividend_work   <= 32'd0;
            divisor_latched <= 32'd1;
            remainder_work  <= 33'd0;
            quotient_work   <= 32'd0;
            iteration       <= 6'd0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                dividend_work   <= dividend;
                divisor_latched <= (divisor == 32'd0) ? 32'd1 : divisor;
                remainder_work  <= 33'd0;
                quotient_work   <= 32'd0;
                iteration       <= 6'd0;
                busy            <= 1'b1;
            end else if (busy) begin
                dividend_work  <= {dividend_work[30:0], 1'b0};
                remainder_work <= next_remainder;
                quotient_work  <= next_quotient;
                if (iteration == 6'd31) begin
                    quotient  <= next_quotient;
                    remainder <= next_remainder[31:0];
                    busy      <= 1'b0;
                    done      <= 1'b1;
                end else begin
                    iteration <= iteration + 1'b1;
                end
            end
        end
    end

endmodule
