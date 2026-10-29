"""空中书写乐园：PEN/HAND轨迹共用现有模型；摄像头监看由FPGA负责。"""

from __future__ import annotations

import argparse
import math
import os
import queue
import random
import sys
import textwrap
import time
from datetime import datetime
from pathlib import Path

from .core import BossGame, FallingGame, MixedGame, DECKS, DEFAULT_BOSS_WORDS, WORD_MEANINGS, MAX_WORD_LENGTH, LESSON_CHARACTER_LIMIT, plan_practice, plan_words
from .replay import ReplaySource, load_replay
from .rendering import NativeDraw
from .learning import LearningArchive, local_timestamp, session_stats
from .serial_protocol import PRINT_ENCODING, MAX_TEXT, text_bytes

# 布局和点击检测统一使用逻辑坐标；输出分辨率由render_scale与视口缩放决定。
WIDTH, HEIGHT = 1280, 720
CREAM = (250, 247, 237)
INK = (39, 68, 59)
MUTED = (100, 119, 106)
GREEN = (48, 112, 84)
MINT = (221, 236, 216)
ORANGE = (225, 119, 69)
PEACH = (250, 224, 203)
YELLOW = (247, 195, 81)
BLUE = (222, 237, 242)
WHITE = (255, 254, 248)
LINE = (220, 224, 207)
RECEIPT_COLUMNS = 32
RECEIPT_PAGE_LINES = 24


def _ascii_input(value):
    return isinstance(value, str) and len(value) == 1 and value.isascii() and value.isalnum()


def _receipt_width(text):
    """12点西文字库/24点汉字库下，GBK编码字节数对应实际显示列数。"""
    return len(text.encode(PRINT_ENCODING))


def _receipt_center(text):
    """只补左侧空格居中，不能用按Unicode字符数计算的str.center。"""
    return " " * max(0, (RECEIPT_COLUMNS-_receipt_width(text))//2) + text


def _receipt(lines, *, compact_separators=False):
    """窄纸GBK排版：最多32西文列/16汉字，换行不截断双字节字符。

    不丢弃黑板空格/空行；超长单词按列断开。预览与UART使用同一文本，
    保留512字节门禁，末尾留三行供手动撕纸，实际进纸长度以打印机为准。
    """
    # 此处保持自然阅读行序；E10的倒序补偿只在发送出口执行，不改预览内容。
    rows = []
    for line in lines:
        # 固定展开TAB，避免打印机的可配置制表位使预览与纸面宽度不同。
        remaining = line.expandtabs(4)
        if not remaining:
            rows.append("")
        while remaining:
            columns = cut = 0
            for char in remaining:
                width = _receipt_width(char)
                if columns + width > RECEIPT_COLUMNS:
                    break
                columns += width
                cut += 1
            if cut < len(remaining):
                # 优先在已容纳的空格后换行，保留原文且尽量不拆英文单词。
                boundary = remaining.rfind(" ", 0, cut)
                if boundary > 0 and remaining[:boundary].strip():
                    cut = boundary + 1
            rows.append(remaining[:cut])
            remaining = remaining[cut:]
    message = "\r\n".join(rows) + "\r\n\r\n\r\n\r\n"
    # 长词的待复习项可能挤满整单；仅学习小票超限时缩短装饰分隔线，正文和日期不截断。
    # 黑板保持原样，不能把使用者自己写的横线当作可删装饰。
    if compact_separators and len(message.encode(PRINT_ENCODING)) > MAX_TEXT:
        rows = ["-"*12 if row == "-"*RECEIPT_COLUMNS else row for row in rows]
        message = "\r\n".join(rows) + "\r\n\r\n\r\n\r\n"
    # 32列是每行排版限制，512字节是整单协议限制，换行和撕纸空行也计入后者。
    text_bytes(message)
    return message


def board_receipt(text, *, chinese=True):
    """按当前界面语言冻结黑板小票；正文原样保留，日期取本次生成时间。"""
    if not isinstance(text, str) or not text.strip():
        raise ValueError("黑板没有可打印内容")
    text_bytes(text)
    body = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    return _receipt([_receipt_center("小芽自由书写" if chinese else "FREE WRITING"),
                     "-"*RECEIPT_COLUMNS, ("打印：" if chinese else "Printed ") + local_timestamp().replace("T", " "),
                     "-"*RECEIPT_COLUMNS, *body, "-"*RECEIPT_COLUMNS])


def lesson_receipt(record, *, chinese=True):
    """小票标题随界面语言，一票只取一条已归档练习及其原学习时间。"""
    if not record or not record["answers"] or record["status"] not in ("completed", "stopped", "interrupted"):
        raise ValueError("请先结束练习，再选择一条学习记录")
    stats = session_stats(record)
    seconds = int(record["elapsed_seconds"])
    # 英文小票仍经同一个GBK链路发送；ASCII字节不变，不需要切换打印机字库。
    if not chinese:
        name = {"numbers": "NUMBERS", "boss": "WORDS", "challenge": "MIXED"}[record["lesson"]]
        state = {"completed": "COMPLETE", "stopped": "UNFINISHED", "interrupted": "INTERRUPTED"}[record["status"]]
        mixups = [f"{a}>{b}x{count}" for (a, b), count in stats["mixups"].most_common(4)]
        if len(stats["mixups"]) > 4:
            mixups.append(f"+{len(stats['mixups'])-4} types")
        return _receipt([_receipt_center("LEARNING RECORD"),
                         "-"*RECEIPT_COLUMNS,
                         f"No. {record['id']:06d} | {name}",
                         "Start " + record["started_at"].replace("T", " "),
                         ("Saved " if record["status"] == "interrupted" else "End   ") + record["ended_at"].replace("T", " "),
                         state, "-"*RECEIPT_COLUMNS,
                         f"Score {stats['correct']}/{stats['goal']} | Accuracy {stats['accuracy']:.1f}%",
                         f"Answers {stats['attempts']} | Retry {stats['retries']}",
                         f"First try {stats['first_try']} | Best run {stats['best_combo']}",
                         f"Active {seconds//60}m {seconds%60:02d}s",
                         "-"*RECEIPT_COLUMNS,
                         "Practice: " + " ".join(record["targets"]),
                         "Review: " + (", ".join(stats["review"]) or "None"),
                         "Mixups: " + ("; ".join(mixups) or "None"),
                         "-"*RECEIPT_COLUMNS], compact_separators=True)
    name = {"numbers": "数字练习", "boss": "单词练习", "challenge": "混写挑战"}[record["lesson"]]
    state = {"completed": "已完成", "stopped": "未完成", "interrupted": "意外中断"}[record["status"]]
    mixups = [f"{a}>{b}({count}次)" for (a, b), count in stats["mixups"].most_common(4)]
    if len(stats["mixups"]) > 4:
        mixups.append(f"另{len(stats['mixups'])-4}类")
    end_label = "存档：" if record["status"] == "interrupted" else "结束："
    return _receipt([_receipt_center("小芽学习记录"),
                     "-"*RECEIPT_COLUMNS,
                     f"编号：{record['id']:06d} | {name}",
                     "开始：" + record["started_at"].replace("T", " "),
                     end_label + record["ended_at"].replace("T", " "),
                     state, "-"*RECEIPT_COLUMNS,
                     f"完成：{stats['correct']}/{stats['goal']}  正确率：{stats['accuracy']:.1f}%",
                     f"作答：{stats['attempts']}次  重试：{stats['retries']}次",
                     f"首答正确：{stats['first_try']}  最长连对：{stats['best_combo']}",
                     f"有效练习：{seconds//60}分{seconds%60:02d}秒",
                     "-"*RECEIPT_COLUMNS,
                     "练习：" + " ".join(record["targets"]),
                     "待复习：" + (", ".join(stats["review"]) or "无"),
                     "易混淆：" + ("; ".join(mixups) or "无"),
                     "-"*RECEIPT_COLUMNS], compact_separators=True)


def resolve_font(explicit=None):
    """只读取具体字体文件，绝不调用会触发Windows注册表异常的SysFont。"""
    if explicit:
        path = Path(explicit)
        if not path.is_file():
            raise ValueError(f"字体不存在：{path}")
        return str(path)
    candidates = [
        Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts/msyh.ttc",
        Path("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"),
        Path("/usr/share/fonts/truetype/wqy/wqy-microhei.ttc"),
        Path("/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc"),
    ]
    return next((str(p) for p in candidates if p.is_file()), None)


class ArcadeApp:
    """输入、课程与绘画分离；按钮坐标始终使用1280×720逻辑画布。"""

    def __init__(self, pygame, args):
        self.pg, self.args = pygame, args
        pygame.display.init()
        pygame.font.init()
        pygame.display.set_caption("Little Sprout | 空中书写乐园")
        sizes = pygame.display.get_desktop_sizes()
        if args.windowed:
            self.screen = pygame.display.set_mode((WIDTH, HEIGHT), pygame.RESIZABLE)
        else:
            if not 0 <= args.display < len(sizes):
                raise ValueError("无效的显示器编号")
            self.screen = pygame.display.set_mode(sizes[args.display], pygame.FULLSCREEN, display=args.display)
        # 保留布局单位，字体/图元直接在高分辨率画布原生绘制。
        render_height = getattr(args, "render_height", 1080)
        if render_height not in (720, 1080):
            raise ValueError("渲染高度只支持720或1080")
        self.render_scale = render_height / HEIGHT
        self.render_size = (round(WIDTH*self.render_scale), render_height)
        self.canvas = pygame.Surface(self.render_size)
        self.draw = NativeDraw(pygame, self.render_scale)
        self.font_path = resolve_font(getattr(args, "font", None))
        # 没有中文字体时完整切换英文文案，避免香橙派上出现方框乱码。
        self.chinese = self.font_path is not None
        self.fonts, self.text_cache = {}, {}
        self.clock = pygame.time.Clock()
        self.running, self.paused = True, False
        self.mode = self.game = None
        self.deck = getattr(args, "deck", "numbers")
        self.elapsed = 0.0
        # 游戏时间会在引导/暂停时停住；uptime始终运行，供导航回放与首次引导计时使用。
        self.uptime = 0.0
        self.intro_until = 0.0
        self.introduced_lessons = set()
        # 解锁仍只认完整课程通关；后面从本地档案恢复，星数/中途退出不算。
        self.completed_lessons = set()
        self.menu_notice = ""
        self.menu_notice_until = 0.0
        self.return_armed_until = 0.0
        # 后台只投递识别事件；页面、课程和档案由pygame主线程统一更新。
        self.character_queue = queue.Queue(maxsize=32)
        self.last_host_event_id = -1
        self.next_event_id = 0
        self.feedback, self.last_char = "", ""
        self.feedback_until = 0.0
        self.buttons = []
        self.focus = 0
        self.hint = False
        self.intro = False
        self.lesson_number = 0
        self.session_stars = 0
        self.celebration = 0.0
        self.success_label = ""
        self.keyboard_focus = False
        # 复习集合稍后从档案恢复；回放独立，不混入真实累计成绩。
        self.seen = {deck: {} for deck in DECKS}
        self.review = {deck: set() for deck in DECKS}
        self.word_review = set()
        self.word_seen = {}
        self.recent_words = ()
        self.recent_digits = ()
        self.lesson_wins = {"boss": 0, "challenge": 0}
        # 普通启动真正随机；显式seed可复现，演示回放默认仍为7。
        self.practice_seed = args.seed if args.seed is not None else random.SystemRandom().randrange(2**32)
        self.reviewing = set()
        self.round_mistakes = set()
        self.mismatch = False
        self.leave_prompt = False
        self.celebration_duration = 1.6
        self.replay_events = load_replay(args.replay) if args.replay else None
        self.replay = ReplaySource(self.replay_events) if self.replay_events is not None else None
        self.archive = LearningArchive(getattr(args, "profile", Path(__file__).resolve().parent.parent / "user_data/learning.json"),
                                       enabled=self.replay_events is None)
        saved = self.archive.data
        self.completed_lessons = {lesson for lesson, count in saved["completions"].items() if count}
        self.seen["numbers"] = dict(saved["seen_digits"])
        self.review["numbers"] = set(saved["review_digits"])
        self.word_seen = dict(saved["seen_words"])
        self.word_review = set(saved["review_words"])
        self.lesson_wins = {lesson: saved["completions"][lesson] for lesson in self.lesson_wins}
        self.board_text = saved["board_text"]
        self.board_tools = self.board_clear_confirm = False
        self.lesson_record = None
        self.history_open = False
        self.history_page = 0
        self.history_selected_id = None
        self.live = None
        self.live_port = getattr(args, "port", None)
        self.input_status = None
        self.input_notice = ""
        self.input_notice_until = 0.0
        self.last_input = None
        # 打印是显式确认的独立事务，不进入题目计分；快照在打开确认页时冻结。
        self.print_dialog = None
        self.print_job_id = 0
        self.print_state = ""
        self.print_notice = ""
        self.print_notice_until = 0.0
        if args.mode:
            self.start_mode(args.mode)

    def tr(self, chinese, english):
        return chinese if self.chinese else english

    def _font(self, size, bold=False):
        key = size, bold
        if key not in self.fonts:
            path = self.font_path
            if bold and path:
                source = Path(path)
                # SDL_ttf对部分CJK字体合成粗体会挤叠字形；只用已有真粗体，不下载。
                name = "msyhbd.ttc" if source.name.lower() == "msyh.ttc" else source.name.replace("Regular", "Bold")
                candidate = source.with_name(name)
                if candidate.is_file():
                    path = str(candidate)
            font = self.pg.font.Font(path, max(1, round(size*self.render_scale)))
            # 找不到中文真粗体时保留清晰的常规字重，英文默认字体可合成粗体。
            font.set_bold(bold and self.font_path is None)
            self.fonts[key] = font
        return self.fonts[key]

    def _text(self, value, x, y, size=24, color=INK, align="left", bold=False, *, max_width=None):
        # 长词/释义按实际字体宽度缩小；最低字号仍放不下时才省略，避免盖住其他面板。
        # 未传宽度的旧调用保持原字号和绘制位置。
        if max_width is not None:
            limit = round(max_width * self.render_scale)
            while size > 14 and self._font(size, bold).size(value)[0] > limit:
                size -= 1
            if self._font(size, bold).size(value)[0] > limit:
                while value and self._font(size, bold).size(value + "…")[0] > limit:
                    value = value[:-1]
                value += "…"
        key = value, size, color, bold
        if key not in self.text_cache:
            if len(self.text_cache) > 350:
                self.text_cache.clear()
            self.text_cache[key] = self._font(size, bold).render(value, True, color)
        surface = self.text_cache[key]
        rect = surface.get_rect()
        x, y = self.draw.point((x, y))
        if align == "center":
            rect.midtop = (x, y)
        elif align == "right":
            rect.topright = (x, y)
        else:
            rect.topleft = (x, y)
        self.canvas.blit(surface, rect)

    def _panel(self, rect, fill=WHITE, radius=25, shadow=True):
        pg = self.pg
        if shadow:
            self.draw.rect(self.canvas, (231, 229, 216), pg.Rect(rect).move(0, 5), border_radius=radius)
        self.draw.rect(self.canvas, fill, rect, border_radius=radius)

    def _button(self, rect, label, action, fill=GREEN, color=WHITE):
        # 悬停只改变亮度，不改变位置，避免孩子追着移动的按钮点击。
        if self.pg.Rect(rect).collidepoint(self._logical_pos(self.pg.mouse.get_pos())):
            fill = tuple(min(255, c + 12) for c in fill)
        self._panel(rect, fill, 16, False)
        self._text(label, rect[0] + rect[2] // 2, rect[1] + (rect[3] - self._font(20).get_height() / self.render_scale) // 2,
                   20, color, "center", True)
        self.buttons.append((self.pg.Rect(rect), action))

    def _star(self, x, y, radius=14, color=YELLOW):
        points = []
        for i in range(10):
            a = -math.pi / 2 + i * math.pi / 5
            r = radius if i % 2 == 0 else radius * .47
            points.append((x + math.cos(a) * r, y + math.sin(a) * r))
        self.draw.polygon(self.canvas, color, points)

    def _cloud(self, x, y, scale=1):
        for dx, dy, r in ((0, 0, 22), (25, -12, 30), (55, 0, 22)):
            self.draw.circle(self.canvas, WHITE, (int(x + dx * scale), int(y + dy * scale)), int(r * scale))

    def _animal(self, x, y, scale=1, kind="bear"):
        """原创几何插画：同一套脸部语言用于引导伙伴和具象单词提示。"""
        pg = self.pg
        def circle(color, dx, dy, radius):
            self.draw.circle(self.canvas, color, (round(x + dx * scale), round(y + dy * scale)), round(radius * scale))
        fur = (206, 148, 93) if kind == "bear" else (238, 170, 99)
        if kind == "dog":
            fur = (194, 139, 90)
        if kind == "sun":
            for i in range(12):
                a = i * math.pi / 6
                self.draw.line(self.canvas, YELLOW,
                             (x + math.cos(a) * 65 * scale, y + math.sin(a) * 65 * scale),
                             (x + math.cos(a) * 79 * scale, y + math.sin(a) * 79 * scale), max(2, round(7 * scale)))
            fur = YELLOW
        elif kind == "cat":
            for sign in (-1, 1):
                self.draw.polygon(self.canvas, fur, [(x + sign * 50 * scale, y - 20 * scale),
                    (x + sign * 48 * scale, y - 77 * scale), (x + sign * 6 * scale, y - 43 * scale)])
        else:
            for sign in (-1, 1):
                circle(fur, sign * 43, -43, 25 if kind == "bear" else 30)
                circle(PEACH, sign * 43, -43, 13)
        circle(fur, 0, 0, 60)
        circle((254, 226, 183), 0, 24, 32)
        for sign in (-1, 1):
            circle(INK, sign * 21, -5, 5)
            circle(PEACH, sign * 37, 16, 10)
        circle(INK, 0, 14, 7)
        self.draw.arc(self.canvas, INK, (x - 15 * scale, y + 15 * scale, 30 * scale, 21 * scale),
                    math.pi, math.pi * 2, max(2, round(3 * scale)))

    def _background(self):
        self.canvas.fill(CREAM)
        pg = self.pg
        self.draw.ellipse(self.canvas, (231, 237, 218), (-120, 646, 900, 200))
        self.draw.ellipse(self.canvas, (222, 234, 211), (630, 656, 800, 160))
        for x in (35, 1215):
            self.draw.line(self.canvas, GREEN, (x, 677), (x, 645), 3)
            self.draw.ellipse(self.canvas, GREEN, (x, 647, 17, 9))
            self.draw.ellipse(self.canvas, GREEN, (x - 17, 657, 17, 9))

    def _header(self, section=None):
        pg = self.pg
        self.draw.circle(self.canvas, GREEN, (63, 46), 21)
        self.draw.ellipse(self.canvas, MINT, (50, 33, 12, 18))
        self.draw.ellipse(self.canvas, MINT, (63, 30, 12, 18))
        self.draw.line(self.canvas, MINT, (63, 43), (63, 58), 3)
        self._text(self.tr("小芽 · 空中书写乐园", "LITTLE SPROUT"), 98, 25, 26, GREEN, bold=True)
        self._text("PLAY  /  WRITE  /  GROW", 100, 60, 11, MUTED)
        if section:
            self._text(section, 640, 35, 22, GREEN, "center", True)
            self._button((966, 23, 112, 46), self.tr("暂停", "Pause"), "pause", MINT, GREEN)
            self._button((1094, 23, 134, 46), self.tr("回到乐园", "Home"), "leave", WHITE, GREEN)
        else:
            self._panel((1008, 25, 220, 40), MINT, 20, False)
            label = self.tr(f"累计收集  {self.archive.data['stars']}  颗星星", f"Total: {self.archive.data['stars']} stars")
            self._text(label, 1118, 33, 15, GREEN, "center")

    def _draw_menu(self):
        self._header()
        self._panel((52, 104, 1176, 230), MINT, 32, False)
        # 游戏不区分书写来源；首页与操作文案不绑定笔头、手势或物理按键。
        invitation = self.tr("准备好了吗，", "Ready to write?")
        self._text(invitation, 88, 127, 41, GREEN, bold=True)
        self._text(self.tr("让数字和单词开出花。", "Let learning bloom."), 88, 184, 40, GREEN, bold=True)
        self._text(self.tr("选一个小冒险 · 看一看，写一写，再试一次", "Choose an adventure. Look, write, and try again."),
                   90, 264, 19, MUTED)
        # 右侧插画与主标题保持独立区域，避免装饰压到教学内容。
        self._cloud(826, 153, .8)
        self._cloud(1110, 151, .65)
        self.draw.ellipse(self.canvas, (197, 216, 178), (756, 273, 430, 60))
        if self.live_port:
            self._panel((816, 123, 368, 193), WHITE, 24, False)
            self._text(self.tr("我的空中笔迹", "My air writing"), 1000, 138, 20, GREEN, "center", True)
            self._draw_last_input((837, 178, 123, 117), (1070, 193))
        else:
            self._animal(1000, 226, 1.2)
            for x, y, char, color in ((817, 230, "a", PEACH), (1126, 230, "3", YELLOW)):
                self._panel((x - 38, y - 37, 76, 84), color, 19, False)
                self._text(char, x, y - 40, 55, GREEN, "center", True)
        self._star(1168, 195, 13)
        self._star(916, 130, 10)
        cards = [
            ("numbers", "123", "数字练习", "Numbers", "认识 0–9 · 每组十题", "Meet 0–9 · ten cards", BLUE),
            ("boss", "Cat", "单词练习", "Words", "每组三词 · 20字母以内", "Three words · up to 20 letters", MINT),
            ("challenge", "3 + Cat", "混写挑战", "Mixed challenge", "数字与单词交替闯关", "Numbers and words together", PEACH),
        ]
        for i, (action, mark, cn, en, hint, ehint, tint) in enumerate(cards):
            x = 52 + i * 398
            locked = action == "challenge" and not self.challenge_unlocked
            self._panel((x, 365, 380, 246))
            self._panel((x + 18, 383, 344, 82), LINE if locked else tint, 18, False)
            self._text(mark, x + 190, 387, 45, MUTED if locked else GREEN, "center", True)
            self._text(self.tr(cn, en), x + 22, 479, 24, INK, bold=True)
            if action == "challenge":
                # 两个独立勋章明确告知还缺哪门课程，不能靠反复刷星星解锁。
                hint = "数字" + ("已通关" if "numbers" in self.completed_lessons else "待通关")
                hint += " · 单词" + ("已通关" if "boss" in self.completed_lessons else "待通关")
                ehint = "Numbers " + ("done" if "numbers" in self.completed_lessons else "needed")
                ehint += " / Words " + ("done" if "boss" in self.completed_lessons else "needed")
            elif action in self.completed_lessons:
                hint, ehint = "已通关 · 可以再次练习", "Completed · play again"
            self._text(self.tr(hint, ehint), x + 22, 516, 16, MUTED)
            label = self.tr("待解锁", "Locked") if locked else self.tr("开始探索", "Let's explore")
            self._button((x + 18, 552, 344, 42), label + f"  {i+1}", action,
                         LINE if locked else GREEN, INK if locked else WHITE)
            # 整张课程卡可点，仍只占一个键盘焦点位置。
            self.buttons[-1] = (self.pg.Rect(x, 365, 380, 246), action)
        self._button((52, 625, 270, 42), self.tr("4  自由拼词", "4  Free writing"), "board", BLUE, GREEN)
        self._button((340, 625, 270, 42), self.tr("5  学习档案", "5  Learning record"), "archive", MINT, GREEN)
        # 只在首页解释数字6为语言命令，不占用课程答案或黑板正文的6。
        self._button((898, 625, 330, 42), self.tr("6  切换为 English", "6  Switch to Chinese"), "language", WHITE, GREEN)
        prompt = self.menu_notice if self.uptime < self.menu_notice_until else self.tr(
            "写对应数字并确认选择", "Write a number and confirm")
        self._text(prompt, 52, 688, 13, GREEN)
        self._footer()

    def _footer(self):
        # 首页已有中央选课提示；去掉角落重复说明，保留课程内必要的返回导航。
        if self.game is not None:
            if self.intro:
                guide = self.tr("课程即将自动开始", "Lesson starts automatically")
            elif self.game.status == "victory":
                guide = self.tr("写1再玩一组 · 写2回首页 · 写3打印", "Write 1 replay / 2 home / 3 print")
            else:
                guide = self.tr("连续确认两个0返回首页 · 遇到目标0先完成题目",
                                "Confirm 0 twice for home; finish a target 0 first")
            self._text(guide, 52, 688, 13, MUTED)
        if self.live_port:
            state = self.input_status.state if self.input_status else "connecting"
            labels = {"connecting": ("连接中", "Connecting"), "ready": ("等待下一笔", "Ready"),
                      "recognizing": ("识别中", "Recognizing"), "disconnected": ("断线 · 自动重连", "Reconnecting"),
                      "invalid": ("无效输入 · 清空重写", "Invalid: clear and retry"),
                      "overflow": ("输入过快 · 清空重写", "Queue full: clear and retry"),
                      "error": ("服务故障 · 查看终端", "Service error: check terminal")}
            label = self.tr(*labels.get(state, labels["error"]))
            color = GREEN if state == "ready" else ORANGE
            self.draw.circle(self.canvas, color, (876, 696), 4)
            self._text(self.tr(f"书写输入 · {label}", f"Writing input · {label}"),
                       1228, 688, 13, color, "right")
        elif self.replay:
            # 普通演示不显示技术标签；回放会自行推进，仍明确提示自动输入。
            self._text(self.tr("回放演示 · 自动输入", "REPLAY · automatic input"),
                       1228, 688, 13, MUTED, "right")
        if self.archive.error:
            self._text(self.tr("存档不可用 · 本次进度仅临时保留", "Save unavailable · progress is temporary"),
                       640, 94, 14, ORANGE, "center")

    def _draw_last_input(self, rect, char_pos):
        """只展示最近已确认的一笔，不冒充实时视频或逐帧识别。"""
        self._panel(rect, CREAM, 14, False)
        detail = self.last_input or {}
        points = detail.get("points", ())
        if points:
            x, y, w, h = rect
            mapped = [(x+10+px*(w-20)/255, y+10+py*(h-20)/255) for px, py in points]
            for a, b in zip(mapped, mapped[1:]):
                self.draw.line(self.canvas, GREEN, a, b, 2)
            self.draw.circle(self.canvas, ORANGE, mapped[0], 3)
        else:
            self._text(self.tr("等待书写", "Write next"), rect[0]+rect[2]/2, rect[1]+rect[3]/2-10,
                       14, MUTED, "center")
        self._text(detail.get("char", "—"), *char_pos, 48, GREEN, "center", True)
        if detail:
            self._text(self.tr(f"处理 {detail['latency_ms']:.1f} ms", f"Input {detail['latency_ms']:.1f} ms"),
                       char_pos[0], char_pos[1]+60, 12, MUTED, "center")

    @property
    def challenge_unlocked(self):
        return {"numbers", "boss"} <= self.completed_lessons

    def start_mode(self, mode, deck=None, guided=False):
        if mode not in ("falling", "boss", "challenge"):
            raise ValueError("未知游戏模式")
        if mode == "falling" and deck not in (None, "numbers"):
            raise ValueError("数字练习只使用numbers；大小写独立课程已退役")
        # 所有入口统一校验，键盘、触摸、串口和命令行都不能绕过通关条件。
        if mode == "challenge" and not self.challenge_unlocked:
            self.menu_notice = self.tr("先把数字和单词各玩通一遍，就能解锁挑战！",
                                       "Finish numbers AND words once to unlock the challenge!")
            self.menu_notice_until = self.uptime + 5.0
            return False
        self._finish_session()
        self.mode = mode
        self.deck = "numbers"
        # 正常练习换序，回放固定seed；数字每组覆盖0～9各一次。
        seed = (self.args.seed if self.args.seed is not None else 7) if self.replay_events is not None else self.practice_seed + self.lesson_number
        self.lesson_number += 1
        if mode == "falling":
            cards = None if self.replay_events is not None else plan_practice(self.deck, seed, self.seen[self.deck], self.review[self.deck], self.recent_digits)
            self.game = FallingGame(seed=seed, deck=self.deck, cards=cards)
            self.reviewing = set() if cards is None else set(cards) & self.review[self.deck]
            if cards is not None:
                self.recent_digits = tuple(cards)
        else:
            # 每第三组最多一个长词；上限从6开始，每三次通关增加2，避免一开始出现很长的词。
            # 单词课和混写各自使用原有通关计数，中途退出不升级。
            wins = self.lesson_wins[mode]
            words = DEFAULT_BOSS_WORDS if self.replay_events is not None else plan_words(
                seed, self.word_seen, self.word_review, self.recent_words, advanced=wins % 3 == 2,
                max_length=min(MAX_WORD_LENGTH, 6 + 2 * (wins // 3)),
                max_characters=LESSON_CHARACTER_LIMIT - (3 if mode == "challenge" else 0))
            # 词库/调度用大写规范键；实际题目首字母大写，其余小写，不改模型输入。
            targets = tuple(word.capitalize() for word in words)
            if mode == "challenge":
                digits = None if self.replay_events is not None else plan_practice(
                    "numbers", seed, self.seen["numbers"], set(), self.recent_digits, count=3)
                self.game = MixedGame(seed, targets, digits)
                self.reviewing = set()
                if digits is not None:
                    self.recent_digits = tuple(digits)
            else:
                self.game = BossGame(targets)
                self.reviewing = set(self.word_review)
            if self.replay_events is None:
                self.recent_words = words + self.recent_words[:3]
        self.round_mistakes = set()
        self.mismatch = self.leave_prompt = False
        # 每门课程仅首次进入展示完整引导；返回同一课程时直接练习。
        lesson = mode if mode != "falling" else self.deck
        self.intro = guided and lesson not in self.introduced_lessons
        self.intro_until = self.uptime + 4.0 if self.intro else 0.0
        self.return_armed_until = 0.0
        self.celebration = 0.0
        self.paused = False
        self.elapsed = 0.0
        self.feedback = self.last_char = ""
        self.feedback_until = 0
        self.hint = False
        self.focus = 0
        self.lesson_record = None if self.replay_events is not None else self.archive.new_session(
            "numbers" if mode == "falling" else mode,
            self.game._cards if isinstance(self.game, FallingGame) else self.game.words)
        return True

    def _recognized_char(self, char):
        """统一接收一次已确认的识别字符；键盘和回放也走同一导航入口。

        上游应当每条有效轨迹只调用一次，且在主线程消费事件；不把视频帧当输入。
        """
        if not _ascii_input(char):
            raise ValueError("需要单个ASCII字母或数字")
        if self.print_dialog is not None:
            # 确认页独占字符，不能把发送/返回指令写进黑板或算作答题。
            if char == "1" and self.print_dialog["state"] == "CONFIRM":
                self._action("print_send")
            elif char in ("0", "2"):
                self._action("print_close")
            elif char in ("7", "8"):
                self._action("print_prev" if char == "7" else "print_next")
            return
        if self.mode == "board":
            self._board_input(char)
            return
        if self.mode == "archive":
            if self.history_open:
                self._history_input(char)
                return
            if char == "0":
                self._action("home")
            elif char in ("1", "2"):
                self._action("numbers" if char == "1" else "boss")
            elif char == "3":
                self._action("history")
            return
        if self.game is None:
            choices = {"1": "numbers", "2": "boss", "3": "challenge", "4": "board", "5": "archive", "6": "language"}
            if char in choices:
                self._action(choices[char])
            return
        if self.intro:
            if char == "0":
                self._action("home")
            return
        if self.leave_prompt:
            if char == "1":
                self._action("stay")
            elif char == "2":
                self._action("home")
            return
        if self.game.status == "victory":
            if char == "1":
                self._action("restart")
            elif char == "2":
                self._action("home")
            elif char == "3":
                self._action("print_lesson")
            return
        if self.paused:
            if char == "1":
                self._action("pause")
            elif char == "2":
                self._action("leave")
            return
        # 返回命令只在当前目标不是0时识别；两个独立确认可避免误触退出。
        if char == "0" and self._target_char() != "0":
            if self.return_armed_until > self.uptime:
                self._action("home")
            else:
                self.return_armed_until = self.uptime + 8.0
                self.feedback = self.tr("再写一个0并确认，就会返回首页",
                                        "Write and confirm 0 once more to go home")
                self.feedback_until = self.elapsed + 8.0
            return
        self.return_armed_until = 0.0
        self._submit(char)

    def post_confirmed_char(self, char, event_id, detail=None):
        """后台只投递数据，页面由主线程更新；event_id不是FPGA回绕seq。"""
        if not _ascii_input(char):
            raise ValueError("需要单个ASCII字母或数字")
        if isinstance(event_id, bool) or not isinstance(event_id, int) or event_id < 0:
            raise ValueError("event_id必须是非负整数")
        try:
            self.character_queue.put_nowait((event_id, char, detail))
        except queue.Full:
            return False
        return True

    def _consume_confirmed_chars(self):
        """只在pygame主线程更改页面；重复或迟到的推理事件不再触发导航。"""
        # 每轮至多处理32笔，避免输入持续积压时阻塞绘制；不使用板端8位seq去重。
        for _ in range(32):
            try:
                event_id, char, detail = self.character_queue.get_nowait()
            except queue.Empty:
                return
            if event_id > self.last_host_event_id:
                self.last_host_event_id = event_id
                # 只丢弃前台过期事件；该笔的UART回传和后台日志不会因此撤销。
                if detail and time.monotonic() - detail["created_at"] > 3.0:
                    self.input_notice = self.tr("输入已过期，请清空后重写", "Input expired. Clear and write again.")
                    self.input_notice_until = self.uptime + 4
                    continue
                if detail:
                    self.last_input = dict(detail, char=char)
                    self.input_notice = self.tr(f"识别到 {char} · 请先清空，再写下一个",
                                                f"Read {char} · clear before writing the next one")
                    if self.intro and char != "0":
                        self.input_notice = self.tr(f"识别到 {char} · 引导尚未结束，请清空后等字卡出现再写",
                                                    f"Read {char} · wait for the lesson, clear and rewrite")
                    self.input_notice_until = self.uptime + 4
                self._recognized_char(char)

    def _submit(self, char):
        if self.game is None or self.paused or self.intro or self.leave_prompt or self.game.status != "playing":
            return
        # 串口、键盘与回放均按确认事件进入判题，不按摄像头或显示帧重复计分。
        self.next_event_id += 1
        old_word = self.game.word if isinstance(self.game, BossGame) else None
        # 显示字形不能分裂同一个词的统计/复习键；数字仍保持原字符。
        word_key = old_word.upper() if old_word is not None and not old_word.isdigit() else None
        target = self._target_char()
        finishing_word = old_word is not None and self.game.index == len(old_word) - 1
        position = self.game.completed
        result = self.game.submit(char, self.next_event_id)
        self.last_char = char
        if result == "correct":
            self.mismatch = False
            if self.replay_events is None and finishing_word and not old_word.isdigit():
                self.word_seen[word_key] = self.word_seen.get(word_key, 0) + 1
            if self.replay_events is None:
                if word_key is None:
                    counts = self.seen["numbers"]
                    counts[target] = counts.get(target, 0) + 1
                    if target not in self.round_mistakes:
                        self.review["numbers"].discard(target)
                elif finishing_word and word_key not in self.round_mistakes:
                    self.word_review.discard(word_key)
            self.session_stars += 1
            if self.game.status == "victory":
                self.completed_lessons.add("numbers" if self.mode == "falling" else self.mode)
                if self.mode in self.lesson_wins and self.replay_events is None:
                    self.lesson_wins[self.mode] += 1
            # 成功卡用目标规范字形；last_char/最近笔迹仍保留原始识别，不改UART。
            self.success_label = old_word if finishing_word else target
            self.celebration_duration = 2.2 if finishing_word and len(old_word) > 1 else 1.6
            self.celebration = self.celebration_duration
            self.feedback = self.tr("写对啦！小星星送给你", "Wonderful! A star for you.")
            if char != target:
                self.feedback = self.tr(f"认出 {target.upper()}/{target.lower()} 啦！这组字母不区分大小写",
                                        f"Well done! {target.upper()}/{target.lower()} both count.")
            self.hint = False
        elif result == "wrong":
            self.mismatch = True
            if self.replay_events is None:
                item = word_key or target
                self.round_mistakes.add(item)
                if word_key is not None:
                    self.word_review.add(item)
                else:
                    self.review["numbers"].add(item)
            self.celebration = 0.0
            self.feedback = self.tr("字母相同，注意大小写哦", "Same letter! Check CAPITAL / small.") if char.lower() == target.lower() else self.tr("这次输入和字卡不同，我们再试一次", "This input differs from the card. Try again.")
            self.hint = True
        if result in ("correct", "wrong") and self.replay_events is None:
            # 只计有效答题，导航、引导和重复事件不计；每笔成功仍只奖励一星。
            saved = self.archive.data
            saved["attempts"] += 1
            saved["stars"] += int(result == "correct")
            if result == "correct" and self.game.status == "victory":
                saved["completions"]["numbers" if self.mode == "falling" else self.mode] += 1
            self._record_answer(target, char, result == "correct", position)
            self._save_learning()
        self.feedback_until = self.elapsed + 2.5

    def _record_answer(self, expected, received, correct, position):
        """只记录真正进入判题的事件；导航/重复回传/打印指令都不进入成绩。"""
        record = self.lesson_record
        if record is None:
            return
        record["answers"].append(dict(expected=expected, received=received, correct=correct,
                                      position=position, seconds=round(self.elapsed, 3)))
        record["elapsed_seconds"] = round(self.elapsed, 3)
        record["ended_at"] = local_timestamp()
        if self.game.status == "victory":
            record["status"] = "completed"
        self.archive.store_session(record)

    def _finish_session(self):
        """离开/重开/正常退出时归档未完成练习；通关记录不再改日期、用时或成绩。"""
        record = self.lesson_record
        if record is not None and record["status"] == "in_progress" and record["answers"]:
            record.update(status="stopped", ended_at=local_timestamp(), elapsed_seconds=round(self.elapsed, 3))
            self.archive.store_session(record)
            self._save_learning()

    def _save_learning(self):
        """仅主线程在答题或编辑后保存，绘画每帧不读写磁盘。"""
        if self.replay_events is not None:
            return
        saved = self.archive.data
        saved["seen_digits"] = dict(self.seen["numbers"])
        saved["review_digits"] = sorted(self.review["numbers"])
        saved["seen_words"] = dict(self.word_seen)
        saved["review_words"] = sorted(self.word_review)
        saved["board_text"] = self.board_text
        self.archive.save()

    def _board_input(self, char):
        """自由拼词不判答案、不奖励星星；0只在本页用作工具入口。"""
        if self.board_clear_confirm:
            if char in ("1", "2"):
                self._action("board_clear_yes" if char == "1" else "board_cancel")
            return
        if self.board_tools:
            # 0已用作本页工具入口；要输入真正的数字0，使用工具项6。
            actions = {"1": "board_backspace", "2": "board_space", "3": "board_newline",
                       "4": "board_clear", "5": "home", "6": "board_zero", "7": "print_board", "0": "board_cancel"}
            if char in actions:
                self._action(actions[char])
            return
        if char == "0":
            self._action("board_tools")
        else:
            self._board_append(char)

    def _board_append(self, text):
        if len(self.board_text) + len(text) <= 120:
            self.board_text += text
            self._save_learning()
        else:
            self.input_notice = self.tr("小黑板写满了，打开工具清空或删一字", "Board full. Open tools to clear or delete.")
            self.input_notice_until = self.uptime + 4

    def _board_lines(self):
        """按实际字体宽度换行，避免连续W等宽字母伸进右侧笔迹区。"""
        lines = []
        maximum = round(728*self.render_scale)
        for paragraph in self.board_text.split("\n"):
            line = ""
            for char in paragraph:
                if line and self._font(42, True).size(line+char)[0] > maximum:
                    lines.append(line)
                    line = ""
                line += char
            lines.append(line)
        return lines

    def _draw_board(self):
        """只显示确认后字符与最近一笔，不声称UART支持实时黑板轨迹。"""
        self._header()
        self._panel((52, 119, 840, 490), WHITE, 28)
        self._text(self.tr("我的自由小黑板", "My little writing board"), 88, 139, 28, GREEN, bold=True)
        self._text(self.tr("没有标准答案 · 大小写按识别结果显示", "No target answer · original letter case stays"),
                   88, 187, 17, MUTED)
        self._panel((80, 228, 784, 280), MINT, 22, False)
        # 超过四行只显示末尾；原文最多120字符，并在档案中完整保留。
        lines = self._board_lines()
        for index, line in enumerate(lines[-4:]):
            self._text(line, 108, 244+index*61, 42, GREEN, bold=True)
        if not self.board_text:
            self._text(self.tr("写个字母，让想法开始吧", "Write a letter. Start an idea."), 472, 339, 25, GREEN, "center")
        self._text(self.tr(f"已写 {len(self.board_text)} / 120 · 内容自动保存", f"{len(self.board_text)} / 120 · saved automatically"),
                   88, 532, 16, MUTED)
        self._button((88, 563, 228, 38), self.tr("0  打开工具", "0  Open tools"), "board_tools", GREEN, WHITE)
        self._panel((914, 119, 314, 490), BLUE, 28, False)
        self._text(self.tr("最近一笔", "Latest writing"), 1071, 144, 25, GREEN, "center", True)
        self._draw_last_input((940, 199, 135, 151), (1150, 222))
        self._text(self.tr("① 写好后确认", "Confirm each character"), 940, 414, 18, GREEN)
        self._text(self.tr("② 清空后继续", "Clear, then write next"), 940, 454, 18, GREEN)
        self._text(self.tr("板端清空只清当前笔迹", "Board clear resets one stroke"), 940, 509, 14, MUTED)
        self._text(self.tr("工具中可删字、空格、换行", "Tools: delete, space, new line"), 640, 638, 20, GREEN, "center")
        self._footer()
        if self.board_tools:
            self._draw_board_tools()

    def _draw_board_tools(self):
        shade = self.pg.Surface(self.render_size, self.pg.SRCALPHA)
        shade.fill((39, 68, 59, 105))
        self.canvas.blit(shade, (0, 0))
        self.buttons = []
        self._panel((320, 145, 640, 444), WHITE, 28)
        self._text(self.tr("清空整块黑板？", "Clear the whole board?") if self.board_clear_confirm else self.tr(
            "小黑板工具", "Writing tools"), 640, 177, 30, GREEN, "center", True)
        if self.board_clear_confirm:
            self._text(self.tr("只清拼词内容，学习成绩不会消失", "Only the text is cleared; learning records stay"),
                       640, 260, 18, MUTED, "center")
            self._button((368, 365, 250, 65), self.tr("1  确认清空", "1  Clear"), "board_clear_yes")
            self._button((662, 365, 250, 65), self.tr("2  保留内容", "2  Keep"), "board_cancel", MINT, GREEN)
        else:
            actions = [("board_backspace", "1  删一个字", "1  Delete"), ("board_space", "2  加空格", "2  Space"),
                       ("board_newline", "3  换一行", "3  New line"), ("board_clear", "4  清空黑板", "4  Clear board"),
                       ("home", "5  回到乐园", "5  Home"), ("board_zero", "6  输入数字0", "6  Insert zero"),
                       ("print_board", "7  打印内容", "7  Print text"), ("board_cancel", "0  继续拼词", "0  Keep writing")]
            for index, (action, cn, en) in enumerate(actions):
                self._button((354+(index%2)*294, 238+(index//2)*73, 278, 58), self.tr(cn, en), action, MINT, GREEN)
            self._text(self.tr("打印前会再次确认，原文不会清空", "Confirm before sending; your text stays"),
                       640, 548, 15, MUTED, "center")

    def _draw_archive(self):
        if self.history_open:
            self._draw_history()
            return
        self._header()
        saved = self.archive.data
        summary = saved["summary"]
        self._text(self.tr("学习档案", "Learning record"), 52, 112, 32, INK, bold=True)
        self._text(self.tr(f"{summary['sessions']} 次练习", f"{summary['sessions']} sessions"), 1208, 125, 18, MUTED, "right")
        for index, (value, cn, en, tint) in enumerate([
                (saved["attempts"], "累计作答", "Answers", BLUE),
                (saved["stars"], "累计星星", "Stars", MINT),
                (f"{100*saved['stars']/saved['attempts']:.1f}%" if saved["attempts"] else "—", "总体正确率", "Accuracy", PEACH),
                (f"{summary['elapsed_seconds']/60:.1f}", "学习分钟", "Active minutes", BLUE)]):
            x = 52+index*299
            self._panel((x, 179, 279, 143), WHITE, 18, False)
            self.draw.rect(self.canvas, tint, (x+20, 201, 4, 94), border_radius=2)
            self._text(self.tr(cn, en), x+40, 199, 17, MUTED)
            self._text(str(value), x+40, 232, 43, INK, bold=True)
        self._panel((52, 346, 574, 257), WHITE, 20, False)
        self._panel((650, 346, 578, 257), WHITE, 20, False)
        self._text(self.tr("课程通关", "Completed lessons"), 78, 365, 22, INK, bold=True)
        self._text(self.tr("待复习", "Review"), 676, 365, 22, INK, bold=True)
        counts = saved["completions"]
        unfinished = max(0, summary["sessions"]-sum(counts.values()))
        for index, (key, cn, en, tint) in enumerate((("numbers", "数字", "Numbers", BLUE),
                ("boss", "单词", "Words", MINT), ("challenge", "混写", "Mixed", PEACH))):
            y = 416+48*index
            self.draw.circle(self.canvas, tint, (88, y+14), 8)
            self._text(self.tr(cn, en), 110, y, 20, GREEN)
            self._text(self.tr(f"{counts[key]} 组", f"{counts[key]} lessons"), 596, y, 20, INK, "right", True)
        self._text(self.tr(f"未完成 {unfinished} 次 · 最长连对 {summary['best_combo']}",
                           f"Unfinished {unfinished} · Best run {summary['best_combo']}"), 78, 565, 15, MUTED)
        digits = " ".join(sorted(self.review["numbers"])) or self.tr("暂无", "None yet")
        words = ", ".join(word.title() for word in sorted(self.word_review)[:6]) or self.tr("暂无", "None yet")
        if len(self.word_review) > 6:
            words += self.tr(f" … 共{len(self.word_review)}词", f" ... {len(self.word_review)} total")
        self._text(self.tr("数字", "Numbers"), 676, 416, 15, MUTED)
        self._text(digits, 676, 443, 22, GREEN)
        self._text(self.tr("单词", "Words"), 676, 486, 15, MUTED)
        for row, line in enumerate(textwrap.wrap(words, 44)):
            self._text(line, 676, 513+29*row, 18, GREEN)
        self._button((52, 625, 270, 42), self.tr("1  练数字", "1  Numbers"), "numbers", BLUE, GREEN)
        self._button((354, 625, 270, 42), self.tr("2  练单词", "2  Words"), "boss", MINT, GREEN)
        self._button((656, 625, 270, 42), self.tr("3  练习记录", "3  History"), "history", GREEN, WHITE)
        self._button((958, 625, 270, 42), self.tr("0  返回", "0  Home"), "home", CREAM, GREEN)
        self._footer()

    def _history_records(self):
        return list(reversed(self.archive.data["sessions"]))

    def _selected_history(self):
        records = self._history_records()
        self.history_page = min(self.history_page, max(0, (len(records)-1)//4))
        shown = records[self.history_page*4:self.history_page*4+4]
        selected = next((item for item in shown if item["id"] == self.history_selected_id), None)
        if selected is None and shown:
            selected = shown[0]
            self.history_selected_id = selected["id"]
        return selected

    def _history_input(self, char):
        # 1～4选当前页的一次练习，5打印选中项；7/8翻页，0回汇总。
        if char in ("1", "2", "3", "4"):
            self._action("history_select_" + char)
        elif char == "5":
            self._action("print_history")
        elif char in ("7", "8"):
            self._action("history_prev" if char == "7" else "history_next")
        elif char == "0":
            self._action("archive")

    def _draw_history(self):
        """同一页左侧选择、右侧预览；日期/内容/成绩并列，打印仍须二次确认。"""
        self._header()
        records = self._history_records()
        selected = self._selected_history()
        pages = max(1, (len(records)+3)//4)
        self._text(self.tr("练习记录", "Practice history"), 52, 112, 32, INK, bold=True)
        self._text(self.tr(f"{len(records)} 次 · {self.history_page+1} / {pages} 页",
                           f"{len(records)} sessions · {self.history_page+1} / {pages}"), 1208, 125, 18, MUTED, "right")
        self._panel((52, 179, 398, 424), WHITE, 20, False)
        self._panel((474, 179, 754, 424), WHITE, 20, False)
        names = {"numbers": self.tr("数字", "Numbers"), "boss": self.tr("单词", "Words"), "challenge": self.tr("混写", "Mixed")}
        states = {"completed": self.tr("已完成", "Complete"), "stopped": self.tr("未完成", "Unfinished"),
                  "interrupted": self.tr("意外中断", "Interrupted"), "in_progress": self.tr("进行中", "In progress")}
        for index, record in enumerate(records[self.history_page*4:self.history_page*4+4]):
            chosen = selected is not None and selected["id"] == record["id"]
            y = 191+102*index
            date = record["started_at"].replace("T", " ")[5:16]
            self._button((64, y, 374, 94), "", f"history_select_{index+1}", MINT if chosen else WHITE, GREEN)
            self._panel((78, y+16, 32, 32), GREEN if chosen else CREAM, 10, False)
            self._text(str(index+1), 94, y+18, 19, WHITE if chosen else MUTED, "center", True)
            self._text(date, 124, y+14, 20, INK, bold=True)
            self._text(f"#{record['id']:06d}", 420, y+18, 13, MUTED, "right")
            stats = session_stats(record)
            self._text(f"{names[record['lesson']]} · {stats['correct']}/{stats['goal']} · {states[record['status']]}",
                       124, y+53, 16, GREEN if chosen else MUTED)
        if selected is None:
            self._text(self.tr("暂无记录", "No records yet"), 850, 316, 28, INK, "center", True)
            self._text(self.tr("完成一组练习后可在这里查看", "Finish a lesson to see it here"), 850, 372, 18, MUTED, "center")
        else:
            stats = session_stats(selected)
            self._text(names[selected["lesson"]], 502, 198, 26, INK, bold=True)
            self._text(states[selected["status"]], 1200, 207, 17, GREEN if selected["status"] == "completed" else ORANGE, "right")
            self._text(self.tr("开始 ", "Start ")+selected["started_at"].replace("T", " "), 502, 252, 16, MUTED)
            ending = self.tr("记录截至：", "Saved to: ") if selected["status"] == "interrupted" else self.tr("结束：", "End: ")
            self._text(ending+selected["ended_at"].replace("T", " "), 502, 280, 16, MUTED)
            for x, value, caption in ((502, f"{stats['correct']}/{stats['goal']}", self.tr("完成字符", "Progress")),
                    (746, f"{stats['accuracy']:.1f}%", self.tr("正确率", "Accuracy")),
                    (1006, f"{selected['elapsed_seconds']:.0f}s", self.tr("有效用时", "Active time"))):
                self._text(value, x, 322, 35, GREEN, bold=True)
                self._text(caption, x, 371, 15, MUTED)
            self.draw.line(self.canvas, LINE, (502, 411), (1200, 411), 1)
            self._text(self.tr("题目", "Practice"), 502, 427, 15, MUTED)
            self._text("  ".join(selected["targets"]), 502, 453, 22, INK, bold=True, max_width=700)
            self._text(self.tr("复习 ", "Review ")+(", ".join(stats["review"]) or self.tr("无", "None")),
                       502, 501, 17, GREEN, max_width=700)
            self._text(self.tr(f"作答 {stats['attempts']} · 重试 {stats['retries']} · 首次答对 {stats['first_try']} · 最长连对 {stats['best_combo']}",
                               f"Answers {stats['attempts']} · Retries {stats['retries']} · First try {stats['first_try']} · Best run {stats['best_combo']}"),
                       502, 554, 15, MUTED)
            self._button((474, 625, 364, 42), self.tr("5  打印本次", "5  Print this record"), "print_history")
        if self.history_page:
            self._button((52, 625, 184, 42), self.tr("7  上一页", "7  Previous"), "history_prev", MINT, GREEN)
        if self.history_page+1 < pages:
            self._button((252, 625, 184, 42), self.tr("8  下一页", "8  Next"), "history_next", MINT, GREEN)
        self._button((862, 625, 366, 42), self.tr("0  返回汇总", "0  Summary"), "archive", CREAM, GREEN)
        self._footer()

    def _advance(self, dt):
        """非阻塞反馈计时；暂停/引导页不推进课程，动画期间仍可提交下一字符。"""
        # 先推进会话时钟与打印状态，再判断是否暂停课程；暂停不阻断串口事务。
        intro_remaining = max(0.0, self.intro_until - self.uptime) if self.intro else 0.0
        self.uptime += dt
        self._poll_print_status()
        if self.intro and self.uptime >= self.intro_until:
            self._action("begin")
        # 回放是整个香橙派会话的事件流，首页也必须消费；切换课程不重播旧字符。
        if self.replay:
            for char in self.replay.due(self.uptime):
                self._recognized_char(char)
        if not self.game or self.paused or self.intro or self.leave_prompt:
            return
        lesson_dt = max(0.0, dt - intro_remaining)
        self.elapsed += lesson_dt
        self.celebration = max(0.0, self.celebration - dt)
        if self.game.status == "playing":
            self.game.tick(lesson_dt)

    def _draw_intro(self):
        """三步图解先说明操作，点击准备好后才开始计时与接收字符。"""
        self._header()
        self._panel((100, 110, 1080, 506))
        self._text(self.tr("先认识玩法，再开始冒险", "A little practice before we begin"), 640, 138, 32, GREEN, "center", True)
        steps = [(165, "1", "看字卡", "Look", "看看要写哪个字符", "Find the character"),
                 (495, "2", "空中写", "Write", "写好后确认一次", "Write, then confirm"),
                 (825, "3", "收星星", "Collect", "清空轨迹，再写下一个", "Clear, then write the next")]
        for x, n, cn, en, caption, ec in steps:
            self._panel((x, 211, 290, 242), (BLUE if n == "1" else PEACH if n == "2" else MINT), 24, False)
            if n == "1":
                self._text(self._target_char(), x+145, 222, 77, GREEN, "center", True)
            elif n == "2":
                self._text(self._target_char(), x+145, 222, 77, GREEN, "center")
                self.draw.line(self.canvas, ORANGE, (x+199,304), (x+223,274), 8)
            else:
                self._star(x+145, 271, 40)
            self._text(n + "  " + self.tr(cn, en), x+145, 340, 25, GREEN, "center", True)
            self._text(self.tr(caption, ec), x+145, 395, 17, INK, "center")
        self.buttons = []
        self._button((365, 499, 346, 60), self.tr("准备好了，开始吧", "Ready, let's begin"), "begin")
        self._button((735, 499, 180, 60), self.tr("返回", "Back"), "home", MINT, GREEN)
        wait = max(0, math.ceil(self.intro_until - self.uptime))
        self._text(self.tr(f"{wait} 秒后自动开始 · 写0返回首页",
                           f"Starts in {wait}s · write 0 for home"), 640, 577, 17, MUTED, "center")
        self._footer()

    def _draw_success(self):
        """保留刚完成的字符/完整单词；右侧仍显示下一目标，不吞快速输入。"""
        t = 1.0 - self.celebration / self.celebration_duration
        # 奖励期间整块活动区换景，不让新题/参照卡从奖励卡背后露出干扰。
        self._panel((76, 180, 792, 411), MINT, 24, False)
        self._panel((267, 227, 410, 238), WHITE, 30)
        self._text(self.success_label, 472, 251, 66, GREEN, "center", True, max_width=370)
        word_done = len(self.success_label) > 1
        self._text(self.tr("一个单词拼好啦！", "A whole word!") if word_done else self.tr("这个字符完成啦！", "Character complete!"), 472, 348, 25, GREEN, "center", True)
        caption = self.tr("星星收齐了，看看你的收获吧", "All stars collected!") if self.game.status == "victory" else self.tr("下一张字卡在右边", "Your next card is on the right")
        self._text(caption, 472, 408, 16, MUTED, "center")
        # 一颗星沿弧线飞向进度栏，不闪屏、不暂停主循环。
        end_x = 99 + (self.game.completed - 1) * min(55, 680 // self.game.goal)
        x = 680 + (end_x - 680) * t
        y = 370 + (144 - 370) * t - 65 * math.sin(math.pi*t)
        self._star(x, y, 23 - t*10)

    def _draw_mismatch(self):
        """用中性并列比较解释不匹配，不以红叉把机器输入等同孩子能力。"""
        self._panel((76, 180, 792, 411), PEACH, 24, False)
        self._text(self.tr("看看哪里不一样", "Spot the difference"), 472, 207, 28, GREEN, "center", True)
        for x, value, cn, en in ((182, self.last_char, "这次输入", "This input"), (512, self._target_char(), "目标字卡", "Target card")):
            self._panel((x, 268, 250, 225), WHITE, 22, False)
            self._text(self.tr(cn, en), x+125, 286, 20, MUTED, "center")
            self._text(value, x+125, 325, 92, GREEN, "center", True)
        self._text(self.tr("按右边的字卡再试一次，不会扣星星", "Try the target card again. You keep your stars."),
                   472, 534, 20, GREEN, "center")

    def _draw_leave_prompt(self):
        shade = self.pg.Surface(self.render_size, self.pg.SRCALPHA)
        shade.fill((39, 68, 59, 105))
        self.canvas.blit(shade, (0, 0))
        self.buttons = []
        self._panel((300, 206, 680, 305))
        self._text(self.tr("要离开这一组练习吗？", "Leave this lesson?"), 640, 242, 30, GREEN, "center", True)
        self._text(self.tr("本组进度会结束，已获得的星星保留", "This lesson ends. Your collected stars stay."), 640, 307, 19, MUTED, "center")
        self._button((355, 394, 270, 60), self.tr("继续练习", "Keep practicing"), "stay")
        self._button((655, 394, 270, 60), self.tr("回到乐园", "Go home"), "home", MINT, GREEN)

    def _target_char(self):
        if isinstance(self.game, FallingGame):
            return self.game.target.char
        return self.game.word[min(self.game.index, len(self.game.word) - 1)]

    def _lesson_side(self):
        game = self.game
        self._panel((916, 111, 312, 510))
        title = self.tr("接下来，写这个", "Next, write this") if self.celebration else self.tr("看一看，再写一写", "Look, then write")
        if game.status == "victory":
            title = self.tr("这一组完成啦", "Lesson complete")
        self._text(title, 1072, 136, 24, GREEN, "center", True)
        self._panel((988, 186, 168, 155), MINT, 25, False)
        self._text(self._target_char(), 1072, 180, 106, GREEN, "center", True)
        char = self._target_char()
        kind = self.tr("数字", "Number") if char.isdigit() else self.tr("大写字母", "Capital letter") if char.isupper() else self.tr("小写字母", "Small letter")
        self._text(kind, 1072, 355, 17, MUTED, "center")
        self._text(self.tr("①  写好后确认", "1  Write and confirm"), 949, 404, 21)
        self._text(self.tr("②  清空后写下一个", "2  Clear for the next one"), 949, 444, 21)
        if self.live_port:
            self._text(f"{game.completed} / {game.goal}", 849, 128, 19, GREEN, "right", True)
            self._draw_last_input((946, 484, 101, 105), (1122, 482))
            return
        self._button((946, 509, 252, 48), self.tr("收起提示", "Hide hint") if self.hint else self.tr("看看提示", "Show a hint"), "hint", PEACH, INK)
        if self.hint and char.isdigit():
            self._text(self.tr("数一数这些小圆点", "Count the little dots") if char != "0"
                       else self.tr("0 表示一个也没有", "Zero means no dots"), 1072, 568, 17, GREEN, "center")
            for i in range(int(char)):
                self.draw.circle(self.canvas, ORANGE, (1072 - (int(char)-1)*11 + i*22, 605), 6)
        else:
            msg = self.tr(f"大写 {char.upper()} · 小写 {char.lower()}", f"Capital {char.upper()} / small {char.lower()}") if self.hint else self.tr("慢慢来，我会等你", "Take your time")
            self._text(msg, 1072, 575, 18, GREEN, "center")
        self._text(f"{game.completed} / {game.goal}", 849, 128, 19, GREEN, "right", True)

    def _progress(self):
        game = self.game
        for i in range(game.goal):
            x = 99 + i * min(55, 680 // game.goal)
            self._star(x, 144, 13, YELLOW if i < game.completed else LINE)

    def _draw_falling(self):
        game = self.game
        self._header(self.tr("数字练习", "Numbers"))
        self._panel((52, 111, 840, 510))
        self._progress()
        tint = BLUE
        self.draw.rect(self.canvas, tint, (76, 180, 792, 411), border_radius=24)
        self._cloud(145, 239, .8)
        self._cloud(681, 253, 1.0)
        self.draw.ellipse(self.canvas, MINT, (77, 536, 790, 80))
        centers = (195, 376, 557, 738)
        x = centers[game.target.lane]
        y = round(280 + game.target.progress * 192)
        self.draw.line(self.canvas, MUTED, (x, y + 58), (x + 8, y + 106), 2)
        self.draw.polygon(self.canvas, ORANGE, [(x, y+52), (x-9, y+69), (x+9, y+69)])
        balloon = PEACH
        self.draw.ellipse(self.canvas, balloon, (x-58, y-69, 116, 132))
        self.draw.ellipse(self.canvas, WHITE, (x-39, y-48, 14, 30))
        self._text(game.target.char, x, y-55, 70, INK, "center", True)
        # 数字课以十格点数参照把符号和数量联系起来。
        aid_x = 667 if x < 472 else 262
        self._panel((aid_x-123, 329, 246, 156), WHITE, 20, False)
        self._text(self.tr("一起数一数", "Let's count"), aid_x, 342, 19, GREEN, "center")
        for i in range(10):
            cx, cy = aid_x-80+(i%5)*40, 400+(i//5)*42
            self.draw.circle(self.canvas, ORANGE if i < int(game.target.char) else LINE, (cx,cy), 12)
        if game.target.char == "0":
            self._text(self.tr("0：一个也没有", "0: no dots"), aid_x, 460, 12, MUTED, "center")
        self._text(self.tr("写出气球上的字符，就能收集星星", "Write the balloon's character to collect a star"),
                   472, 553, 18, GREEN, "center")
        self._lesson_side()
        self._status()

    def _draw_boss(self):
        game = self.game
        self._header(self.tr("混写挑战", "Mixed challenge") if self.mode == "challenge" else self.tr("单词练习", "Words"))
        self._panel((52, 111, 840, 510))
        self._progress()
        # 中文释义和专属插画按规范键查询，字卡/英文反馈保留实际大小写。
        word_key = game.word.upper()
        kind = {"CAT": "cat", "DOG": "dog", "SUN": "sun"}.get(word_key, "bear")
        cn = WORD_MEANINGS.get(word_key, game.word)
        self._panel((80, 181, 784, 253), MINT, 25, False)
        self._cloud(151, 242, .7)
        self._cloud(701, 251, .6)
        number_round = self.mode == "challenge" and game.word.isdigit()
        if number_round:
            self._text(game.word, 472, 210, 100, GREEN, "center", True)
            for i in range(int(game.word)):
                self.draw.circle(self.canvas, ORANGE, (392+(i%5)*40, 350+(i//5)*40), 11)
            self._text(self.tr("数字关", "Number round"), 472, 400, 18, GREEN, "center")
        else:
            self._animal(472, 298, 1.1, kind)
            self._text(self.tr(cn, game.word), 472, 384, 22, GREEN, "center", True, max_width=736)
        instruction = self.tr("写出数字，再去拼单词", "Write the number, then build a word") if number_round else self.tr(
            "按顺序写出字母，认识一个新单词", "One letter at a time. Make a new word.")
        self._text(instruction,
                   472, 451, 20, MUTED, "center")
        if self.mode == "challenge":
            self._text(self.tr(f"第 {game.stage+1} / {len(game.words)} 关", f"Round {game.stage+1} / {len(game.words)}"),
                       820, 195, 16, GREEN, "right", True)
        # 6字母以内保留原字卡；长词在原活动区内缩小间距与字号，不占用右侧输入区。
        width = min(84, 784 / len(game.word))
        card_width = min(70, width - 10)
        letter_size = min(46, int(card_width * .75))
        start = 472 - len(game.word) * width / 2
        for i, char in enumerate(game.word):
            x = round(start + i * width)
            fill = MINT if i < game.index else YELLOW if i == game.index else CREAM
            self._panel((x, 498, card_width, 78), fill, 14, False)
            self._text(char, x+card_width/2, 498+(46-letter_size)/2, letter_size,
                       GREEN, "center", True, max_width=card_width-4)
            if i < game.index:
                self._star(x+card_width-8, 502, min(9, card_width/4))
        self._lesson_side()
        self._status()

    def _status(self):
        text = self.feedback if self.elapsed < self.feedback_until else self.tr("写好一个 · 确认一次 · 清空再继续", "Write one · confirm once · clear and continue")
        self._text(text, 640, 641, 23, GREEN, "center", True)
        self._footer()

    def _overlay(self):
        game = self.game
        shade = self.pg.Surface(self.render_size, self.pg.SRCALPHA)
        shade.fill((39, 68, 59, 105))
        self.canvas.blit(shade, (0, 0))
        # 模态窗口独占点击列表，禁止误触被遮挡的课程按钮。
        self.buttons = []
        self._panel((330, 137, 620, 449), WHITE, 32)
        for i in range(3):
            self._star(572+i*68, 206, 24 if i != 1 else 32)
        victory = game.status == "victory"
        self._text(self.tr("小小书写家，真棒！", "You did it, little writer!") if victory else self.tr("休息一小会儿", "A little break"),
                   640, 263, 32, GREEN, "center", True)
        self._text(self.tr(f"收集 {game.completed} 颗星星 · 完成今日小冒险", f"{game.completed} stars · adventure complete")
                   if victory else self.tr("准备好了，我们再出发", "Ready whenever you are."),
                   640, 325, 20, MUTED, "center")
        if victory:
            message = self.tr("混写挑战已解锁！回首页写3开始", "Mixed challenge unlocked! Home, then write 3") if self.challenge_unlocked else self.tr(
                "再通关另一门课程，就能解锁混写挑战", "Finish the other lesson to unlock the challenge")
            self._text(message,
                       640, 371, 18, MUTED, "center")
        self._button((390, 437, 238, 57), self.tr("再玩一组", "Play again") if victory else self.tr("继续探索", "Continue"),
                     "restart" if victory else "pause")
        self._button((652, 437, 238, 57), self.tr("回到乐园", "Home"), "home" if victory else "leave", MINT, GREEN)
        if victory:
            self._button((390, 506, 500, 42), self.tr("3  打印学习小票", "3  Print learning receipt"), "print_lesson", BLUE, GREEN)
        prompt = self.tr("写1再玩 · 写2回首页 · 写3打印",
                         "Write 1 replay / 2 home / 3 print") if victory else self.tr(
                         "写1继续 · 写2回首页", "Write 1 to continue / 2 for home")
        self._text(prompt, 640, 561 if victory else 535, 14, MUTED, "center")

    def _print_message(self, state):
        messages = {
            "QUEUED": ("等待发送", "Queued"),
            "WAITING": ("等待设备应答", "Waiting for device"),
            "ACTIVE": ("正在发送小票", "Sending receipt"),
            "SENT": ("已发送，请查看打印纸", "Sent. Check the paper."),
            "BUSY": ("设备忙，本次未发送", "Device busy. Not sent."),
            "BAD_TEXT": ("文本不支持，本次未发送", "Unsupported text. Not sent."),
            "ID_CONFLICT": ("任务编号冲突，请检查连接", "Job conflict. Check connection."),
            "UNKNOWN": ("未查到任务，请先检查是否已出纸", "No job record. Check the paper first."),
            "TIMEOUT_UNKNOWN": ("应答超时，请先检查是否已出纸", "Reply timed out. Check the paper first."),
            "DISCONNECTED_UNKNOWN": ("连接中断，请先检查是否已出纸", "Disconnected. Check the paper first."),
            "PROTOCOL_ERROR": ("设备回复异常，请检查连接", "Unexpected reply. Check connection."),
            "UNAVAILABLE": ("串口未连接，本次未发送", "No connection. Not sent."),
        }
        return self.tr(*messages.get(state, messages["PROTOCOL_ERROR"]))

    def _open_print(self, source):
        """前台只冻结内容/确认意图，真正串口写操作交给原后台线程。"""
        try:
            if self.live is not None and self.live.snapshot().print_state in ("QUEUED", "WAITING", "ACTIVE"):
                raise ValueError(self.tr("已有发送任务，请等待结束", "A job is already in progress."))
            if source == "board":
                if self.mode != "board":
                    return
                text = board_receipt(self.board_text, chinese=self.chinese)
                label = self.tr("黑板内容", "Blackboard text")
            elif source == "lesson":
                if self.game is None or self.game.status != "victory":
                    raise ValueError(self.tr("课程结束后才能打印", "Finish the lesson before printing"))
                text = lesson_receipt(self.lesson_record, chinese=self.chinese)
                label = self.tr(f"学习记录 #{self.lesson_record['id']:06d}", f"Learning record #{self.lesson_record['id']:06d}")
            elif source == "history" and self.mode == "archive" and self.history_open:
                record = self._selected_history()
                text = lesson_receipt(record, chinese=self.chinese)
                label = self.tr(f"学习记录 #{record['id']:06d}", f"Learning record #{record['id']:06d}")
            else:
                return
        except ValueError as error:
            self.print_notice, self.print_notice_until = str(error), self.uptime + 6
            return
        # 冻结正文、日期与语言；确认和翻页不重新读取档案或重新生成小票。
        self.print_dialog = {"text": text, "label": label, "state": "CONFIRM", "job_id": 0, "page": 0}

    def _send_print(self):
        # 入队后离开CONFIRM，连续确认不会再次提交；关闭预览也不取消已提交任务。
        if self.print_dialog is None or self.print_dialog["state"] != "CONFIRM":
            return
        try:
            if self.live is None:
                raise ValueError("书写串口未连接")
            # 实机每个新打印行出现在上一行上方，故只在发送出口倒序已排版的行。
            # 行内字符/GBK字节不倒转；预览快照不改，撕纸走纸仍放发送末尾。
            feed = "\r\n"*4
            rows = self.print_dialog["text"][:-len(feed)].split("\r\n")
            wire_text = "\r\n".join(reversed(rows)) + feed
            job_id = self.live.request_print(wire_text)
        except (ValueError, queue.Full):
            self.print_dialog["state"] = "UNAVAILABLE"
            return
        self.print_job_id, self.print_state = job_id, "QUEUED"
        self.print_dialog.update(state="QUEUED", job_id=job_id)
        self.print_notice = self._print_message("QUEUED")
        self.print_notice_until = self.uptime + 8

    def _poll_print_status(self):
        if self.live is None or not self.print_job_id:
            return
        snapshot = self.live.snapshot()
        if snapshot.print_job_id != self.print_job_id or snapshot.print_state == self.print_state:
            return
        self.print_state = snapshot.print_state
        self.print_notice = self._print_message(self.print_state)
        self.print_notice_until = self.uptime + 8
        if self.print_dialog is not None and self.print_dialog["job_id"] == self.print_job_id:
            self.print_dialog["state"] = self.print_state

    def _draw_receipt_preview(self):
        """按最终纸面的自然阅读顺序逐列预览；7/8可看完整长黑板。

        预览只读已冻结的快照，翻页不触发串口或重新生成日期。
        """
        dialog = self.print_dialog
        lines = dialog["text"].replace("\r\n", "\n").split("\n")
        # 撕纸空行不挤占预览页，但发送原文不裁减。
        while lines and not lines[-1]:
            lines.pop()
        pages = max(1, (len(lines)+RECEIPT_PAGE_LINES-1)//RECEIPT_PAGE_LINES)
        page = dialog["page"] = max(0, min(pages-1, dialog.get("page", 0)))
        self._panel((172, 128, 344, 426), (255, 255, 255), 3, False)
        for row, line in enumerate(lines[page*RECEIPT_PAGE_LINES:(page+1)*RECEIPT_PAGE_LINES]):
            column = 0
            for char in line:
                if char != " ":
                    self._text(char, 205+column*8.5, 146+row*16, 12, INK)
                column += _receipt_width(char)
        self._text(f"{page+1} / {pages}", 344, 563, 14, MUTED, "center")
        if page:
            self._button((172, 588, 162, 36), self.tr("7  上一页", "7  Previous"), "print_prev", MINT, GREEN)
        if page+1 < pages:
            self._button((354, 588, 162, 36), self.tr("8  下一页", "8  Next"), "print_next", MINT, GREEN)

    def _draw_print_dialog(self):
        shade = self.pg.Surface(self.render_size, self.pg.SRCALPHA)
        shade.fill((39, 68, 59, 105))
        self.canvas.blit(shade, (0, 0))
        self.buttons = []
        self._panel((138, 90, 1004, 554), WHITE, 24, False)
        dialog = self.print_dialog
        confirming = dialog["state"] == "CONFIRM"
        self._draw_receipt_preview()
        self._text(self.tr("打印小票", "Print receipt"), 566, 148, 32, INK, bold=True)
        self._text(dialog["label"], 566, 209, 20, MUTED)
        message = self.tr("确认打印？", "Print this receipt?") if confirming else self._print_message(dialog["state"])
        color = GREEN if confirming or dialog["state"] in ("QUEUED", "WAITING", "ACTIVE", "SENT") else ORANGE
        self.draw.circle(self.canvas, color, (576, 294), 6)
        for row, line in enumerate(textwrap.wrap(message, 35 if not self.chinese else 23)):
            self._text(line, 596, 277+32*row, 20, color, bold=True)
        if confirming:
            self._button((566, 401, 252, 56), self.tr("1  打印", "1  Print"), "print_send")
            self._button((838, 401, 252, 56), self.tr("2  返回", "2  Back"), "print_close", MINT, GREEN)
        else:
            self._button((566, 401, 524, 56), self.tr("0 / 2  返回", "0 / 2  Back"), "print_close", MINT, GREEN)
        self._text(self.tr("不自动重印；已发送的任务不能撤回", "No automatic reprint. Sent jobs cannot be cancelled."),
                   566, 509, 15, MUTED)

    def _action(self, action):
        # 鼠标、键盘和识别字符复用同一状态转换，不在各输入入口复制页面逻辑。
        self.focus = 0
        if action == "language":
            # 只允许首页切换，不在确认页改动已冻结的小票，也不修改学习档案。
            if self.mode is not None or self.print_dialog is not None:
                return
            if not self.chinese and not self.font_path:
                self.menu_notice = "Chinese font missing. Install a CJK font."
                self.menu_notice_until = self.uptime + 6
                return
            self.chinese = not self.chinese
            self.menu_notice, self.menu_notice_until = "", 0.0
        elif action in ("print_board", "print_lesson", "print_history"):
            self._open_print({"print_board": "board", "print_lesson": "lesson", "print_history": "history"}[action])
        elif action == "print_send":
            self._send_print()
        elif action == "print_close":
            self.print_dialog = None
        elif action in ("print_prev", "print_next"):
            if self.print_dialog is not None:
                page = self.print_dialog.get("page", 0)
                lines = self.print_dialog["text"].replace("\r\n", "\n").rstrip("\n").split("\n")
                pages = max(1, (len(lines)+RECEIPT_PAGE_LINES-1)//RECEIPT_PAGE_LINES)
                self.print_dialog["page"] = max(0, min(pages-1, page+(-1 if action == "print_prev" else 1)))
        elif action in ("board", "archive"):
            self._finish_session()
            self.mode, self.game = action, None
            self.paused = self.intro = self.leave_prompt = False
            self.return_armed_until = 0.0
            self.board_tools = self.board_clear_confirm = False
            self.history_open = False
        elif action == "history":
            self._action("archive")
            self.history_open, self.history_page, self.history_selected_id = True, 0, None
        elif action.startswith("history_select_"):
            if self.mode == "archive" and self.history_open:
                index = int(action.rsplit("_", 1)[1])-1
                shown = self._history_records()[self.history_page*4:self.history_page*4+4]
                if 0 <= index < len(shown):
                    self.history_selected_id = shown[index]["id"]
        elif action in ("history_prev", "history_next"):
            if self.mode == "archive" and self.history_open:
                pages = max(1, (len(self._history_records())+3)//4)
                self.history_page = max(0, min(pages-1, self.history_page + (-1 if action == "history_prev" else 1)))
                self.history_selected_id = None
        elif action.startswith("board_"):
            if self.mode != "board":
                return
            if action == "board_tools":
                self.board_tools = True
            elif action == "board_clear":
                self.board_tools = self.board_clear_confirm = True
            elif action == "board_cancel":
                self.board_tools = self.board_clear_confirm = False
            elif action == "board_clear_yes":
                self.board_text = ""
                self.board_tools = self.board_clear_confirm = False
                self._save_learning()
            else:
                self.board_tools = self.board_clear_confirm = False
                if action == "board_backspace":
                    self.board_text = self.board_text[:-1]
                    self._save_learning()
                elif action in ("board_space", "board_newline", "board_zero"):
                    self._board_append({"board_space": " ", "board_newline": "\n", "board_zero": "0"}[action])
        elif action == "home":
            self._finish_session()
            self.mode = self.game = None
            self.paused = False
            self.intro = False
            self.leave_prompt = False
            self.return_armed_until = 0.0
        elif action == "begin":
            if self.intro:
                self.introduced_lessons.add(self.mode if self.mode != "falling" else self.deck)
            self.intro = False
        elif action == "leave":
            if self.game and not self.intro and self.game.status == "playing":
                self.leave_prompt = True
            else:
                self._action("home")
        elif action == "stay":
            self.leave_prompt = False
        elif action == "pause":
            self.paused = not self.paused
        elif action == "restart":
            self.start_mode(self.mode)
        elif action == "hint":
            self.hint = not self.hint
            if not self.hint:
                self.mismatch = False
        elif action in ("boss", "challenge"):
            self.start_mode(action, guided=True)
        elif action == "numbers":
            self.start_mode("falling", "numbers", guided=True)

    def _handle_key(self, event):
        pg = self.pg
        if self.print_dialog is not None and event.key == pg.K_ESCAPE:
            self._action("print_close")
            return
        # 真实模式不让键盘字符混入成绩；Esc/暂停等维护操作仍可用。
        if self.live_port and _ascii_input(getattr(event, "unicode", "")):
            return
        if event.key == pg.K_ESCAPE:
            if self.mode == "archive" and self.history_open:
                self._action("archive")
            elif self.mode in ("board", "archive"):
                self._action("board_cancel" if self.mode == "board" and self.board_tools else "home")
            elif self.game is None:
                self.running = False
            elif self.leave_prompt:
                self._action("stay")
            else:
                self._action("leave")
        elif event.key == pg.K_TAB and self.buttons:
            self.keyboard_focus = True
            direction = -1 if getattr(event, "mod", 0) & pg.KMOD_SHIFT else 1
            self.focus = (self.focus + direction) % len(self.buttons)
        elif event.key == pg.K_RETURN and self.buttons:
            self._action(self.buttons[self.focus % len(self.buttons)][1])
        elif self.print_dialog is not None:
            if _ascii_input(getattr(event, "unicode", "")):
                self._recognized_char(event.unicode)
        elif self.leave_prompt:
            return
        elif self.mode in ("board", "archive") and _ascii_input(getattr(event, "unicode", "")):
            self._recognized_char(event.unicode)
        elif self.game is None:
            actions = {pg.K_1: "numbers", pg.K_2: "boss", pg.K_3: "challenge", pg.K_4: "board", pg.K_5: "archive", pg.K_6: "language"}
            if event.key in actions:
                self._action(actions[event.key])
        elif event.key == pg.K_SPACE and self.intro:
            self._action("begin")
        elif event.key == pg.K_SPACE and self.game.status == "playing":
            self._action("pause")
        elif event.key == pg.K_F5:
            self._action("restart")
        elif _ascii_input(event.unicode):
            self._recognized_char(event.unicode)

    def _logical_pos(self, pos):
        """窗口缩放和黑边采用同一变换；鼠标/触摸与实际按钮保持对齐。"""
        viewport = self._viewport()
        return ((pos[0] - viewport.x)*WIDTH/viewport.width,
                (pos[1] - viewport.y)*HEIGHT/viewport.height)

    def _viewport(self):
        """输入和输出共用舍入后的视口，奇数尺寸和留白处也能精确对齐。"""
        w, h = self.screen.get_size()
        scale = min(w / WIDTH, h / HEIGHT)
        width, height = max(1, round(WIDTH*scale)), max(1, round(HEIGHT*scale))
        return self.pg.Rect((w-width)//2, (h-height)//2, width, height)

    def _click(self, pos):
        self.keyboard_focus = False
        pos = self._logical_pos(pos)
        for rect, action in self.buttons:
            if rect.collidepoint(pos):
                self._action(action)
                break

    def _draw(self):
        self.buttons = []
        self._background()
        if self.intro:
            self._draw_intro()
        elif self.mode == "board":
            self._draw_board()
        elif self.mode == "archive":
            self._draw_archive()
        elif self.mode == "falling":
            self._draw_falling()
        elif self.mode in ("boss", "challenge"):
            self._draw_boss()
        else:
            self._draw_menu()
        if self.game and self.celebration > 0 and not self.intro:
            self._draw_success()
        elif self.game and self.mismatch and not self.intro:
            self._draw_mismatch()
        if self.game and not self.intro and (self.paused or (self.game.status == "victory" and not self.celebration)):
            self._overlay()
        if self.leave_prompt:
            self._draw_leave_prompt()
        if self.print_dialog is not None:
            self._draw_print_dialog()
        # 页面顶部之外固定一行接入反馈，不覆盖学习字卡/奖励区。
        if self.print_dialog is None:
            if self.uptime < self.print_notice_until:
                self._text(self.print_notice, 640, 666, 13, MUTED, "center")
            elif self.live_port and self.uptime < self.input_notice_until:
                self._text(self.input_notice, 640, 666, 13, MUTED, "center")
        # 键盘焦点用深色外框表达，不依赖颜色区分；也支持鼠标和触摸。
        if self.buttons and self.keyboard_focus:
            rect = self.buttons[self.focus % len(self.buttons)][0]
            self.draw.rect(self.canvas, ORANGE, rect.inflate(6, 6), 2, border_radius=18)
        viewport = self._viewport()
        self.screen.fill(CREAM)
        # 同分辨率直接输出，只有窗口/桌面大小不同时才缩放一次。
        image = self.canvas if viewport.size == self.render_size else self.pg.transform.smoothscale(self.canvas, viewport.size)
        self.screen.blit(image, viewport.topleft)
        self.pg.display.flip()

    def run(self):
        pg = self.pg
        try:
            if self.live_port:
                from .live_input import PenInput
                self.live = PenInput(self.live_port, self.args.model, self.post_confirmed_char,
                                     bd_shape=self.args.bd_shape, log_dir=self.args.log_dir)
                print(f"书写输入：{self.live_port}；日志：{self.live.log_path}；PEN/HAND共用现有模型。", flush=True)
                self.live.start()
            self._draw()
            while self.running:
                # 60是界面刷新上限，不是摄像头帧率；卡顿后限制动画步长以免画面突跳。
                dt = min(self.clock.tick(60)/1000.0, .1)
                for event in pg.event.get():
                    if event.type == pg.QUIT:
                        self.running = False
                    elif event.type == pg.KEYDOWN:
                        self._handle_key(event)
                    elif event.type == pg.MOUSEBUTTONDOWN and event.button == 1:
                        # SDL触摸会生成合成鼠标事件；过滤它，避免同一次触摸触发两次。
                        if not getattr(event, "touch", False):
                            self._click(event.pos)
                    elif event.type == pg.FINGERDOWN:
                        w, h = self.screen.get_size()
                        self._click((event.x*w, event.y*h))
                if self.live:
                    self.input_status = self.live.snapshot()
                self._consume_confirmed_chars()
                self._advance(dt)
                self._draw()
        finally:
            try:
                self._finish_session()
                if self.live:
                    self.live.close()
            finally:
                pg.quit()


def main(argv=None):
    parser = argparse.ArgumentParser(description="小芽空中书写乐园：学前字母、数字与单词练习")
    parser.add_argument("--mode", choices=("falling", "boss", "challenge"))
    parser.add_argument("--deck", choices=("numbers",), default="numbers", help="兼容旧数字练习命令")
    parser.add_argument("--replay", type=Path)
    parser.add_argument("--port", help="书写轨迹串口，如COM3或/dev/ttyUSB0；不可同时运行采集器")
    parser.add_argument("--model", type=Path, help="PEN/HAND共用的现有62类PEN训练模型.npz；须与--port一起使用")
    parser.add_argument("--bd-shape", action="store_true", help="显式启用已有B/D复核，默认保持原模型")
    parser.add_argument("--log-dir", type=Path, default=Path("logs/game"), help="真实接入JSONL日志目录")
    parser.add_argument("--profile", type=Path, default=Path(__file__).resolve().parent.parent / "user_data/learning.json",
                        help="学习档案路径；默认项目旁user_data/learning.json，回放不读写")
    parser.add_argument("--windowed", action="store_true")
    parser.add_argument("--render-height", type=int, choices=(720, 1080), default=1080,
                        help="原生渲染高度，默认1080；低性能设备可选720")
    parser.add_argument("--display", type=int, default=0)
    parser.add_argument("--seed", type=int, help="显式固定出题；普通启动随机，回放默认7")
    parser.add_argument("--font", type=Path, help="已有中文字体文件；不自动下载")
    args = parser.parse_args(argv)
    if bool(args.port) != bool(args.model) or (args.port and args.replay) or (args.bd_shape and not args.port):
        parser.error("--port与--model须一起使用；真实串口不可混用--replay；--bd-shape仅用于真实模型")
    try:
        import pygame
    except ImportError:
        print("当前环境没有pygame，请切换到已有环境；未安装软件。", file=sys.stderr)
        return 2
    try:
        ArcadeApp(pygame, args).run()
    except (OSError, ValueError, ImportError, pygame.error) as error:
        print(f"游戏启动失败：{error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
