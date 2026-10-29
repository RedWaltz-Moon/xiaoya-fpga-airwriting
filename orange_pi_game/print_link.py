"""打印扩展链路验证：发送到FPGA，或用第二个CH340观察转发口；不启动游戏。"""

from __future__ import annotations

import argparse
import math
import secrets
import sys
import time
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from orange_pi_game.serial_protocol import PrintTransaction, STATUS, StreamParser


def run_job(link, text, job_id, *, timeout=5.0, clock=time.monotonic, report=print):
    """与游戏使用同一帧实现；串口独占，只查询状态、不重发打印任务。"""
    # 本工具验证原文转发，不套用游戏的小票排版或E10行序补偿；SENT只表示串口已发完。
    transaction = PrintTransaction(job_id, text, clock(), timeout=timeout)
    parser = StreamParser((STATUS,))
    last_receive = clock()
    previous_state = None
    while not transaction.finished:
        now = clock()
        packet = transaction.poll(now)
        if packet is not None:
            if link.write(packet) != len(packet):
                raise OSError("任务写入不完整，状态未知，不要直接重发")
            # 有限长度写入，不flush等待打印机；串口对象已设置write_timeout。
        chunk = link.read(min(link.in_waiting or 1, 4096))
        if chunk:
            last_receive = clock()
            for frame in parser.feed(chunk):
                if frame.kind == STATUS:
                    transaction.accept(frame)
        elif parser.has_pending_data and clock() - last_receive >= 1:
            parser.discard_pending()
        if transaction.state != previous_state:
            report(f"job={job_id} {transaction.state} {transaction.detail}")
            previous_state = transaction.state
    return transaction


def main(argv=None):
    parser = argparse.ArgumentParser(description="打印串口扩展验证；默认交互选择端口并输入文本")
    parser.add_argument("port", nargs="?", help="FPGA原主机口，如COM3或/dev/ttyUSB0")
    parser.add_argument("--text", help="发送一条GBK中文或ASCII文本；默认追加CRLF")
    parser.add_argument("--job-id", type=lambda s: int(s, 0), help="可选固定任务ID，默认随机非零32位")
    parser.add_argument("--timeout", type=float, default=5.0, help="状态等待秒数，超时不重发")
    parser.add_argument("--monitor", action="store_true", help="此端口连接GPIO转发TX，只观察原文、不发任务")
    args = parser.parse_args(argv)
    if args.monitor and (args.text is not None or args.job_id is not None):
        parser.error("monitor不能与text/job-id组合")
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("timeout须为有限正数")
    if args.job_id is not None and not 1 <= args.job_id <= 0xFFFFFFFF:
        parser.error("job-id须为1..4294967295")
    try:
        import serial
        from orange_pi_game.start import choose_port
        port = args.port or choose_port()
        # 本工具固定115200：正常模式接主机口；monitor仅适合相同速率的诊断转发口。
        # 正式E10打印口为9600，不能用此monitor观察，须用可设置9600的串口助手。
        with serial.Serial(port, 115200, bytesize=8, parity="N", stopbits=1,
                           timeout=.05, write_timeout=1) as link:
            if args.monitor:
                print("只观察转发口：115200 8N1；先打开本窗口，再在另一端发任务。Ctrl+C退出。")
                while True:
                    data = link.read(min(link.in_waiting or 1, 4096))
                    if data:
                        print(f"RX {data!r}  HEX {data.hex(' ').upper()}", flush=True)
            while True:
                text = args.text if args.text is not None else input("打印文本（GBK中文/ASCII，:q退出）：")
                if args.text is None and text == ":q":
                    return 0
                job_id = args.job_id if args.job_id is not None else secrets.randbelow(0xFFFFFFFF) + 1
                result = run_job(link, text + "\r\n", job_id, timeout=args.timeout)
                if args.text is not None:
                    return 0 if result.state == "SENT" else 2
                if result.state != "SENT":
                    print("任务未确认完成，停止会话；先查清原因，不自动提交新任务。")
                    return 2
    except (KeyboardInterrupt, EOFError):
        print("已退出；若发送中退出，转发状态可能未知，不自动重打。")
        return 130
    except (ImportError, OSError, ValueError) as error:
        print(f"链路验证失败：{error}；未安装软件，未自动重发。", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
