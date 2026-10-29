"""从 JSONL 文件按时间回放已确认的单字符识别事件。"""

from dataclasses import dataclass
import json
import math
from pathlib import Path


@dataclass(frozen=True)
class ReplayEvent:
    at: float
    char: str


def _unique_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    """拒绝重复键，避免同一行的时间或字符被静默覆盖。"""
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"重复 JSON 键: {key}")
        result[key] = value
    return result


def _reject_constant(value: str) -> None:
    raise ValueError(f"非法 JSON 数值: {value}")


def load_replay(path: Path) -> list[ReplayEvent]:
    """读取按时间排序的 JSONL；每行包含 at（秒）和 char（ASCII 字母数字）。"""
    # 这是离线交互事件格式，不是人工标注轨迹JSONL，也不是串口日志。
    events = []
    previous_at = -1.0
    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            item = json.loads(
                line, object_pairs_hook=_unique_keys, parse_constant=_reject_constant
            )
            if not isinstance(item, dict) or item.keys() != {"at", "char"}:
                raise ValueError("需要且仅需要 at 和 char 两个字段")

            at = item["at"]
            if isinstance(at, bool) or not isinstance(at, (int, float)):
                raise ValueError("at 必须是非负有限秒数")
            try:
                at = float(at)
            except OverflowError as exc:
                raise ValueError("at 必须是非负有限秒数") from exc
            if not math.isfinite(at) or at < 0:
                raise ValueError("at 必须是非负有限秒数")
            if at < previous_at:
                raise ValueError("事件时间不能倒退")

            char = item["char"]
            if not isinstance(char, str) or len(char) != 1 or not (
                "0" <= char <= "9" or "A" <= char <= "Z" or "a" <= char <= "z"
            ):
                raise ValueError("char 必须是单个 ASCII 字母或数字")
            events.append(ReplayEvent(at, char))
            previous_at = at
        except (json.JSONDecodeError, ValueError) as exc:
            raise ValueError(f"{path}:{line_no}: {exc}") from exc
    return events


class ReplaySource:
    """按累计运行时间逐次交付事件，每条事件只交付一次。"""

    def __init__(self, events: list[ReplayEvent]):
        self._events = tuple(events)
        self._next = 0

    def due(self, elapsed: float) -> list[str]:
        # 一帧可能跨过多个事件时刻，按原顺序全部交付；不能用帧率决定回放速度。
        ready = []
        while self._next < len(self._events) and self._events[self._next].at <= elapsed:
            ready.append(self._events[self._next].char)
            self._next += 1
        return ready
