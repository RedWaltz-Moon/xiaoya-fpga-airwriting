#!/usr/bin/env python3
"""生成M4D单字符识别结果帧，输出可直接粘贴到十六进制串口工具的数据。"""

import argparse

from ..trajectory_collect.collect import build_frame, crc16_ccitt


# 只生成十六进制文本，不打开串口；seq须取当前上行帧第5字节，不能固定填0。
def parse_byte(value: str) -> int:
    number = int(value, 0)
    if not 0 <= number <= 0xFF:
        raise argparse.ArgumentTypeError("序号必须在0..255之间")
    return number


def main() -> None:
    parser = argparse.ArgumentParser(
        description="生成M4D V1结果帧；sequence取FPGA上行轨迹帧第5个字节(seq)。"
    )
    parser.add_argument("sequence", type=parse_byte, help="轨迹序号，如0、15或0x0F")
    parser.add_argument("result", help="单个识别结果：0-9、A-Z或a-z")
    args = parser.parse_args()

    try:
        frame = build_frame(args.sequence, args.result)
    except ValueError as error:
        parser.error(str(error))
    print(" ".join(f"{value:02X}" for value in frame))


if __name__ == "__main__":
    main()
