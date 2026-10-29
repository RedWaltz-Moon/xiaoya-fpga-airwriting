# 空中书写轨迹数据

本目录保存通过 FPGA 采集、人工标注的字符轨迹，用于训练与验证主机识别模型。它不是游戏运行日志，也不包含模型文件。

游戏使用已训练好的 `models/pen_tr01_to_val01_62_baseline.npz`；正常运行游戏无需携带本目录。请保留数据备份，以便重新训练、评估或追溯模型来源。

[数据概览](#dataset) · [记录格式](#format) · [采集续采](#collection) · [训练产出](#training) · [数据许可](#license)

<a id="dataset"></a>

## 数据集概览

```text
data/
├── README.md
└── full/
    ├── train/
    │   └── pen_p01_tr01.jsonl
    └── val/
        └── pen_p01_val01.jsonl
```

| 文件 | 用途 | 采集者 | 场次 | 模式 | 样本数 | 每类样本数 |
| --- | --- | --- | --- | --- | --- | --- |
| `full/train/pen_p01_tr01.jsonl` | 训练集 | p01 | tr01 | PEN | 930 | 15 |
| `full/val/pen_p01_val01.jsonl` | 独立采集场次验证集 | p01 | val01 | PEN | 310 | 5 |

以上统计核对于 2026-10-09。两份文件各覆盖 62 类字符，类别顺序固定为：

```text
0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz
```

标签严格区分大小写。游戏对部分形似字母的模糊匹配不改变数据标签或模型类别。

现有数据全部来自 PEN 采集；游戏允许 PEN/HAND 共用现有模型，不意味着已有专门的 HAND 数据集或 HAND 准确率评估。验证集已用于模型评估与选型，不应当作未见过的最终测试集；跨人或最终泛化评估需要另外采集。

<a id="format"></a>

## 数据格式

使用 UTF-8 JSONL，每行是一个完整样本，不是整个文件外包一层 JSON 数组。

| 字段 | 含义 |
| --- | --- |
| `timestamp_utc` | 保存时的 UTC 时间 |
| `writer` | 采集者编号，例如 p01 |
| `session` | 采集场次，例如 tr01、val01 |
| `mode` | 人工指定的 PEN/HAND 来源；UART V1 本身没有模式字段 |
| `label` | 人工输入的真实单字符标签 |
| `class_index` | 标签在固定 62 类顺序中的索引 |
| `sequence` | FPGA 的 8 位帧序号，会回绕，复位后可能归零，不是样本累计数 |
| `points` | 64 组 `[x, y]`，每轴为 0～255 整数归一化坐标 |
| `raw_frame_hex` | 原始 UART 帧的十六进制字符串，用于协议与 CRC 核对 |

请勿单独修改标签、索引、点列或原始帧，使记录内部不一致。补采时使用采集工具追加；修订数据前先备份，并记录修订原因。

<a id="collection"></a>

## 采集与续采

在项目根目录、具有 pyserial 的 Python 环境中执行：

```bash
python tools/trajectory_collect/collect.py data/full/train/pen_p01_tr01.jsonl --writer p01 --session tr01 --mode PEN
```

未指定端口时列出串口供选择。写一个字符并在 FPGA 确认后，人工输入真实标签、回车保存，再清空并写下一个。

相同文件、采集者、场次与模式可使用相同命令续采，恢复总数和每类计数。FPGA 复位不会重置文件中的计数。已有数据已采集完成，不需要为运行游戏重新采集。

训练、验证、最终测试分别使用不同场次与输出文件，不要把训练记录复制进验证或测试集。详细操作见[采集工具说明](../tools/trajectory_collect/README.md)。

<a id="training"></a>

## 训练与产出

在项目根目录、具有 NumPy 的 Python 环境中执行：

```bash
python tools/trajectory_train/train.py --mode PEN --train data/full/train/pen_p01_tr01.jsonl --val data/full/val/pen_p01_val01.jsonl --output models/pen_new_62.npz --report models/pen_new_62_report.json
```

训练只读输入数据，生成新的 NPZ 模型和 JSON 评估报告；已有输出文件会拒绝覆盖。以上命令是按需重新训练示例，不是游戏启动步骤。Windows 使用 `python`，Linux 可使用 `python3`。

更多校验规则、评估口径及环境要求见[训练工具说明](../tools/trajectory_train/README.md)。

<a id="related"></a>

## 相关目录

| 位置 | 内容 | 是否为游戏必需 |
| --- | --- | --- |
| `data/` | 人工标签的训练/验证轨迹 | 否，仅采集、训练和评估时需要 |
| `models/` | 已训练模型与评估报告 | 需要游戏选用的模型，报告非运行依赖 |
| `logs/game/` | 游戏接入期间的串口、预测、回传和异常日志 | 否，运行时生成，主要用于排错 |
| `user_data/learning.json` | 星星、练习数、通关、错题和电子黑板 | 自动生成；保留才能延续学习记录 |

游戏日志里的预测字符不是人工真值，不能直接当作训练标签。清理日志不会删除本目录数据、模型或学习档案；清理数据也不会重置游戏进度，但会失去重训和复现依据。

<a id="license"></a>

## 许可证与隐私

- 不要把尚未备份的原始采集文件当作缓存删除。
- 发布前核对轨迹、采集者编号、时间等信息是否适合公开；日志还可能包含端口与本机路径。
- 新增其他采集者的数据前，确认公开与再分发许可；不要把未获授权的外部数据混入发行包。
- 样本统计只描述规模与类别覆盖，不代表识别准确率或跨人泛化能力。

本目录数据集采用 [MIT License](../LICENSE)，Copyright (c) 2026 RedWaltz。再分发时请保留版权与许可声明；单独发布本目录时，一并附上项目根目录的 LICENSE。第三方数据不由本项目重新授权。
