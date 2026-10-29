"""汇总与逐次档案：答题/结束时原子保存，不自动清理用户文件。"""

import json
import math
import os
import tempfile
from collections import Counter
from copy import deepcopy
from datetime import datetime
from pathlib import Path

from .core import WORD_MEANINGS, MAX_WORD_LENGTH


def _empty_record():
    # 汇总和单次明细共用v2文件；课程键属于存档格式，不能随界面名称变动。
    return dict(version=2, attempts=0, stars=0,
                completions=dict(numbers=0, boss=0, challenge=0),
                seen_digits={}, review_digits=[], seen_words={}, review_words=[], board_text="",
                summary=dict(sessions=0, elapsed_seconds=0.0, first_try=0, best_combo=0), sessions=[])


def _count(value):
    # bool也是int的子类，不能把true/false当作累计次数。
    return type(value) is int and value >= 0


def local_timestamp():
    """只读取主机本地时钟并保存时区；不联网校时，不把打印时间当学习时间。"""
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _number(value):
    if type(value) not in (int, float) or value < 0:
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def _character(value):
    return isinstance(value, str) and len(value) == 1 and value.isascii() and value.isalnum()


def _validate_session(record):
    fields = {"id", "lesson", "started_at", "ended_at", "status", "targets", "answers", "elapsed_seconds"}
    if not isinstance(record, dict) or set(record) != fields:
        raise ValueError("单次学习记录结构无效")
    if not _count(record["id"]) or record["id"] == 0 or record["lesson"] not in ("numbers", "boss", "challenge"):
        raise ValueError("学习记录编号或课程无效")
    if record["status"] not in ("in_progress", "completed", "stopped", "interrupted") or not _number(record["elapsed_seconds"]):
        raise ValueError("学习状态或用时无效")
    for key in ("started_at", "ended_at"):
        if not isinstance(record[key], str) or datetime.fromisoformat(record[key]).utcoffset() is None:
            raise ValueError("学习日期必须包含时区")
    targets = record["targets"]
    # 数字课程现在有10题；不按新课组总量裁剪旧档案，历史记录保留原成绩。
    if not isinstance(targets, list) or not 1 <= len(targets) <= 10 or any(
            not isinstance(item, str) or not 1 <= len(item) <= MAX_WORD_LENGTH or not all(_character(c) for c in item) for item in targets):
        raise ValueError("练习内容无效")
    if not isinstance(record["answers"], list):
        raise ValueError("答题明细无效")
    content, position = "".join(targets), 0
    # 重放已记录的判题结果校验位置：答错留在原位，答对才前进，不重新调用模型。
    for answer in record["answers"]:
        if not isinstance(answer, dict) or set(answer) != {"expected", "received", "correct", "position", "seconds"}:
            raise ValueError("答题明细结构无效")
        if not _count(answer["position"]) or answer["position"] != position or position >= len(content):
            raise ValueError("答题位置无效")
        if answer["expected"] != content[position] or not _character(answer["received"]) or type(answer["correct"]) is not bool:
            raise ValueError("答题字符或判定无效")
        if not _number(answer["seconds"]) or answer["seconds"] > record["elapsed_seconds"]:
            raise ValueError("答题用时无效")
        position += int(answer["correct"])
    if record["status"] == "completed" and position != len(content):
        raise ValueError("未完成记录不能标记通关")


def session_stats(record):
    """从已冻结的答题事件计算本次成绩，不引用累计分或当前模型重新判卷。"""
    answers = record["answers"]
    correct = sum(answer["correct"] for answer in answers)
    wrong_positions = {answer["position"] for answer in answers if not answer["correct"]}
    # 某位置只要出现过错误，其后重试成功也不算“首答正确”。
    clean = sum(answer["correct"] and answer["position"] not in wrong_positions for answer in answers)
    combo = best = 0
    mixups = Counter()
    review = []
    for answer in answers:
        combo = combo + 1 if answer["correct"] else 0
        best = max(best, combo)
        if not answer["correct"]:
            mixups[(answer["expected"], answer["received"])] += 1
            end = 0
            for item in record["targets"]:
                end += len(item)
                if answer["position"] < end:
                    if item not in review:
                        review.append(item)
                    break
    return dict(attempts=len(answers), correct=correct, retries=len(answers)-correct,
                goal=len("".join(record["targets"])), accuracy=100*correct/len(answers) if answers else 0,
                first_try=clean, best_combo=best, mixups=mixups, review=review)


def _validate(data):
    """拒绝未知结构和非法字符，损坏存档保留原件，不能静默覆盖。"""
    if not isinstance(data, dict) or type(data.get("version")) is not int or data["version"] != 2:
        raise ValueError("存档版本不兼容，请手动备份或删除 learning.json 后重启")
    expected = set(_empty_record())
    if set(data) != expected:
        raise ValueError("存档结构或版本不支持")
    if not all(_count(data[key]) for key in ("attempts", "stars")):
        raise ValueError("累计次数无效")
    completions = data["completions"]
    if not isinstance(completions, dict) or set(completions) != {"numbers", "boss", "challenge"} or not all(_count(n) for n in completions.values()):
        raise ValueError("通关记录无效")
    for key, allowed in (("seen_digits", set("0123456789")), ("seen_words", set(WORD_MEANINGS))):
        counts = data[key]
        if not isinstance(counts, dict) or not set(counts) <= allowed or not all(_count(n) for n in counts.values()):
            raise ValueError("练习覆盖记录无效")
    for key, allowed in (("review_digits", set("0123456789")), ("review_words", set(WORD_MEANINGS))):
        items = data[key]
        if not isinstance(items, list) or any(not isinstance(item, str) for item in items) or len(set(items)) != len(items) or not set(items) <= allowed:
            raise ValueError("复习记录无效")
    text = data["board_text"]
    if not isinstance(text, str) or len(text) > 120 or any(c not in " \n" and not (c.isascii() and c.isalnum()) for c in text):
        raise ValueError("拼词记录无效")
    if data["version"] == 2:
        summary = data["summary"]
        if not isinstance(summary, dict) or set(summary) != {"sessions", "elapsed_seconds", "first_try", "best_combo"} or not all(
                _count(summary[key]) for key in ("sessions", "first_try", "best_combo")) or not _number(summary["elapsed_seconds"]):
            raise ValueError("学习汇总无效")
        sessions = data["sessions"]
        if not isinstance(sessions, list):
            raise ValueError("学习历史无效")
        ids = set()
        for record in sessions:
            _validate_session(record)
            if record["id"] in ids:
                raise ValueError("学习记录编号重复")
            ids.add(record["id"])


class LearningArchive:
    """单进程单份本地档案；回放不读写真实成绩，I/O失败不阻断游戏。"""

    def __init__(self, path, enabled=True):
        self.path = Path(path)
        self.enabled = enabled
        self.error = ""
        self.data = _empty_record()
        if not enabled:
            return
        try:
            with self.path.open(encoding="utf-8") as stream:
                loaded = json.load(stream)
            _validate(loaded)
            self.data = loaded
            # 非正常退出只知道最后保存的一笔；保留原时间，不伪造退出时间。
            for record in self.data["sessions"]:
                if record["status"] == "in_progress":
                    record["status"] = "interrupted"
        except FileNotFoundError:
            pass
        except (OSError, ValueError, UnicodeError) as error:
            # 此次只保留内存进度；不要把损坏/未知版本原件替换成空档案。
            self.enabled = False
            self.error = str(error)

    def new_session(self, lesson, targets):
        """一次课组一个编号；无答题的空课组不落盘，编号不依赖FPGA的seq。"""
        stamp = local_timestamp()
        return dict(id=max((item["id"] for item in self.data["sessions"]), default=0)+1,
                    lesson=lesson, started_at=stamp, ended_at=stamp, status="in_progress",
                    targets=list(targets), answers=[], elapsed_seconds=0.0)

    def store_session(self, record):
        """以同一编号更新当前课组，通关/重画/重复打印不新增历史；保存独立深拷贝。"""
        _validate_session(record)
        if not record["answers"]:
            return
        records = self.data["sessions"]
        previous = None
        for index, existing in enumerate(records):
            if existing["id"] == record["id"]:
                previous = existing
                records[index] = deepcopy(record)
                break
        else:
            records.append(deepcopy(record))
        # 汇总增量更新并随档案保存；默认页面直接读汇总，不逐帧扫描全部答题历史。
        # 同编号记录会反复保存，因此用新旧差值累计，不能每次把整组成绩再加一遍。
        stats = session_stats(record)
        summary = self.data["summary"]
        summary["sessions"] += int(previous is None)
        summary["elapsed_seconds"] = round(summary["elapsed_seconds"] + record["elapsed_seconds"] -
                                           (previous["elapsed_seconds"] if previous else 0), 3)
        summary["first_try"] += stats["first_try"] - (session_stats(previous)["first_try"] if previous else 0)
        summary["best_combo"] = max(summary["best_combo"], stats["best_combo"])

    def save(self):
        """同目录临时文件+fsync+原子替换：写失败时旧档案保持完整。"""
        # 原子替换防止读到半份JSON；这是单进程文件存档，不提供多进程并发写锁。
        if not self.enabled:
            return False
        temporary = None
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=self.path.parent,
                                             prefix=".learning-", suffix=".tmp", delete=False) as stream:
                temporary = Path(stream.name)
                json.dump(self.data, stream, ensure_ascii=False, allow_nan=False, indent=2)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
            self.error = ""
            return True
        except (OSError, ValueError) as error:
            self.error = str(error)
            return False
        finally:
            # 只清理本次明确创建的临时文件，不删除旧档案或用户目录。
            if temporary is not None:
                try:
                    temporary.unlink(missing_ok=True)
                except OSError:
                    pass
