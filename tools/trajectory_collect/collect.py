#!/usr/bin/env python3
"""独立采集脚本：内置V1校验和标签格式，仅依赖pyserial，不依赖项目其他文件。"""

from __future__ import annotations

# 协议和样本校验内置，复制此脚本即可采集；不依赖训练或游戏目录。
# 下标即class_index，大小写区分；输入模式只用于数据分组，UART上行没有模式字段。
CLASSES = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
MODES = ("PEN", "HAND")

from dataclasses import dataclass



# V1：帧头2字节 + 版本/类型/seq/点数/长度6字节 + XY交错载荷 + 小端CRC16。
# seq为8位板端序号，复位或回绕可重复，不能用作累计样本数。
SOF = bytes((0xA5, 0x5A))
TRAJECTORY_VERSION = 0x01
TRAJECTORY_TYPE = 0x01
POINT_COUNT = 64
PAYLOAD_LENGTH = POINT_COUNT * 2
FRAME_LENGTH = 2 + 6 + PAYLOAD_LENGTH + 2


@dataclass(frozen=True)
class TrajectoryFrame:
    """一帧已经通过格式和CRC校验的64点轨迹。"""

    sequence: int
    points: tuple[tuple[int, int], ...]


class TrajectoryStreamParser:
    """从任意分块的串口字节流中恢复V1轨迹帧。"""

    def __init__(self) -> None:
        self.buffer = bytearray()
        self.valid_frames = 0
        self.bad_crc_frames = 0
        self.bad_header_candidates = 0
        self.discarded_bytes = 0

    @property
    def has_pending_data(self) -> bool:
        return bool(self.buffer)

    def discard_pending(self) -> int:
        """半帧超时后清空缓存，避免永久等待已经中断的帧。"""
        count = len(self.buffer)
        self.discarded_bytes += count
        self.buffer.clear()
        return count

    def feed(self, data: bytes) -> list[TrajectoryFrame]:
        self.buffer.extend(data)
        frames: list[TrajectoryFrame] = []

        while True:
            sof_index = self.buffer.find(SOF)
            if sof_index < 0:
                # 保留末尾A5，下一批数据可能从5A继续组成跨块帧头。
                keep = 1 if self.buffer[-1:] == SOF[:1] else 0
                discard = len(self.buffer) - keep
                if discard:
                    del self.buffer[:discard]
                    self.discarded_bytes += discard
                break

            if sof_index:
                del self.buffer[:sof_index]
                self.discarded_bytes += sof_index

            if len(self.buffer) < 8:
                break

            header_ok = (
                self.buffer[2] == TRAJECTORY_VERSION
                and self.buffer[3] == TRAJECTORY_TYPE
                and self.buffer[5] == POINT_COUNT
                and self.buffer[6] == (PAYLOAD_LENGTH & 0xFF)
                and self.buffer[7] == (PAYLOAD_LENGTH >> 8)
            )
            if not header_ok:
                del self.buffer[0]
                self.bad_header_candidates += 1
                self.discarded_bytes += 1
                continue

            # 分块尚未收齐时保留缓存；超时策略由串口调用方决定。
            if len(self.buffer) < FRAME_LENGTH:
                break

            raw = bytes(self.buffer[:FRAME_LENGTH])
            crc_received = raw[-2] | (raw[-1] << 8)
            # CRC覆盖版本到载荷末尾，不含帧头和CRC字段本身。
            crc_calculated = crc16_ccitt(raw[2:-2])
            if crc_received != crc_calculated:
                # 只移过一个字节后重新寻找帧头，能够从损坏帧内部恢复后续合法帧。
                del self.buffer[0]
                self.bad_crc_frames += 1
                self.discarded_bytes += 1
                continue

            payload = raw[8:-2]
            points = tuple(zip(payload[0::2], payload[1::2]))
            frames.append(TrajectoryFrame(sequence=raw[4], points=points))
            self.valid_frames += 1
            del self.buffer[:FRAME_LENGTH]

        return frames



def crc16_ccitt(data: bytes) -> int:
    crc = 0xFFFF
    for value in data:
        crc ^= value << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def build_frame(sequence: int, result: str) -> bytes:
    # 回传使用本笔seq和人工标签，只用于板端回显，不代表模型已经识别。
    if len(result) != 1 or result not in CLASSES:
        raise ValueError("结果必须是单个0-9、A-Z或a-z字符")

    body = bytes((0x01, 0x81, sequence, 0x01, 0x01, 0x00, ord(result)))
    crc = crc16_ccitt(body)
    return bytes((0xA5, 0x5A)) + body + bytes((crc & 0xFF, crc >> 8))

from datetime import datetime, timezone



def validate_record_fields(record: dict):
    """返回已通过CRC的帧，供续采、审阅和训练统一校验，不修改原记录。"""
    if not isinstance(record, dict):
        raise ValueError("样本须为JSON对象")
    label = record.get("label")
    if not isinstance(label, str) or len(label) != 1 or label not in CLASSES:
        raise ValueError("标签须为单个0-9、A-Z或a-z字符")
    # 严格排除bool：Python将True视为整数1，但它不是合法的类别编号或坐标。
    if type(record.get("class_index")) is not int or record["class_index"] != CLASSES.index(label):
        raise ValueError("标签与类别编号不一致")
    if record.get("mode") not in MODES:
        raise ValueError("mode须为PEN或HAND")
    for name in ("writer", "session"):
        if not isinstance(record.get(name), str) or not record[name].strip():
            raise ValueError(f"{name}不能为空")
    sequence = record.get("sequence")
    if type(sequence) is not int or not 0 <= sequence <= 255:
        raise ValueError("记录序号须为0..255整数")
    try:
        raw = bytes.fromhex(record["raw_frame_hex"])
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError("原始帧十六进制字段无效") from error
    if len(raw) != FRAME_LENGTH or not raw.startswith(SOF):
        raise ValueError("原始帧长度或帧头错误")
    parser = TrajectoryStreamParser()
    frames = parser.feed(raw)
    if len(frames) != 1 or parser.has_pending_data or parser.discarded_bytes:
        raise ValueError("原始帧格式或CRC错误")
    frame = frames[0]
    if frame.sequence != sequence:
        raise ValueError("记录序号与原始帧不一致")
    points = record.get("points")
    if (not isinstance(points, list) or len(points) != 64
            or any(not isinstance(p, list) or len(p) != 2
                   or any(type(v) is not int or not 0 <= v <= 255 for v in p)
                   for p in points)):
        raise ValueError("点列必须为64组0..255整数坐标")
    # JSON点列必须与CRC保护的原始帧一致，不能只修改其中一份来修补样本。
    if points != [list(p) for p in frame.points]:
        raise ValueError("点列与原始帧不一致")
    return frame


def make_record(
    frame: TrajectoryFrame, label: str, mode: str, writer: str, session: str
) -> dict:
    """保留原始帧和人工标签，供质检及按人员/场次划分数据集。"""
    if len(label) != 1 or label not in CLASSES:
        raise ValueError("标签必须是单个0-9、A-Z或a-z字符")
    if len(frame.points) != 64:
        raise ValueError("V1轨迹必须恰好包含64个点")
    if mode not in MODES or not writer.strip() or not session.strip():
        raise ValueError("mode/writer/session无效")

    payload = bytes(value for point in frame.points for value in point)
    body = bytes((0x01, 0x01, frame.sequence, 0x40, 0x80, 0x00)) + payload
    crc = crc16_ccitt(body)
    raw = SOF + body + bytes((crc & 0xFF, crc >> 8))
    return {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
        "writer": writer,
        "session": session,
        "mode": mode,
        "label": label,
        "class_index": CLASSES.index(label),
        "sequence": frame.sequence,
        "points": [list(point) for point in frame.points],
        "raw_frame_hex": raw.hex().upper(),
    }

import argparse
import json
import time
from collections import Counter
from pathlib import Path
from typing import TextIO




def write_record(output: TextIO, record: dict) -> None:
    """一条完整样本占一行，立即落盘以免中途退出丢失已采内容。"""
    # flush将Python缓冲交给操作系统；未调用fsync，不承诺突然断电后的持久性。
    output.write(json.dumps(record, ensure_ascii=False) + "\n")
    output.flush()


def load_saved_counts(output: TextIO, writer: str, session: str, mode: str) -> Counter[str]:
    """从当前文件恢复已落盘样本数；FPGA的8位seq不能作为采样计数。"""
    counts: Counter[str] = Counter()
    output.seek(0)
    for line_number, line in enumerate(output, 1):
        try:
            record = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"第{line_number}行不是完整JSON样本，请先检查原文件") from error
        if (not isinstance(record, dict) or not isinstance(record.get("label"), str)
                or len(record["label"]) != 1 or record["label"] not in CLASSES):
            raise ValueError(f"第{line_number}行标签无效，请先检查原文件")
        if (record.get("writer"), record.get("session"), record.get("mode")) != (writer, session, mode):
            raise ValueError(f"第{line_number}行的writer/session/mode与本次参数不符，请换文件或参数")
        # 续采不能只看标签计数，损坏CRC或错位点列必须先修复，禁止继续追加。
        try:
            validate_record_fields(record)
        except ValueError as error:
            raise ValueError(f"第{line_number}行样本无效：{error}") from error
        counts[record["label"]] += 1
    output.seek(0, 2)
    return counts


def discard_stale_bytes(link) -> int:
    """进入下一笔前等待串口静默0.5秒，排除标签输入期间积压的旧帧。"""
    # 正式连接每次读超时0.1秒，连续5次空读才算静默；有新数据就重新计时。
    discarded = 0
    quiet_reads = 0
    while quiet_reads < 5:
        chunk = link.read(link.in_waiting or 1)
        if chunk:
            discarded += len(chunk)
            quiet_reads = 0
        else:
            quiet_reads += 1
    return discarded


def choose_port(ports, input_fn=input) -> str:
    """列出当前可用串口并按编号选择；不猜测Gowin下载线的端口。"""
    if not ports:
        raise ValueError("未发现串口，请检查USB串口连接，不能只连接Gowin下载线")
    for index, port in enumerate(ports, 1):
        print(f"{index}. {port.device}  {port.description}")
    while True:
        choice = input_fn("选择串口编号：").strip()
        if choice.isdigit() and 1 <= int(choice) <= len(ports):
            return ports[int(choice) - 1].device
        print("请输入列表中的串口编号。")


def capture_one(
    link, output: TextIO, writer: str, session: str, mode: str,
    input_fn=input, counts: Counter[str] | None = None,
) -> bool:
    """等待一帧完整轨迹后再要标签；False表示用户主动退出。"""
    parser = TrajectoryStreamParser()
    last_receive = time.monotonic()
    while True:
        chunk = link.read(link.in_waiting or 1)
        now = time.monotonic()
        if chunk:
            last_receive = now
            frames = parser.feed(chunk)
            if not frames:
                continue
            if len(frames) > 1:
                print("同批收到多帧，无法确定哪个对应标签；已放弃，请清空后重采。")
                return True
            frame = frames[0]
            xs = [point[0] for point in frame.points]
            ys = [point[1] for point in frame.points]
            print(f"收到seq={frame.sequence}，X={min(xs)}..{max(xs)}，Y={min(ys)}..{max(ys)}。")
            if max(max(xs) - min(xs), max(ys) - min(ys)) < 4:
                print("轨迹跨度过小，本笔不保存或回传；请清空后重写。")
                return True
            while True:
                label = input_fn("输入刚才这笔的标签并回车保存（空回车放弃，:q退出）：").strip()
                if label == ":q":
                    return False
                if not label:
                    print("本笔未保存或回传；请在FPGA清空后重写。")
                    return True
                if len(label) != 1 or label not in CLASSES:
                    print("标签须为单个0-9、A-Z或a-z字符。")
                    continue
                # 先保存再回显；后续串口失败不会撤销JSONL，重采前先核对此笔是否已保存。
                write_record(output, make_record(frame, label, mode, writer, session))
                # 计数只在样本实际写入后增加；同一seq在复位后再次出现也算新样本。
                if counts is not None:
                    counts[label] += 1
                    print(f"已保存 {label}：本文件第{sum(counts.values())}条 / 该字符第{counts[label]}条"
                          f"（FPGA seq={frame.sequence}，仅供协议核对）。")
                else:
                    print(f"已保存 {label} / FPGA seq={frame.sequence}；FPGA回显的是人工标签。")
                reply = build_frame(frame.sequence, label)
                if link.write(reply) != len(reply):
                    raise OSError("标签回显帧未完整发送；JSONL已保存，请检查本笔")
                link.flush()
                return True
        elif parser.has_pending_data and now - last_receive >= 1.0:
            parser.discard_pending()
            print("半帧超时，已重新等待有效轨迹。")


def collect(port: str, output_path: Path, writer: str, session: str, mode: str, input_fn=input) -> None:
    try:
        import serial
    except ModuleNotFoundError as error:
        raise SystemExit("当前环境没有pyserial；请切换到已有串口环境，不会自动安装软件。") from error

    if output_path.suffix.lower() != ".jsonl":
        raise ValueError("采集输出须为.jsonl文件")
    if mode not in MODES or not writer.strip() or not session.strip():
        raise ValueError("mode/writer/session无效")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    # 先校验续采文件再打开串口；参数/CRC不一致时不动板端，原文件也不追加。
    with output_path.open("a+", encoding="utf-8", newline="\n") as output:
        counts = load_saved_counts(output, writer, session, mode)
        print(f"当前文件已保存{sum(counts.values())}条；复位后的FPGA seq不影响此计数。")
        present = " ".join(f"{label}:{counts[label]}" for label in CLASSES if counts[label])
        print("各字符已保存数量：" + (present or "尚无样本"))
        print("标签回显仅用于采集确认，不代表模型识别。")
        print("PEN用S4确认/S3清空；HAND用比耶确认/张掌清空。输入:q退出。")
        with serial.Serial(
            port=port, baudrate=115200, bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE, stopbits=serial.STOPBITS_ONE,
            timeout=0.1, write_timeout=1.0,
        ) as link:
            # 开始和每次输入标签后均排空旧数据，防止把上一笔迟到帧标成下一笔。
            discarded = discard_stale_bytes(link)
            if discarded:
                print(f"已丢弃{discarded}字节旧数据。")
            while True:
                print("等待下一笔：先清空旧轨迹，再书写并确认……", flush=True)
                if not capture_one(link, output, writer, session, mode, input_fn, counts):
                    return
                discarded = discard_stale_bytes(link)
                if discarded:
                    print(f"已丢弃{discarded}字节标签输入期间的旧数据；请等下一条等待提示。")


def main() -> None:
    parser = argparse.ArgumentParser(description="逐笔采集带人工标签的真实64点轨迹JSONL")
    parser.add_argument("output", type=Path, help="追加保存的JSONL文件路径")
    parser.add_argument("--port", help="可选；不指定则列出串口供编号选择")
    parser.add_argument("--writer", required=True, help="书写者编号，不填真实姓名")
    parser.add_argument("--session", required=True, help="采集场次编号，训练/测试按场次隔离")
    parser.add_argument("--mode", required=True, choices=MODES)
    args = parser.parse_args()
    if not args.writer.strip() or not args.session.strip():
        parser.error("writer和session不能为空")
    try:
        if args.port:
            port = args.port
        else:
            from serial.tools import list_ports
            port = choose_port(list(list_ports.comports()))
        collect(port, args.output, args.writer, args.session, args.mode)
    except KeyboardInterrupt:
        print("\n已停止采集。")
    except (ModuleNotFoundError, ValueError, OSError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
