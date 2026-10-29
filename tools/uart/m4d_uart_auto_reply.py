#!/usr/bin/env python3
"""M4D串口自动闭环：接收V1轨迹帧，并用同一序号固定回传大写A。"""

from __future__ import annotations

# 串口排错工具复用同级采集目录的协议实现，需保留tools结构并用-m入口运行。
# 这里只验证完整收发与同seq回显，固定A不代表模型推理结果。
import argparse
import time
from ..trajectory_collect.collect import (
    SOF, FRAME_LENGTH, POINT_COUNT, PAYLOAD_LENGTH, TRAJECTORY_TYPE,
    TRAJECTORY_VERSION, TrajectoryFrame, TrajectoryStreamParser, build_frame,
)


FIXED_RESULT = "A"


def run_serial_loop(port: str, baudrate: int, reconnect_delay: float, frame_timeout: float) -> None:
    """持续连接串口；断线后等待并重连，Ctrl+C可正常退出。"""
    try:
        import serial
    except ModuleNotFoundError as error:
        raise SystemExit("缺少pyserial，请先执行：python -m pip install pyserial") from error

    while True:
        # 每次连接重新同步；last_sequence只用于日志提示，不屏蔽重复序号的回传。
        parser = TrajectoryStreamParser()
        last_receive_time = time.monotonic()
        last_sequence: int | None = None
        try:
            print(f"正在连接 {port}，{baudrate} 8N1……", flush=True)
            with serial.Serial(
                port=port,
                baudrate=baudrate,
                bytesize=serial.EIGHTBITS,
                parity=serial.PARITY_NONE,
                stopbits=serial.STOPBITS_ONE,
                timeout=0.1,
                write_timeout=1.0,
            ) as link:
                print("串口已连接，等待FPGA轨迹帧；按Ctrl+C退出。", flush=True)
                while True:
                    chunk = link.read(link.in_waiting or 1)
                    now = time.monotonic()
                    if chunk:
                        last_receive_time = now
                        for frame in parser.feed(chunk):
                            response = build_frame(frame.sequence, FIXED_RESULT)
                            written = link.write(response)
                            link.flush()
                            if written != len(response):
                                raise serial.SerialTimeoutException("结果帧未完整写入串口")

                            xs = [point[0] for point in frame.points]
                            ys = [point[1] for point in frame.points]
                            duplicate = "，连续重复序号" if frame.sequence == last_sequence else ""
                            print(
                                f"SEQ={frame.sequence:3d} 64点 "
                                f"X={min(xs):3d}..{max(xs):3d} "
                                f"Y={min(ys):3d}..{max(ys):3d} "
                                f"-> 回传A{duplicate}",
                                flush=True,
                            )
                            last_sequence = frame.sequence
                    elif parser.has_pending_data and now - last_receive_time >= frame_timeout:
                        discarded = parser.discard_pending()
                        print(f"半帧等待超时，丢弃{discarded}字节并继续同步。", flush=True)

        except KeyboardInterrupt:
            print("已停止M4D自动回传。", flush=True)
            return
        except (serial.SerialException, OSError) as error:
            print(f"串口异常：{error}；{reconnect_delay:g}秒后重连。", flush=True)
            time.sleep(reconnect_delay)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="接收FPGA V1轨迹帧，并固定回传同seq的大写A结果帧。"
    )
    parser.add_argument("port", help="Windows如COM3，Linux如/dev/ttyUSB0")
    parser.add_argument("--baudrate", type=int, default=115200, help="波特率，默认115200")
    parser.add_argument(
        "--reconnect-delay",
        type=float,
        default=2.0,
        help="断线重连等待秒数，默认2",
    )
    parser.add_argument(
        "--frame-timeout",
        type=float,
        default=1.0,
        help="半帧接收超时秒数，默认1",
    )
    args = parser.parse_args()
    if args.baudrate <= 0 or args.reconnect_delay < 0 or args.frame_timeout <= 0:
        parser.error("波特率和帧超时必须大于0，重连等待不能小于0")

    run_serial_loop(args.port, args.baudrate, args.reconnect_delay, args.frame_timeout)


if __name__ == "__main__":
    main()
