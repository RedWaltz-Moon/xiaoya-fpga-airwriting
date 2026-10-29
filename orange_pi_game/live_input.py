"""书写后台输入桥：PEN/HAND共用现有模型与V1协议，不在线程操作pygame。"""

from __future__ import annotations

import hashlib
import json
import queue
import secrets
import threading
import time
import uuid
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from pathlib import Path

from .serial_protocol import PrintTransaction, STATUS, TRAJECTORY, StreamParser, text_bytes


@dataclass(frozen=True)
class InputStatus:
    state: str = "connecting"
    message: str = ""
    char: str = ""
    sequence: int | None = None
    points: tuple = ()
    latency_ms: float = 0.0
    accepted: int = 0
    duplicates: int = 0
    print_state: str = ""
    print_job_id: int = 0
    print_message: str = ""


class PenInput:
    """沿用旧类名兼容调用；两种轨迹共享单串口、模型和事件投递逻辑。"""

    def __init__(self, port, model_path, post_char, *, bd_shape=False, log_dir=Path("logs/game"),
                 serial_factory=None, monotonic=time.monotonic):
        # 仅真实输入按需加载NumPy/模型，键盘和回放不新增依赖。
        from tools.trajectory_infer import pen_uart_reply as pen
        self.pen = pen
        self.model_path = Path(model_path).resolve()
        self.model = pen.load_pen_model(self.model_path)
        self.model_hash = hashlib.sha256(self.model_path.read_bytes()).hexdigest()
        if serial_factory is None:
            import serial
            serial_factory = serial.Serial
        self.serial_factory = serial_factory
        self.port, self.post_char, self.bd_shape = port, post_char, bd_shape
        self.monotonic = monotonic
        self.stop_event = threading.Event()
        # 前台只取不可变状态快照、排队请求；串口读写和日志由后台线程串行处理。
        self.lock = threading.Lock()
        self.status = InputStatus()
        self.thread = None
        self.event_id = self.connection_id = 0
        self.previous_key = None
        self.previous_at = 0.0
        self.previous_response = None
        # 前台只能排队；后台仍是唯一串口读写者。不请求打印时不产生任何扩展消息。
        self.print_requests = queue.Queue(maxsize=1)
        self.print_transaction = None
        self.run_id = uuid.uuid4().hex
        folder = Path(log_dir)
        folder.mkdir(parents=True, exist_ok=True)
        name = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        self.log_path = folder / f"trajectory_{name}_{self.run_id[:8]}.jsonl"
        self.log = self.log_path.open("x", encoding="utf-8")
        # V1不含板端模式，不能把模型的PEN训练来源当作实际输入方式。
        # 保留加载器的模型来源校验，不改变现有NPZ、归一化或识别算法。
        self._record("session", mode="UNKNOWN", model_training_mode=self.model.input_mode,
                     port=port, model_path=str(self.model_path),
                     model_sha256=self.model_hash, classes=pen.CLASSES, bd_shape=bd_shape)

    def snapshot(self):
        with self.lock:
            return self.status

    def _status(self, **fields):
        with self.lock:
            self.status = replace(self.status, **fields)

    def _record(self, kind, **fields):
        self.log.write(json.dumps(dict(kind=kind, run_id=self.run_id, connection=self.connection_id,
                                      timestamp_utc=datetime.now(timezone.utc).isoformat(),
                                      **fields), ensure_ascii=False, allow_nan=False) + "\n")
        self.log.flush()

    def _reply(self, link, response):
        if link.write(response) != len(response):
            raise OSError("结果帧未完整写入串口")
        link.flush()

    def request_print(self, text):
        """供游戏确认调用：有界GBK文本，返回任务ID；轨迹确认不直接触发打印。"""
        text_bytes(text)
        job_id = secrets.randbelow(0xFFFFFFFF) + 1
        with self.lock:
            if self.stop_event.is_set():
                raise ValueError("服务已经退出，不能排队打印")
            if self.status.state not in ("ready", "recognizing", "invalid", "overflow"):
                raise ValueError("串口尚未连接，不能排队打印")
            if self.status.print_state in ("QUEUED", "WAITING", "ACTIVE"):
                raise ValueError("已有打印任务尚未结束")
            self.print_requests.put_nowait((job_id, text))
            self.status = replace(self.status, print_state="QUEUED", print_job_id=job_id,
                                  print_message="等待后台发送")
        return job_id

    def _print_tick(self, link):
        if self.print_transaction is None or self.print_transaction.finished:
            try:
                job_id, text = self.print_requests.get_nowait()
            except queue.Empty:
                return
            self.print_transaction = PrintTransaction(job_id, text, self.monotonic())
        transaction = self.print_transaction
        packet = transaction.poll(self.monotonic())
        if packet is not None and link.write(packet) != len(packet):
            raise OSError("打印消息未完整写出，任务状态未知")
        self._status(print_state=transaction.state, print_job_id=transaction.job_id,
                     print_message=transaction.detail)

    def _cancel_print(self):
        # 断线/退出后无法区分设备复位、已发完或仍在发送，绝不跨重连自动补打。
        if self.print_transaction is not None and not self.print_transaction.finished:
            self.print_transaction.abort("DISCONNECTED_UNKNOWN", "连接中断，请核对输出后再操作")
        with self.lock:
            if self.status.print_state in ("QUEUED", "WAITING", "ACTIVE"):
                self.status = replace(self.status, print_state="DISCONNECTED_UNKNOWN",
                                      print_message="连接中断或退出，不自动重发")
            while not self.print_requests.empty():
                self.print_requests.get_nowait()

    def process_frame(self, frame, link):
        """先回传成功，再投递游戏；重复包可再回结果，但不重复导航/计分。"""
        started = self.monotonic()
        timing_started = time.perf_counter()
        payload = bytes(value for point in frame.points for value in point)
        body = bytes((1, 1, frame.sequence, 64, 128, 0)) + payload
        crc = self.pen.crc16_ccitt(body)
        raw = b"\xa5\x5a" + body + bytes((crc & 255, crc >> 8))
        key = hashlib.sha256(raw).hexdigest()
        # V1无复位/ACK字段，只去掉0.75s内连续完全相同的包；不永久按seq去重。
        # 不续期窗口，避免复位后相同笔迹一直被压住；断线时重置此窗口。
        if key == self.previous_key and started - self.previous_at < .75:
            self._reply(link, self.previous_response)
            self._status(duplicates=self.snapshot().duplicates + 1)
            self._record("duplicate", sequence=frame.sequence, raw_frame_hex=raw.hex(),
                         response_hex=self.previous_response.hex())
            return
        self._status(state="recognizing", message="")
        try:
            feature = self.pen.normalize_points(frame.points)
        except ValueError as error:
            self._status(state="invalid", message=str(error))
            self._record("invalid", sequence=frame.sequence, raw_frame_hex=raw.hex(), reason=str(error))
            return
        scores = self.model.scores_from_feature(feature)
        label = self.pen.predict_pen_from_feature(self.model, feature, bd_shape=self.bd_shape)
        response = self.pen.build_frame(frame.sequence, label)
        # 不伪造置信度概率，不因题目范围把C/c等自动换成正确答案。
        self._record("prediction", event_id=self.event_id + 1, sequence=frame.sequence,
                     raw_frame_hex=raw.hex(), points=frame.points, scores=scores.tolist(),
                     baseline_char=self.pen.CLASSES[int(scores.argmax())], char=label,
                     inference_ms=round((time.perf_counter() - timing_started)*1000, 3))
        self._reply(link, response)
        self.previous_key, self.previous_at, self.previous_response = key, started, response
        self.event_id += 1
        # perf_counter在Windows有高分辨率；此时间不含摄像头、书写、UART上行等待。
        latency = round((time.perf_counter() - timing_started)*1000, 3)
        detail = dict(points=frame.points, sequence=frame.sequence, latency_ms=latency,
                      created_at=started)
        queued = self.post_char(label, self.event_id, detail)
        # 界面队列满不会撤回已成功发送的UART结果；显示overflow供用户清空重写。
        self._record("delivery", event_id=self.event_id, sequence=frame.sequence, char=label,
                     response_hex=response.hex(), queued=queued, latency_ms=latency)
        self._status(state="ready" if queued else "overflow", message="",
                     char=label, points=frame.points, sequence=frame.sequence, latency_ms=latency,
                     accepted=self.snapshot().accepted + int(queued))

    def _connected_loop(self, link):
        parser = StreamParser((TRAJECTORY, STATUS))
        last_receive = self.monotonic()
        while not self.stop_event.is_set():
            chunk = link.read(min(link.in_waiting or 1, 4096))
            now = self.monotonic()
            if chunk:
                last_receive = now
                old_errors = (parser.bad_crc_frames, parser.bad_header_candidates)
                frames = parser.feed(chunk)
                if old_errors != (parser.bad_crc_frames, parser.bad_header_candidates):
                    self._record("bad_frame", bad_crc=parser.bad_crc_frames,
                                 bad_header=parser.bad_header_candidates)
                    self._status(state="invalid", message="帧校验失败")
                for frame in frames:
                    if self.stop_event.is_set():
                        break
                    if frame.kind == TRAJECTORY:
                        # 公共帧先按type分流，打印状态绝不能进入轨迹归一化或课程输入。
                        points = tuple(zip(frame.payload[0::2], frame.payload[1::2]))
                        self.process_frame(self.pen.TrajectoryFrame(frame.sequence, points), link)
                    elif frame.kind == STATUS and self.print_transaction is not None:
                        try:
                            if self.print_transaction.accept(frame):
                                self._record("print_status", job_id=self.print_transaction.job_id,
                                             state=self.print_transaction.state)
                                self._status(print_state=self.print_transaction.state,
                                             print_job_id=self.print_transaction.job_id,
                                             print_message=self.print_transaction.detail)
                        except ValueError as error:
                            self._record("print_bad_status", reason=str(error))
            elif parser.has_pending_data and now - last_receive >= 1.0:
                count = parser.discard_pending()
                self._record("partial_timeout", discarded=count)
                self._status(state="invalid", message="半帧超时")
            self._print_tick(link)

    def _run(self):
        try:
            while not self.stop_event.is_set():
                self._status(state="connecting", message="")
                try:
                    with self.serial_factory(port=self.port, baudrate=115200, bytesize=8,
                                             parity="N", stopbits=1, timeout=.1,
                                             write_timeout=1.0) as link:
                        self.connection_id += 1
                        self.previous_key = self.previous_response = None
                        # 重连重新等新笔；丢弃设备端旧缓冲，防止一开游戏就自动选课。
                        link.reset_input_buffer()
                        self._record("connected", port=self.port)
                        self._status(state="ready", message="")
                        self._connected_loop(link)
                except OSError as error:
                    self._cancel_print()
                    self._status(state="disconnected", message=str(error))
                    self._record("disconnected", error=str(error))
                    self.stop_event.wait(2.0)
        except Exception as error:
            # 日志/模型/回调故障不可当作正常重连隐瞒，停止服务并让游戏显示故障。
            self._status(state="error", message=str(error))
            print(f"书写输入服务停止：{error}", flush=True)
        finally:
            self._cancel_print()
            self.log.close()

    def start(self):
        self.thread = threading.Thread(target=self._run, name="pen-input", daemon=True)
        self.thread.start()

    def close(self):
        # 通知线程退出并等待串口上下文释放；不在前台并发关闭其正在使用的串口。
        self.stop_event.set()
        if self.thread is not None:
            self.thread.join(timeout=3.0)
            if self.thread.is_alive():
                raise OSError("书写输入线程未能及时退出")
        else:
            self.log.close()
