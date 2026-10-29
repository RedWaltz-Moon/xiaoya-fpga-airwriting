"""共享V1字节流：保留轨迹/结果格式，增加有界文本转发与可查询状态。

仅负责帧与事务，不打开串口、不导入游戏/模型，也不包含E10私有指令。
"""

from __future__ import annotations

import struct
import math
from dataclasses import dataclass

SOF = b"\xa5\x5a"
# 公共帧：帧头2字节 + 版本/type/seq/count各1字节 + 小端长度2字节 + 载荷 + 小端CRC2字节。
# seq只关联一次请求/应答；打印任务另用32位job_id，不能混作书写累计计数。
TRAJECTORY, RESULT, PRINT, QUERY, STATUS = 0x01, 0x81, 0x82, 0x83, 0x02
MAX_TEXT = 512
PRINT_ENCODING = "gbk"
UNKNOWN, ACTIVE, SENT, BUSY, BAD_TEXT, ID_CONFLICT = range(6)
STATUS_NAMES = {UNKNOWN: "UNKNOWN", ACTIVE: "ACTIVE", SENT: "SENT",
                BUSY: "BUSY", BAD_TEXT: "BAD_TEXT", ID_CONFLICT: "ID_CONFLICT"}


def crc16(data):
    """与既有V1完全相同：FFFF/1021、不反射、不异或、低字节先发。"""
    crc = 0xFFFF
    for value in data:
        crc ^= value << 8
        for _ in range(8):
            crc = ((crc << 1) ^ (0x1021 if crc & 0x8000 else 0)) & 0xFFFF
    return crc


@dataclass(frozen=True)
class Frame:
    kind: int
    sequence: int
    count: int
    payload: bytes


def encode(kind, sequence, payload, count=1):
    if kind not in (TRAJECTORY, RESULT, PRINT, QUERY, STATUS):
        raise ValueError("未知帧类型")
    if not 0 <= sequence <= 255:
        raise ValueError("seq须为0..255")
    body = struct.pack("<BBBBH", 1, kind, sequence, count, len(payload)) + payload
    if not _valid_header(body):
        raise ValueError("帧类型、count或长度不匹配")
    # CRC覆盖版本至载荷，不含帧头，也不把CRC自身算入长度。
    return SOF + body + struct.pack("<H", crc16(body))


def _valid_header(header):
    version, kind, _, count, length = struct.unpack("<BBBBH", header[:6])
    return version == 1 and (
        (kind == TRAJECTORY and count == 64 and length == 128)
        or (kind == RESULT and count == 1 and length == 1)
        or (kind == PRINT and count == 1 and 5 <= length <= MAX_TEXT + 4)
        or (kind == QUERY and count == 1 and length == 4)
        or (kind == STATUS and count == 1 and length == 7))


class StreamParser:
    """一个入口拆分轨迹与状态；噪声/坏CRC逐字节重同步，缓存有界。

    外部负责无字节间隔超时后discard_pending，不将打印状态交给识别模型。
    """

    def __init__(self, allowed_types=None):
        self.buffer = bytearray()
        self.allowed_types = frozenset(allowed_types) if allowed_types is not None else None
        self.bad_crc_frames = self.bad_header_candidates = 0

    @property
    def has_pending_data(self):
        return bool(self.buffer)

    def discard_pending(self):
        length = len(self.buffer)
        self.buffer.clear()
        return length

    def feed(self, data):
        # 分字节处理，避免调用方一次传入超大噪声造成长期大缓存。
        frames = []
        for value in data:
            self.buffer.append(value)
            while self.buffer:
                at = self.buffer.find(SOF)
                if at < 0:
                    # 保留尾部单个A5，允许下一次read从5A继续拼成完整帧头。
                    self.buffer[:] = self.buffer[-1:] if self.buffer[-1:] == SOF[:1] else b""
                    break
                del self.buffer[:at]
                if len(self.buffer) < 8:
                    break
                if (not _valid_header(self.buffer[2:8]) or
                        (self.allowed_types is not None and self.buffer[3] not in self.allowed_types)):
                    self.bad_header_candidates += 1
                    del self.buffer[0]
                    continue
                length = int.from_bytes(self.buffer[6:8], "little")
                total = length + 10
                if len(self.buffer) < total:
                    break
                raw = bytes(self.buffer[:total])
                if crc16(raw[2:-2]) != int.from_bytes(raw[-2:], "little"):
                    # 只滑过一个字节继续找头，避免连同损坏帧后的合法帧一起丢掉。
                    self.bad_crc_frames += 1
                    del self.buffer[0]
                    continue
                frames.append(Frame(raw[3], raw[4], raw[5], raw[8:-2]))
                del self.buffer[:total]
        return frames


def text_bytes(text):
    """E10文本固定GBK，严格编码不替换丢字；仍禁止ESC及任意打印控制命令。"""
    if not isinstance(text, str):
        raise ValueError("打印内容须为字符串")
    try:
        payload = text.encode(PRINT_ENCODING)
    except UnicodeEncodeError as error:
        raise ValueError("打印内容含GBK字库不支持的字符，请移除表情或特殊字符") from error
    if not 1 <= len(payload) <= MAX_TEXT:
        raise ValueError(f"文本长度须为1..{MAX_TEXT}字节")
    # 严格编码保证汉字双字节完整，但ASCII控制字符仍可编码，必须另外过滤。
    # 仅放行TAB/CR/LF，避免正文夹带ESC、NUL、DEL等设备控制字节。
    if any((b < 32 and b not in (9, 10, 13)) or b == 127 for b in payload):
        raise ValueError("文本只允许GBK中文、可见ASCII、TAB、CR、LF")
    return payload


def _job_id(job_id):
    if type(job_id) is not int or not 1 <= job_id <= 0xFFFFFFFF:
        raise ValueError("任务编号须为1..4294967295，不使用轨迹seq代替")
    return struct.pack("<I", job_id)


def print_frame(sequence, job_id, text):
    return encode(PRINT, sequence, _job_id(job_id) + text_bytes(text))


def query_frame(sequence, job_id):
    return encode(QUERY, sequence, _job_id(job_id))


@dataclass(frozen=True)
class PrintStatus:
    job_id: int
    state: int
    length: int

    @property
    def name(self):
        return STATUS_NAMES[self.state]


def parse_status(frame):
    if frame.kind != STATUS:
        raise ValueError("不是打印状态帧")
    job_id, state, length = struct.unpack("<IBH", frame.payload)
    if job_id == 0 or state not in STATUS_NAMES or length > MAX_TEXT:
        raise ValueError("打印状态内容无效")
    if state in (UNKNOWN, BUSY, BAD_TEXT, ID_CONFLICT) and length != 0:
        raise ValueError("拒绝/未知状态不应声明已接收文本长度")
    return PrintStatus(job_id, state, length)


class PrintTransaction:
    """一次只允许一个任务。发送请求仅一次，丢应答只查询，绝不自动重印。

    所有方法由串口所属线程调用；前台线程通过队列请求，不能直接写串口。
    SENT仅表示转发UART最后停止位完成，不表示E10已经出纸。
    """

    def __init__(self, job_id, text, now, *, timeout=5.0, sequence=0):
        self.job_id = job_id
        self.text = text
        self.length = len(text_bytes(text))
        _job_id(job_id)
        if not math.isfinite(timeout) or timeout <= 0:
            raise ValueError("超时须为有限正数")
        self.sequence = sequence
        self.deadline = now + timeout
        self.next_query = now + 0.25
        self.started = False
        self.state = "QUEUED"
        self.detail = ""
        self.finished = False
        # 仅接受本事务实际发出过的seq；新任务使用新的32位job_id。
        self.sequences = set()

    def poll(self, now):
        if self.finished:
            return None
        if now >= self.deadline:
            self.abort("TIMEOUT_UNKNOWN", "无法确认是否已转发，请核对PC输出；不要自动重发")
            return None
        if not self.started:
            # 提交帧只生成一次；之后即使丢应答，也只查询而不重发正文。
            self.started = True
            self.state = "WAITING"
            packet = print_frame(self.sequence, self.job_id, self.text)
        elif now >= self.next_query:
            self.sequence = (self.sequence + 1) & 255
            self.next_query = now + .25
            packet = query_frame(self.sequence, self.job_id)
        else:
            return None
        self.sequences.add(self.sequence)
        return packet

    def accept(self, frame):
        # 同时匹配本事务发出的seq和job_id，隔离迟到应答；SENT不是纸张完成反馈。
        if self.finished or frame.kind != STATUS or frame.sequence not in self.sequences:
            return False
        status = parse_status(frame)
        if status.job_id != self.job_id:
            return False
        if status.state in (ACTIVE, SENT) and status.length != self.length:
            self.abort("PROTOCOL_ERROR", "设备接收长度与当前任务不一致")
        elif status.state == ACTIVE:
            self.state = "ACTIVE"
        elif status.state == SENT:
            self.abort("SENT", "FPGA转发UART发送完成，尚未证明实际出纸")
        else:
            self.abort(status.name, "未完成当前任务；不自动重发")
        return True

    def abort(self, state, detail):
        self.state, self.detail, self.finished = state, detail, True
