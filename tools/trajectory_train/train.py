#!/usr/bin/env python3
"""独立训练脚本：内置JSONL/V1校验和62类基线，离线仅依赖NumPy。"""

from __future__ import annotations

# 协议校验和模板模型内置，复制此脚本即可离线训练；只通过JSONL与采集工具交接。
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



import json
from pathlib import Path

import numpy as np



def normalize_points(points) -> np.ndarray:
    """FPGA已完成几何归一化；软件只做统一的uint8到浮点缩放。"""
    values = np.asarray(points)
    if values.shape != (64, 2) or not np.issubdtype(values.dtype, np.integer):
        raise ValueError("轨迹必须是64个整数坐标点")
    if np.any(values < 0) or np.any(values > 255):
        raise ValueError("轨迹坐标必须在0..255之间")
    span = int(np.max(np.ptp(values, axis=0)))
    if span < 4:
        raise ValueError("轨迹跨度过小，不能作为字符样本")
    # 保留64点的采样先后与XY交错顺序，不二次居中、旋转或转换成位图。
    return (values.astype(np.float32) / 255.0).reshape(128)


def validate_record(record: dict) -> tuple[str, str, str, np.ndarray]:
    """公共字段/CRC校验后再做特征转换，保证采集、审阅与训练接受同一格式。"""
    validate_record_fields(record)
    feature = normalize_points(record["points"])
    return record["label"], record["mode"], record["session"], feature


def load_records(source: Path) -> list[tuple[str, str, str, np.ndarray]]:
    """只读取用户指定文件或目录中的JSONL，不把游戏回放混进数据集。"""
    paths = sorted(source.glob("*.jsonl")) if source.is_dir() else [source]
    if not paths or any(not path.is_file() for path in paths):
        raise ValueError("未找到轨迹JSONL数据")
    records = []
    for path in paths:
        with path.open(encoding="utf-8") as stream:
            for line_number, line in enumerate(stream, 1):
                if not line.strip():
                    continue
                try:
                    records.append(validate_record(json.loads(line)))
                except (ValueError, TypeError) as error:
                    raise ValueError(f"{path}:{line_number}: {error}") from error
    if not records:
        raise ValueError("轨迹数据集为空")
    return records


class BaselineModel:
    """固定62类顺序；每类取最近真实训练样本的负均方距离作为分数。"""

    def __init__(self, features: np.ndarray, labels: np.ndarray, input_mode: str | None = None):
        # 新模型记录训练模式；旧NPZ无此字段时按历史约定由调用入口限制模式。
        if input_mode is not None and input_mode not in MODES:
            raise ValueError("模型输入模式无效")
        self.input_mode = input_mode
        self.features = np.asarray(features, dtype=np.float32)
        self.labels = np.asarray(labels, dtype=np.uint8)
        if self.features.ndim != 2 or self.features.shape[1] != 128:
            raise ValueError("模型特征维度必须为128")
        if len(self.features) == 0 or len(self.labels) != len(self.features):
            raise ValueError("模型样本数量无效")
        if np.any(self.labels >= len(CLASSES)) or not np.all(np.isfinite(self.features)):
            raise ValueError("模型含无效类别或数值")

    def scores(self, points) -> np.ndarray:
        """输出固定0-9/A-Z/a-z顺序的62维距离分数；不是校准概率。"""
        return self.scores_from_feature(normalize_points(points))

    def scores_from_feature(self, feature: np.ndarray) -> np.ndarray:
        # 每个真实样本都是模板；同类取最小MSE的相反数，分数越大越相近。
        distances = np.mean((self.features - feature) ** 2, axis=1)
        scores = np.full(len(CLASSES), -np.inf, dtype=np.float32)
        # 同一类别下标重复出现，必须用at累计最大值，不能用普通高级索引赋值代替。
        np.maximum.at(scores, self.labels, -distances)
        return scores

    def predict(self, points) -> str:
        return CLASSES[int(np.argmax(self.scores(points)))]

    def predict_from_feature(self, feature: np.ndarray) -> str:
        return CLASSES[int(np.argmax(self.scores_from_feature(feature)))]

    def save(self, output: Path) -> None:
        if output.suffix != ".npz" or output.exists():
            raise ValueError("模型输出须为尚不存在的.npz文件")
        output.parent.mkdir(parents=True, exist_ok=True)
        fields = dict(features=self.features, labels=self.labels,
                      classes=np.array(CLASSES), feature_version=np.array(1))
        if self.input_mode is not None:
            fields["input_mode"] = np.array(self.input_mode)
        # 独占创建，避免检查之后另一进程生成同名文件而被覆盖。
        with output.open("xb") as stream:
            np.savez_compressed(stream, **fields)

    @classmethod
    def load(cls, path: Path) -> "BaselineModel":
        # NPZ只接受数值/字符串数组，禁止反序列化pickle对象；类别顺序必须完全匹配。
        with np.load(path, allow_pickle=False) as saved:
            if str(saved["classes"]) != CLASSES or int(saved["feature_version"]) != 1:
                raise ValueError("模型类别顺序或特征版本不兼容")
            mode = str(saved["input_mode"]) if "input_mode" in saved else None
            return cls(saved["features"], saved["labels"], input_mode=mode)


def train_and_evaluate(records, test_session: str) -> tuple[BaselineModel, dict]:
    """整场次留作测试；每种输入模式的62类都须出现在两侧。"""
    # 保留双模式历史调用接口；正式单模式训练入口不走此函数。
    train = [item for item in records if item[2] != test_session]
    test = [item for item in records if item[2] == test_session]
    for name, subset in (("训练", train), ("测试", test)):
        present = {(item[1], item[0]) for item in subset}
        missing = {(mode, char) for mode in ("PEN", "HAND") for char in CLASSES} - present
        if missing:
            raise ValueError(f"{name}集未覆盖62类×PEN/HAND：缺{len(missing)}个模式/字符组合")
    model = BaselineModel(
        np.stack([item[3] for item in train]),
        np.array([CLASSES.index(item[0]) for item in train], dtype=np.uint8),
    )
    report = {"train_count": len(train), "test_count": len(test), "test_session": test_session}
    for mode in ("PEN", "HAND"):
        subset = [item for item in test if item[1] == mode]
        correct = sum(model.predict_from_feature(item[3]) == item[0] for item in subset)
        report[mode] = {"correct": correct, "total": len(subset), "accuracy": correct / len(subset)}
    return model, report

import argparse
import hashlib
import json
from collections import Counter
from pathlib import Path

import numpy as np



def _shape_histogram(feature: np.ndarray) -> np.ndarray:
    """用8×8空间占用描述笔形，忽略64点的起笔方向；仅供B/D二次判别。"""
    points = np.rint(feature.reshape(64, 2) * 255).astype(np.uint8)
    histogram = np.histogram2d(
        points[:, 0], points[:, 1], bins=8, range=((0, 256), (0, 256))
    )[0].astype(np.float32).reshape(-1)
    # L2归一化只比较空间分布；不保留起笔顺序，也不替换128维原始轨迹特征。
    return histogram / max(1.0, float(np.linalg.norm(histogram)))


def predict_pen_from_feature(model: BaselineModel, feature: np.ndarray, bd_shape: bool = False) -> str:
    """保留原基线；仅在其判为B/D时可选用不依赖路径顺序的B/D笔形复核。"""
    prediction = model.predict_from_feature(feature)
    if not bd_shape or prediction not in ("B", "D"):
        return prediction
    mask = np.isin(model.labels, [CLASSES.index("B"), CLASSES.index("D")])
    references = model.features[mask]
    reference_labels = model.labels[mask]
    if len(references) == 0:
        return prediction
    query_shape = _shape_histogram(feature)
    distances = [np.mean((_shape_histogram(item) - query_shape) ** 2) for item in references]
    return CLASSES[int(reference_labels[int(np.argmin(distances))])]


def train_and_validate(
    train_records: list[tuple], val_records: list[tuple], bd_shape: bool = False,
    *, mode: str = "PEN",
) -> tuple[BaselineModel, dict]:
    """固定62类顺序，拒绝模式/场次混用及完全重复的训练与验证轨迹。"""
    if mode not in MODES:
        raise ValueError("训练模式须为PEN或HAND")
    if bd_shape and mode != "PEN":
        raise ValueError("B/D形状复核仅在PEN验证过，不用于HAND")
    for name, records in (("训练", train_records), ("验证", val_records)):
        if not records or {item[1] for item in records} != {mode}:
            raise ValueError(f"{name}集必须仅含{mode}样本")
        missing = set(CLASSES) - {item[0] for item in records}
        if missing:
            raise ValueError(f"{name}集缺少{len(missing)}个字符类别")
    # 验证集只评估、不进入模板库；场次隔离和逐轨迹查重共同避免训练数据泄漏。
    train_sessions = {item[2] for item in train_records}
    val_sessions = {item[2] for item in val_records}
    if train_sessions & val_sessions:
        raise ValueError("训练与验证场次不得重叠")
    train_points = {item[3].tobytes() for item in train_records}
    if any(item[3].tobytes() in train_points for item in val_records):
        raise ValueError("训练与验证存在完全重复的轨迹")

    model = BaselineModel(
        np.stack([item[3] for item in train_records]),
        np.array([CLASSES.index(item[0]) for item in train_records], dtype=np.uint8),
        input_mode=mode,
    )
    confusion = {label: Counter() for label in CLASSES}
    errors = []
    # line是载入后的样本序号，不是跳过空行前的JSONL物理行号。
    # 这里严格区分大小写；游戏中的容错判题不会放宽训练报告准确率。
    for line, (label, _, _, feature) in enumerate(val_records, start=1):
        predicted = predict_pen_from_feature(model, feature, bd_shape=bd_shape)
        confusion[label][predicted] += 1
        if predicted != label:
            errors.append({"line": line, "label": label, "prediction": predicted})

    def summary(chars: str) -> dict:
        total = sum(sum(confusion[label].values()) for label in chars)
        correct = sum(confusion[label][label] for label in chars)
        return {"correct": correct, "total": total, "accuracy": correct / total}

    report = {
        "evaluation": f"Independent {mode} validation; not final test or cross-writer result",
        "mode": mode,
        "inference_variant": "nearest_with_bd_shape_probe" if bd_shape else "nearest_baseline",
        "classes": CLASSES,
        "train_count": len(train_records),
        "val_count": len(val_records),
        "train_sessions": sorted(train_sessions),
        "val_sessions": sorted(val_sessions),
        "train_writers_note": "Writer identifiers remain in source JSONL; compare writers before claiming generalization",
        "train_per_class": dict(Counter(item[0] for item in train_records)),
        "val_per_class": dict(Counter(item[0] for item in val_records)),
        "train_duplicate_count": len(train_records) - len(train_points),
        "val_duplicate_count": len(val_records) - len({item[3].tobytes() for item in val_records}),
        "overall": summary(CLASSES),
        "groups": {
            "digit": summary(CLASSES[:10]),
            "uppercase": summary(CLASSES[10:36]),
            "lowercase": summary(CLASSES[36:]),
        },
        "case_only_errors": sum(
            item["label"].lower() == item["prediction"].lower()
            for item in errors
        ),
        "per_class": {label: summary(label) for label in CLASSES},
        "confusion": {label: dict(confusion[label]) for label in CLASSES},
        "errors": errors,
    }
    return model, report


def train_and_validate_pen(
    train_records: list[tuple], val_records: list[tuple], bd_shape: bool = False
) -> tuple[BaselineModel, dict]:
    """保留原PEN函数接口供现有回归/调用使用；只委托统一实现，不复制算法。"""
    return train_and_validate(train_records, val_records, bd_shape=bd_shape, mode="PEN")


def main() -> None:
    parser = argparse.ArgumentParser(description="PEN/HAND分模式62类基线训练与独立验证")
    parser.add_argument("--mode", choices=MODES, default="PEN", help="训练模式；默认PEN，HAND单独建模")
    parser.add_argument("--train", type=Path, required=True, help="训练JSONL")
    parser.add_argument("--val", type=Path, required=True, help="独立验证JSONL")
    parser.add_argument("--output", type=Path, required=True, help="新模型.npz")
    parser.add_argument("--report", type=Path, required=True, help="新报告.json")
    parser.add_argument("--bd-shape", action="store_true", help="仅对B/D启用空间笔形复核试验")
    args = parser.parse_args()
    try:
        if not args.train.is_file() or not args.val.is_file():
            raise ValueError("训练和验证输入必须是现有JSONL文件")
        if args.output.exists() or args.report.exists():
            raise ValueError("模型和报告输出不得覆盖现有文件")
        if args.output.suffix != ".npz" or args.report.suffix != ".json":
            raise ValueError("模型须为.npz，报告须为.json；使用不同的新输出路径")
        model, report = train_and_validate(
            load_records(args.train), load_records(args.val), bd_shape=args.bd_shape, mode=args.mode
        )
        # 报告保留输入指纹、版本和选项，搬走源码/数据/模型后仍可对照复现。
        report["train_sha256"] = hashlib.sha256(args.train.read_bytes()).hexdigest()
        report["val_sha256"] = hashlib.sha256(args.val.read_bytes()).hexdigest()
        report["train_path"] = str(args.train.resolve())
        report["val_path"] = str(args.val.resolve())
        report["numpy_version"] = np.__version__
        report["feature_version"] = 1
        report["bd_shape"] = args.bd_shape
        # B/D复核是评估/推理选项，不写入NPZ；部署时仍须显式选择相同选项。
        model.save(args.output)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        with args.report.open("x", encoding="utf-8", newline="\n") as stream:
            stream.write(json.dumps(report, ensure_ascii=True, indent=2) + "\n")
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(json.dumps(report["overall"], ensure_ascii=True))


if __name__ == "__main__":
    main()
