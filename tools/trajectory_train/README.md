# 独立轨迹模型训练与验证

`train.py` 将人工标注的64点轨迹整理为最近模板模型，并在独立场次验证集上评估。**不是神经网络训练**：没有反向传播、epoch、学习率或 GPU 要求。

模型原理、已有文件与评估结果见[模型说明](../../models/README.md)。

[快速开始](#quick-start) · [B/D复核](#bd-shape) · [输入要求](#validation) · [产出报告](#outputs) · [许可证](#license)

<a id="environment"></a>

## 独立性与环境

单个 `train.py` 即可复制运行，内置 JSONL/V1 校验、特征转换、模型和评估逻辑，不依赖采集、推理、串口或游戏代码。

建议使用 Python 3.10+ 与 NumPy；无需 pyserial、pygame、Pillow、PyTorch 或 YOLO。不会自动安装依赖。

输入为已有训练/验证 JSONL；输出为**新的 NPZ 模型与 JSON 报告**。不采集、不打开串口、不回传字符。

<a id="workflow"></a>

## 训练步骤

1. 用[采集工具](../trajectory_collect/README.md)准备训练数据和不同场次验证数据。
2. 检查人工标签与大小写，避免跨集完全重复。
3. 执行训练命令，将模板保存到新文件。
4. 阅读报告中的混淆与错误列表，再用独立推理工具实际书写测试。
5. 通过后才明确切换部署模型；游戏不会自动加载最新生成的文件。

已有完整数据见[data说明](../../data/README.md)，无需为运行游戏重训。

<a id="quick-start"></a>

## 快速开始

以下命令从项目根目录执行；Windows 使用 `python`，Linux 可使用 `python3`：

```bash
python tools/trajectory_train/train.py --mode PEN --train data/full/train/pen_p01_tr01.jsonl --val data/full/val/pen_p01_val01.jsonl --output models/pen_new_62.npz --report models/pen_new_62_report.json
```

输出路径必须尚不存在；脚本拒绝覆盖现有模型或报告。重复运行请换新名称，保留已部署模型。训练输入只读。

<a id="bd-shape"></a>

## B/D 复核评估

```bash
python tools/trajectory_train/train.py --mode PEN --train data/full/train/pen_p01_tr01.jsonl --val data/full/val/pen_p01_val01.jsonl --output models/pen_new_bdshape.npz --report models/pen_new_bdshape_report.json --bd-shape
```

只有基线预测为大写B/D时进行8×8空间笔形复核。该选项影响验证策略，不改变保存的模板，也不会把启用开关写入 NPZ；推理时仍需显式添加 `--bd-shape`。

<a id="validation"></a>

## 输入校验与特征

- CLI要求训练和验证输入都是现有 JSONL 文件。
- 所选模式只能是 PEN 或 HAND；两集均须只含该模式、覆盖全部62类。
- 两集的session集合不能重叠，不能含跨集完全相同轨迹。
- 标签/class_index/原始帧/CRC/64点列必须一致，坐标是0～255整数，轨迹最大轴跨度至少4。
- 固定类别顺序为 `0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz`。
- 特征只做 `64×2 → float32除以255 → 128维`；不再次几何归一化、旋转或重采样。
- 预测每类取最近样本的负均方距离，分数不是校准概率。

训练集内部重复会在报告中统计，但不是自动数据增强或自动合成新样本。

<a id="outputs"></a>

## 产出与报告解读

NPZ保存 `features`、`labels`、`classes`、`feature_version` 和新模型的 `input_mode`。JSON报告包括：

| 内容 | 用途 |
| --- | --- |
| overall / groups | 总体及数字、大写、小写的正确数与准确率 |
| per_class / confusion / errors | 每类表现、混淆映射和错误样本 |
| case_only_errors | 仅大小写互换的错误数 |
| train/val数量、场次、每类数量、重复数 | 核对数据覆盖与隔离 |
| 源SHA-256、输入路径、NumPy/特征版本、选项 | 记录训练来源与评估口径 |

报告 `errors.line` 是加载后的验证样本序号；有空行时不一定等于原文件物理行号。终端输出 `correct/total/accuracy`。

随附报告的基线结果为283/310，B/D复核为288/310；这些严格区分大小写，来自同一采集者的独立场次验证，不是跨人、HAND或未见最终测试成绩。验证集已用于选型，不能反复调参后仍把它称作最终测试集。

JSON为UTF-8。Windows终端查看乱码不一定代表文件损坏，可用UTF-8编辑器打开。报告包含A/a等大小写不同键，PowerShell解析时应使用支持大小写保留的 `ConvertFrom-Json -AsHashtable`，或用Python的JSON解析器。

<a id="hand"></a>

## HAND训练边界

训练脚本可以用 `--mode HAND` 生成独立 HAND 模型，但需要真实 HAND 训练/验证数据；`--bd-shape` 不接受 HAND训练。

**当前游戏/独立回传加载器不接受标为HAND的新模型**。现行方案是两种输入共用已部署的 PEN 模型，不需要另训HAND；若未来切换专用HAND模型，需要另外修改并验证加载接口，不能只生成文件便视为接入完成。

<a id="portability"></a>

## 单脚本迁移与实写测试

```bash
python train.py --mode PEN --train data/train.jsonl --val data/val.jsonl --output models/new.npz --report models/new_report.json
python train.py --help
```

训练与推理互不导入；实写测试另用[推理工具](../trajectory_infer/README.md)，指定新模型，且同一串口仅开一个服务。

<a id="license"></a>

## 许可证

自研代码及项目随附数据集、模型采用 [MIT License](../../LICENSE)，Copyright (c) 2026 RedWaltz。第三方依赖、外部数据或模型保留原许可。
