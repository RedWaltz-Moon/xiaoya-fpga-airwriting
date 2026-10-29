"""书写练习规则：分级字卡、无惩罚重试、有限课时；与显示和推理解耦。"""

import math
import random
from dataclasses import dataclass
from .vocabulary import SHORT_WORDS, LONG_WORDS, WORD_MEANINGS, MAX_WORD_LENGTH

CHARACTERS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
# 字母和混写课程按确认字符总数限制书写量，单个词仍受词库长度上限约束。
LESSON_CHARACTER_LIMIT = 20
# 类别顺序与模型一致；题目大小写容错只在匹配函数中处理，不重写输入字符。
DECKS = {
    "numbers": "0123456789",
    "upper": "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    "lower": "abcdefghijklmnopqrstuvwxyz",
    "mixed": CHARACTERS,
}
DEFAULT_BOSS_WORDS = ("CAT", "DOG", "SUN")


def characters_match(actual, target):
    """仅四组同形字母忽略大小写；不改输入，0/O及其他大小写仍严格。"""
    return actual == target or (actual in "CcSsOoZz" and actual.lower() == target.lower())


def plan_practice(deck, seed, seen, review, recent=(), count=10):
    """组内不重复；至多两题复习，其余优先非近期、练习次数少的字符。"""
    if deck not in DECKS:
        raise ValueError("未知练习字卡")
    rng = random.Random(seed)
    pool = list(DECKS[deck])
    rng.shuffle(pool)
    # 先打散再稳定排序，确保同次数字符无固定字母序偏向，并可复现。
    pool.sort(key=lambda char: (char in recent, seen.get(char, 0)))
    selected = [char for char in pool if char in review][:min(2, count)]
    fresh = [char for char in pool if char not in review and char not in selected]
    remainder = fresh + [char for char in pool if char in review and char not in selected]
    selected += remainder[:count-len(selected)]
    rng.shuffle(selected)
    return selected


def plan_words(seed, seen, review, recent=(), advanced=False, max_length=6,
               max_characters=LESSON_CHARACTER_LIMIT):
    """每组三词并均衡覆盖；进阶组仅第三词为长词，词长由通关进度控制。"""
    rng = random.Random(seed)
    pool = list(SHORT_WORDS)
    rng.shuffle(pool)
    pool.sort(key=lambda word: (word in recent, seen.get(word, 0)))
    # 至多复习一个短词，剩余位置补新词，避免困难题占满整组。
    selected = [word for word in pool if word in review][:1]
    fresh = [word for word in pool if word not in review and word not in selected]
    remainder = fresh + [word for word in pool if word in review and word not in selected]
    selected += remainder[: (2 if advanced else 3)-len(selected)]
    rng.shuffle(selected)
    if advanced:
        # 混写先为三个数字预留额度；整词选择而非截断词尾，保持释义和拼写对应。
        word_limit = min(max_length, max_characters - sum(map(len, selected)))
        long_pool = [word for word in LONG_WORDS if len(word) <= word_limit]
        rng.shuffle(long_pool)
        long_pool.sort(key=lambda word: (word not in review, word in recent, seen.get(word, 0)))
        selected.append(long_pool[0])
    return tuple(selected)


def _check_char(char):
    if not isinstance(char, str) or len(char) != 1 or char not in CHARACTERS:
        raise ValueError("char 必须是单个 ASCII 数字或英文字母")


def _check_dt(dt):
    if isinstance(dt, bool) or not isinstance(dt, (int, float)) or not math.isfinite(dt) or dt < 0:
        raise ValueError("dt 必须是非负有限秒数")


def _accept_event(game, event_id):
    """主机事件号单调递增；跨局保留高水位，拒绝重复和迟到事件。"""
    # 这是主机分配的事件号，不是会复位、回绕的FPGA八位seq。
    if event_id is None:
        return True
    if isinstance(event_id, bool) or not isinstance(event_id, int) or event_id < 0:
        raise ValueError("event_id 必须是非负整数或 None")
    if event_id <= game._last_event_id:
        return False
    game._last_event_id = event_id
    return True


@dataclass
class Target:
    char: str
    lane: int
    progress: float = 0.0


class FallingGame:
    """气球慢慢落到草地便停住等待；不因写得慢或写错扣分。"""

    def __init__(self, seed=None, deck="numbers", cards=None):
        if deck not in DECKS:
            raise ValueError("未知练习字卡")
        self.deck = deck
        self._random = random.Random(seed)
        self._last_event_id = -1
        self.goal = 10
        self.reset(cards)

    def reset(self, cards=None):
        # 只重置本组进度，保留事件号高水位，防止上一组的迟到输入落入新题。
        if cards is not None:
            cards = list(cards)
            if len(cards) != 10 or len(set(cards)) != 10 or any(c not in DECKS[self.deck] for c in cards):
                raise ValueError("课程必须含10个不重复的本类别字符")
        self.score = self.combo = self.completed = self.attempts = self.retries = 0
        self.status = "playing"
        # 每组抽取不重复字卡，避免同一字符反复出现而覆盖不足。
        self._cards = cards if cards is not None else self._random.sample(DECKS[self.deck], self.goal)
        self._spawn()

    def _spawn(self):
        self.target = Target(self._cards[self.completed], self._random.randrange(4))

    def tick(self, dt):
        _check_dt(dt)
        if self.status != "playing":
            return "none"
        old = self.target.progress
        # 落到终点后停住；动画时间不参与超时扣分或字符判定。
        self.target.progress = min(1.0, old + dt / 40.0)
        return "landed" if old < 1.0 and self.target.progress == 1.0 else "none"

    def submit(self, char, event_id=None):
        _check_char(char)
        if not _accept_event(self, event_id):
            return "duplicate"
        if self.status != "playing":
            return "ignored"
        self.attempts += 1
        if not characters_match(char, self.target.char):
            self.retries += 1
            self.combo = 0
            return "wrong"
        self.score += 1
        self.combo += 1
        self.completed += 1
        if self.completed == self.goal:
            self.status = "victory"
        else:
            self._spawn()
        return "correct"


class BossGame:
    """友好单词探险：逐字母拼词，仅四组同形字母允许大小写互换。"""

    # 类名供现有调用兼容；当前职责是逐字符单词练习，不包含战斗状态机。

    def __init__(self, words=DEFAULT_BOSS_WORDS):
        self.words = tuple(words)
        if not self.words or any(
            not isinstance(word, str) or not 1 <= len(word) <= MAX_WORD_LENGTH or any(c not in CHARACTERS for c in word)
            for word in self.words
        ):
            raise ValueError(f"words 必须是单项1..{MAX_WORD_LENGTH}字符的ASCII字母数字序列")
        self._last_event_id = -1
        self.goal = sum(map(len, self.words))
        if self.goal > LESSON_CHARACTER_LIMIT:
            raise ValueError(f"每组最多{LESSON_CHARACTER_LIMIT}个确认字符")
        self.reset()

    @property
    def word(self):
        return self.words[self.stage]

    def reset(self):
        self.score = self.combo = self.completed = self.attempts = self.retries = 0
        self.stage = self.index = 0
        self.status = "playing"

    def tick(self, dt):
        _check_dt(dt)
        return "none"

    def submit(self, char, event_id=None):
        _check_char(char)
        if not _accept_event(self, event_id):
            return "duplicate"
        if self.status != "playing":
            return "ignored"
        self.attempts += 1
        if not characters_match(char, self.word[self.index]):
            self.retries += 1
            self.combo = 0
            return "wrong"
        self.score += 1
        self.combo += 1
        self.completed += 1
        self.index += 1
        # 答对才推进字符；到词尾再换词，整组最后一个字符通过后才通关。
        if self.index == len(self.word):
            if self.stage == len(self.words) - 1:
                self.status = "victory"
            else:
                self.stage += 1
                self.index = 0
        return "correct"


class MixedGame(BossGame):
    """混写六轮：数字与完整单词交替，复用逐字符确认而非拼接模型输出。"""

    def __init__(self, seed=None, words=DEFAULT_BOSS_WORDS, digits=None):
        if digits is None:
            digits = random.Random(seed).sample(DECKS["numbers"], len(words))
        if len(words) != 3 or len(digits) != 3 or len(set(digits)) != 3 or any(
            not isinstance(d, str) or len(d) != 1 or d not in DECKS["numbers"] for d in digits
        ):
            raise ValueError("混写需要三个单词及三个不重复的单个数字")
        rounds = [item for pair in zip(digits, words) for item in pair]
        super().__init__(rounds)
