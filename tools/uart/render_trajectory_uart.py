#!/usr/bin/env python3
"""解析M4B UART十六进制文本并渲染64点轨迹。"""

from __future__ import annotations

import argparse
import math
import re
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw

from ..trajectory_collect.collect import crc16_ccitt


# 输入为串口工具导出的十六进制文本，不是采集JSONL或模型特征；输出只用于排错审阅。
@dataclass
class TrajectoryFrame:
    sequence: int
    points: list[tuple[int, int]]
    crc_received: int
    crc_calculated: int

    @property
    def crc_ok(self) -> bool:
        return self.crc_received == self.crc_calculated


def parse_hex_text(path: Path) -> bytes:
    text = path.read_text(encoding="utf-8-sig", errors="ignore")
    tokens = re.findall(r"(?i)(?<![0-9a-f])[0-9a-f]{2}(?![0-9a-f])", text)
    if not tokens:
        raise ValueError(f"{path} 中没有找到十六进制字节")
    return bytes(int(token, 16) for token in tokens)


def extract_frames(stream: bytes) -> list[TrajectoryFrame]:
    """按A5 5A帧头和小端payload长度搜帧，允许文本前后存在杂字节。"""
    frames: list[TrajectoryFrame] = []
    index = 0
    while index + 10 <= len(stream):
        if stream[index : index + 2] != bytes((0xA5, 0x5A)):
            index += 1
            continue

        payload_length = stream[index + 6] | (stream[index + 7] << 8)
        frame_length = 8 + payload_length + 2
        if index + frame_length > len(stream):
            break

        raw = stream[index : index + frame_length]
        point_count = raw[5]
        if raw[2] != 0x01 or raw[3] != 0x01 or payload_length != point_count * 2:
            index += 1
            continue

        payload = raw[8 : 8 + payload_length]
        points = list(zip(payload[0::2], payload[1::2]))
        crc_received = raw[-2] | (raw[-1] << 8)
        # 离线审阅保留CRC失败的完整候选并标红，不代表这些帧会被采集/推理入口接受。
        frames.append(
            TrajectoryFrame(
                sequence=raw[4],
                points=points,
                crc_received=crc_received,
                crc_calculated=crc16_ccitt(raw[2:-2]),
            )
        )
        index += frame_length
    return frames


def draw_frame(frame: TrajectoryFrame, panel_size: int = 440) -> Image.Image:
    image = Image.new("RGB", (panel_size, panel_size + 54), "white")
    draw = ImageDraw.Draw(image)
    margin = 34
    plot_size = panel_size - 2 * margin

    # FPGA坐标原点位于画面左上角，因此Y轴保持向下，显示方向与实际书写一致。
    def screen(point: tuple[int, int]) -> tuple[int, int]:
        x, y = point
        return (
            margin + round(x * plot_size / 255),
            margin + round(y * plot_size / 255),
        )

    draw.rectangle(
        (margin, margin, margin + plot_size, margin + plot_size),
        outline=(190, 190, 190),
        width=1,
    )
    # V1只有按时间排序的64点，无独立抬笔标志；连线展示协议点序，不重建断笔信息。
    mapped = [screen(point) for point in frame.points]
    segment_count = max(1, len(mapped) - 1)
    for i, (start, end) in enumerate(zip(mapped, mapped[1:])):
        # 蓝色到橙色表示采样时间由早到晚，便于观察回绕、跳点和书写方向。
        ratio = i / segment_count
        color = (
            round(35 + 220 * ratio),
            round(105 + 25 * ratio),
            round(225 - 155 * ratio),
        )
        draw.line((start, end), fill=color, width=4)
    for x, y in mapped:
        draw.ellipse((x - 2, y - 2, x + 2, y + 2), fill=(35, 35, 35))
    if mapped:
        sx, sy = mapped[0]
        ex, ey = mapped[-1]
        draw.ellipse((sx - 6, sy - 6, sx + 6, sy + 6), fill=(0, 180, 60))
        draw.ellipse((ex - 6, ey - 6, ex + 6, ey + 6), fill=(220, 35, 35))

    status = "PASS" if frame.crc_ok else "FAIL"
    title = (
        f"SEQ={frame.sequence}  POINTS={len(frame.points)}  "
        f"CRC={frame.crc_received:04X}/{frame.crc_calculated:04X} {status}"
    )
    draw.text((margin, panel_size + 8), title, fill=(0, 120, 0) if frame.crc_ok else (200, 0, 0))
    draw.text((margin, panel_size + 28), "green=start  red=end  blue->orange=time", fill=(70, 70, 70))
    return image


def render_sheet(frames: list[TrajectoryFrame], output: Path) -> None:
    columns = min(3, len(frames))
    rows = math.ceil(len(frames) / columns)
    panel_width, panel_height = 440, 494
    sheet = Image.new("RGB", (columns * panel_width, rows * panel_height), (235, 235, 235))
    for index, frame in enumerate(frames):
        panel = draw_frame(frame, panel_width)
        sheet.paste(panel, ((index % columns) * panel_width, (index // columns) * panel_height))
    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output)


def main() -> None:
    parser = argparse.ArgumentParser(description="渲染M4B UART V1轨迹帧")
    # 不再内置历史示例，输入必须明确指定；默认PNG与输入放一起，避免源码目录产生杂项。
    parser.add_argument("input", type=Path, help="串口接收的十六进制轨迹文本")
    parser.add_argument("-o", "--output", type=Path, help="可选PNG路径；默认输入同目录的*_trajectory.png")
    args = parser.parse_args()
    output = args.output or args.input.with_name(args.input.stem + "_trajectory.png")

    stream = parse_hex_text(args.input)
    frames = extract_frames(stream)
    if not frames:
        raise SystemExit("未找到完整且格式正确的M4B V1轨迹帧")

    render_sheet(frames, output)
    for frame in frames:
        xs = [point[0] for point in frame.points]
        ys = [point[1] for point in frame.points]
        print(
            f"SEQ={frame.sequence} points={len(frame.points)} "
            f"x={min(xs)}..{max(xs)} y={min(ys)}..{max(ys)} "
            f"CRC={'PASS' if frame.crc_ok else 'FAIL'}"
        )
    print(f"已生成: {output.resolve()}")


if __name__ == "__main__":
    main()
