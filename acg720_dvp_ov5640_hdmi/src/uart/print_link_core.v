`timescale 1ns / 1ps

// V1扩展字节核，全部工作在50MHz域。完整CRC及GBK结构通过后才提交有界文本。
// 82=job_id_LE32+文本；83=查询job_id；02回复job_id+状态+长度。
// 当前仅保留最近任务去重；复位/新任务覆盖会丢失历史，主机不得自动重发82。
// 单缓存：忙时不写文本RAM；RAM同步读，两拍等待后交给独立UART发送器。
module print_link_core #(
    parameter integer RX_TIMEOUT_CYCLES = 50000000
) (
    input wire clk, input wire reset_n,
    input wire [7:0] rx_data, input wire rx_valid, input wire rx_error,
    input wire result_cancel,
    input wire reply_busy,
    output reg reply_valid, output reg [7:0] reply_sequence,
    output reg [31:0] reply_job, output reg [7:0] reply_status,
    output reg [15:0] reply_length,
    output reg printer_start, output reg [7:0] printer_data,
    input wire printer_busy, input wire printer_done,
    output reg print_active,
    output reg result_packet_valid, output reg [7:0] result_sequence,
    output reg [7:0] result_ascii
);
    localparam UNKNOWN=8'd0, ACTIVE=8'd1, SENT=8'd2, BUSY=8'd3,
               BAD_TEXT=8'd4, ID_CONFLICT=8'd5;
    reg [3:0] state;
    reg [25:0] receive_idle;
    reg [7:0] frame_type, frame_seq, frame_count, length_low, crc_low;
    reg [15:0] length, crc, payload_crc;
    reg [9:0] payload_index;
    reg [31:0] candidate_job;
    reg [7:0] candidate_ascii;
    reg capture_busy, bad_text;
    reg gbk_pending;
    reg result_block;
    reg last_valid;
    reg [31:0] last_job;
    reg [15:0] last_length, last_payload_crc;
    reg [7:0] last_status;
    reg [7:0] text_ram [0:511];
    reg [8:0] read_address;
    reg [7:0] read_data;
    reg [2:0] send_state;

    function [15:0] crc_next;
        input [15:0] initial_crc; input [7:0] value;
        reg [15:0] work; integer i;
        begin
            work=initial_crc^{value,8'h00};
            for(i=0;i<8;i=i+1)
                work=work[15] ? (work<<1)^16'h1021 : work<<1;
            crc_next=work;
        end
    endfunction
    function printable;
        input [7:0] value;
        begin printable=((value>=32)&&(value<=126)) ||
                        (value==9)||(value==10)||(value==13); end
    endfunction
    function gbk_lead;
        input [7:0] value;
        begin gbk_lead=(value>=8'h81)&&(value<=8'hfe); end
    endfunction
    function gbk_trail;
        input [7:0] value;
        begin gbk_trail=(value>=8'h40)&&(value<=8'hfe)&&(value!=8'h7f); end
    endfunction
    function result_char;
        input [7:0] value;
        begin result_char=((value>=48)&&(value<=57)) ||
                          ((value>=65)&&(value<=90)) || ((value>=97)&&(value<=122)); end
    endfunction

    // 不复位整个RAM，避免把512字节写成大规模清零寄存器。
    always @(posedge clk) read_data <= text_ram[read_address];

    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=0; receive_idle<=0; frame_type<=0; frame_seq<=0;
            frame_count<=0; length_low<=0; crc_low<=0; length<=0;
            crc<=16'hffff; payload_crc<=16'hffff; payload_index<=0;
            candidate_job<=0; candidate_ascii<=0; capture_busy<=0; bad_text<=0; result_block<=0;
            gbk_pending<=0;
            last_valid<=0; last_job<=0; last_length<=0; last_payload_crc<=0;
            last_status<=UNKNOWN; read_address<=0; send_state<=0;
            reply_valid<=0; reply_sequence<=0; reply_job<=0;
            reply_status<=UNKNOWN; reply_length<=0;
            printer_start<=0; printer_data<=0; print_active<=0;
            result_packet_valid<=0; result_sequence<=0; result_ascii<=0;
        end else begin
            reply_valid<=0; printer_start<=0; result_packet_valid<=0;

            // 打印发送独立于主机解析，查询或坏帧不能中止已经接受的文本。
            if(print_active) begin
                case(send_state)
                    1: send_state<=2;
                    2: send_state<=3;
                    3: if(!printer_busy) begin
                        printer_data<=read_data; printer_start<=1; send_state<=4;
                    end
                    4: if(printer_done) begin
                        if({7'd0,read_address}+16'd1==last_length) begin
                            print_active<=0; last_status<=SENT; send_state<=0;
                        end else begin
                            read_address<=read_address+1'b1; send_state<=1;
                        end
                    end
                    default: send_state<=1;
                endcase
            end

            // 1秒无字节或停止位错误只丢弃未提交帧，不取消打印或最近任务记录。
            if(rx_error || ((state!=0) && !rx_valid &&
                            (receive_idle==RX_TIMEOUT_CYCLES-1))) begin
                state<=0; receive_idle<=0; gbk_pending<=0;
            end else if(rx_valid) begin
                receive_idle<=0;
                case(state)
                    0: if(rx_data==8'ha5) begin state<=1; result_block<=0; end
                    1: if(rx_data==8'h5a) state<=2;
                       else if(rx_data!=8'ha5) state<=0;
                    2: if(rx_data==1) begin crc<=crc_next(16'hffff,rx_data); state<=3; end
                       else state<=(rx_data==8'ha5)?1:0;
                    3: if((rx_data==8'h81)||(rx_data==8'h82)||(rx_data==8'h83)) begin
                        frame_type<=rx_data; crc<=crc_next(crc,rx_data); state<=4;
                    end else state<=(rx_data==8'ha5)?1:0;
                    4: begin frame_seq<=rx_data; crc<=crc_next(crc,rx_data); state<=5; end
                    5: begin frame_count<=rx_data; crc<=crc_next(crc,rx_data); state<=6; end
                    6: begin length_low<=rx_data; crc<=crc_next(crc,rx_data); state<=7; end
                    7: begin
                        if((frame_count==1) &&
                           (((frame_type==8'h81)&&({rx_data,length_low}==1)) ||
                            ((frame_type==8'h82)&&({rx_data,length_low}>=5)&&
                                                     ({rx_data,length_low}<=516)) ||
                            ((frame_type==8'h83)&&({rx_data,length_low}==4)))) begin
                            length<={rx_data,length_low}; crc<=crc_next(crc,rx_data);
                            payload_crc<=16'hffff; payload_index<=0; candidate_job<=0;
                            bad_text<=0; gbk_pending<=0; capture_busy<=print_active; state<=8;
                        end else state<=(rx_data==8'ha5)?1:0;
                    end
                    8: begin
                        crc<=crc_next(crc,rx_data);
                        payload_crc<=crc_next(payload_crc,rx_data);
                        if(frame_type==8'h81) begin
                            candidate_ascii<=rx_data;
                            if(!result_char(rx_data)) bad_text<=1;
                        end else begin
                            case(payload_index)
                                0: candidate_job[7:0]<=rx_data;
                                1: candidate_job[15:8]<=rx_data;
                                2: candidate_job[23:16]<=rx_data;
                                3: candidate_job[31:24]<=rx_data;
                                default: if(frame_type==8'h82) begin
                                    // 仅82正文允许GBK双字节；ESC/NUL等仍不能进入文本。
                                    // 只查字节结构，不增加中文字库ROM，也不改变81结果白名单。
                                    if(gbk_pending) begin
                                        if(!gbk_trail(rx_data)) bad_text<=1;
                                        gbk_pending<=0;
                                    end else if(gbk_lead(rx_data)) gbk_pending<=1;
                                    else if(!printable(rx_data)) bad_text<=1;
                                    if(!capture_busy) text_ram[payload_index-10'd4]<=rx_data;
                                end
                            endcase
                        end
                        if({6'd0,payload_index}+16'd1==length) state<=9;
                        else payload_index<=payload_index+1'b1;
                    end
                    9: begin crc_low<=rx_data; state<=10; end
                    10: begin
                        state<=0;
                        if({rx_data,crc_low}==crc) begin
                            if(frame_type==8'h81) begin
                                if(!bad_text && !result_block && !result_cancel) begin
                                    result_packet_valid<=1; result_sequence<=frame_seq;
                                    result_ascii<=candidate_ascii;
                                end
                            end else if((candidate_job!=0) && !reply_busy) begin
                                reply_valid<=1; reply_sequence<=frame_seq;
                                reply_job<=candidate_job; reply_length<=0;
                                if(frame_type==8'h83) begin
                                    reply_status<=UNKNOWN;
                                    if(last_valid && candidate_job==last_job) begin
                                        reply_status<=last_status; reply_length<=last_length;
                                    end
                                // CRC已完整接收，帧末残留首字节也必须拒绝，不能先打印半票。
                                end else if(bad_text || gbk_pending) reply_status<=BAD_TEXT;
                                else if(last_valid && candidate_job==last_job) begin
                                    if((length-16'd4==last_length) &&
                                       (payload_crc==last_payload_crc)) begin
                                        reply_status<=last_status; reply_length<=last_length;
                                    end else reply_status<=ID_CONFLICT;
                                end else if(capture_busy || print_active) reply_status<=BUSY;
                                else begin
                                    // 提交是唯一开始输出的入口；坏CRC/半帧从不输出。
                                    last_valid<=1; last_job<=candidate_job;
                                    last_length<=length-16'd4; last_payload_crc<=payload_crc;
                                    last_status<=ACTIVE; print_active<=1;
                                    read_address<=0; send_state<=1;
                                    reply_status<=ACTIVE; reply_length<=length-16'd4;
                                end
                            end
                        end
                    end
                    default: state<=0;
                endcase
            end else if(state!=0) receive_idle<=receive_idle+1'b1;
            // 清空/新轨迹绑定使正在接收的旧结果失效，但不取消打印任务。
            if(result_cancel) result_block<=1;
        end
    end
endmodule
