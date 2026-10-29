# 字符轨迹模型

本目录保存空中书写字符分类模型及对应验证报告。当前游戏使用 `pen_tr01_to_val01_62_baseline.npz`，支持 `0–9 / A–Z / a–z` 共 62 类。

模型在 Windows 或香橙派上使用 NumPy、CPU 推理；FPGA 只采集和处理轨迹，不运行模型。不需要 YOLO、PyTorch、GPU 或 NPU。

[模型文件](#model-files) · [算法原理](#model-type) · [重新训练](#retraining) · [验证结果](#evaluation) · [发布授权](#license)

<a id="model-files"></a>

## 模型文件

| 文件 | 用途 |
| --- | --- |
| [pen_tr01_to_val01_62_baseline.npz](pen_tr01_to_val01_62_baseline.npz) | 当前部署使用的模板库 |
| [pen_tr01_to_val01_62_baseline_report.json](pen_tr01_to_val01_62_baseline_report.json) | 原始最近模板策略验证报告 |
| [pen_tr01_to_val01_62_bdshape_probe.npz](pen_tr01_to_val01_62_bdshape_probe.npz) | B/D 复核实验留存模型，模板与基线完全相同 |
| [pen_tr01_to_val01_62_bdshape_probe_report.json](pen_tr01_to_val01_62_bdshape_probe_report.json) | 开启 B/D 笔形复核的验证报告 |

2026-10-09 核对：两份 NPZ 字节完全相同。**换成带 `bdshape_probe` 名字的文件不会自动开启复核**；复核由运行参数 `--bd-shape` 控制。

游戏的 `orange_pi_game/start.py` 固定加载基线模型，并开启 B/D 复核。独立推理脚本默认不开启，需要显式添加该参数。

### NPZ 内容

| 字段 | 当前文件内容 |
| --- | --- |
| `features` | `(930, 128)`、float32，每行一条训练轨迹 |
| `labels` | `(930,)`、uint8，类别索引 0～61 |
| `classes` | 固定字符顺序，见下方 |
| `feature_version` | 1 |
| `input_mode` | 随附模型无此字段；新训练脚本会写入 PEN/HAND |

```text
0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz
```

只加载可信来源的模型；当前加载器使用 `allow_pickle=False` 并检查类别顺序、特征版本和完整类别覆盖。

### B/D 复核

仅当基线预测为大写 B 或 D 时，将轨迹转换成 8×8 空间点数直方图，做 L2 归一化，再与 B/D 训练模板比较均方距离。该步骤弱化笔顺影响，只能在 B/D 之间重选，不改变其他字符的初始结果。

`--bd-shape` 是推理策略，不作为开关保存进 NPZ。训练时启用它改变的是验证口径和报告，而不是模板特征。

<a id="retraining"></a>

## 重新训练

所有命令在包含 `data/`、`models/`、`tools/` 的项目根目录执行。Windows 使用 `python`，Linux 可使用 `python3`；需要 NumPy，推荐在已配置的采集/训练环境中运行。

先准备训练和独立场次验证数据，参见[数据说明](../data/README.md)和[采集工具说明](../tools/trajectory_collect/README.md)。不必为了正常玩游戏重新采集或训练。

### 复现基线，输出新文件

```bash
python tools/trajectory_train/train.py --mode PEN --train data/full/train/pen_p01_tr01.jsonl --val data/full/val/pen_p01_val01.jsonl --output models/pen_new_62.npz --report models/pen_new_62_report.json
```

### 验证 B/D 复核

```bash
python tools/trajectory_train/train.py --mode PEN --train data/full/train/pen_p01_tr01.jsonl --val data/full/val/pen_p01_val01.jsonl --output models/pen_new_bdshape.npz --report models/pen_new_bdshape_report.json --bd-shape
```

输出文件必须尚不存在，脚本拒绝覆盖已有模型或报告；重复运行时换一个新名字。输入只读，不会把验证集加入训练模板。

进一步参数、报告字段与迁移方法见[训练工具说明](../tools/trajectory_train/README.md)。

<a id="testing"></a>

## 实写测试

关闭游戏和其他串口程序，把 COM3 换成实际端口：

```bash
python tools/trajectory_infer/pen_uart_reply.py COM3 --model models/pen_new_62.npz --bd-shape
```

用不同于训练数据的新笔迹测试，确认板端由 WAIT 进入 DONE，回显与识别相符，再清空写下一个。测试候选模型不会自动替换游戏默认模型；正式切换前备份旧文件，并明确修改游戏入口的模型选择。

正常游戏启动（在项目根目录）：

```bash
python orange_pi_game/start.py --windowed
```

<a id="model-type"></a>

## 模型是什么类型？

当前实现是**最近模板分类器（可理解为 1-NN 最近邻基线）**，不是卷积网络、Transformer 或其他深度学习网络。

它保存带标签的真实轨迹。遇到新轨迹时，逐一比较与训练样本的距离，选择最接近的字符：

```text
FPGA归一化并重采样为64点
        ↓
软件把64×2整数坐标除以255，展平为128维浮点向量
        ↓
计算与每条训练模板的均方距离
        ↓
每类取最小距离，返回距离最小的字符
        ↓
可选B/D笔形复核 → UART回传 / 游戏判定
```

设新轨迹向量为 `q`，某条训练模板为 `t`：

```text
distance(q, t) = mean((q - t)^2)
score(class)   = -min(distance(q, template_of_class))
prediction     = argmax(score)
```

代码输出的 62 维分数是**负距离，不是概率或校准置信度**。有效输入通常会选出一个类别；当前没有通用的“非字符/未知类别”拒识模型。

软件不额外旋转、裁剪或重采样轨迹，几何归一化已由 FPGA 完成。模板比较仍受起笔方向、笔顺、字形和输入噪声影响。

算法实现见[训练脚本](../tools/trajectory_train/train.py)与[推理脚本](../tools/trajectory_infer/pen_uart_reply.py)。

<a id="training-process"></a>

## “训练”实际做了什么？

本模型的训练不是神经网络的反向传播，也没有 epoch、学习率或优化器：

1. 读取人工标签的 JSONL，检查字段、原始帧、CRC、类别索引与点列一致性。
2. 检查训练/验证模式一致、场次不重叠、两侧覆盖全部 62 类，且没有跨集完全相同轨迹。
3. 将每条训练轨迹转换为 128 维特征，连同类别索引保存为 NPZ 模板库。
4. 使用独立场次验证数据预测，生成准确率、混淆与错误样本报告。

增加样本不会自动更新已有 NPZ；需要重新运行训练脚本，生成并验收新的模型文件。

<a id="evaluation"></a>

## 数据与验证结果

| 数据 | 来源 | 数量 |
| --- | --- | --- |
| 训练 | p01、PEN、tr01 | 930，每类15笔 |
| 验证 | p01、PEN、val01 | 310，每类5笔 |

| 策略 | 正确 / 总数 | 严格62类准确率 |
| --- | --- | --- |
| 最近模板基线 | 283 / 310 | 91.29% |
| 基线＋B/D复核 | 288 / 310 | 92.90% |

以上来自本目录随附的验证报告，严格区分大小写。两种策略均记录21次仅大小写互换错误。游戏允许 `C/c、S/s、O/o、Z/z` 在题目匹配时等价，不会篡改模型原预测，也不把严格报告改成游戏容错后的准确率。

验证数据已用于选型，不能再当作未见过的最终测试集；结果不代表跨人、跨光照、HAND 或长时间实际使用准确率。

PEN/HAND 在运行时可共用现有模型，因为 V1 输入均是64点轨迹且没有模式字段。当前模板仍来自 PEN；独立推理/游戏加载器只接受训练模式为 PEN 或缺省的模型，不接受标记为 HAND 的新模型。

<a id="license"></a>

## 发布与授权

NPZ 是游戏所需的模型，报告用于复现与评估，不是运行依赖。建议同时保留原始训练/验证数据、脚本版本和报告；报告可能记录本机路径，公开前检查。

本目录模型与验证报告采用 [MIT License](../LICENSE)，Copyright (c) 2026 RedWaltz。再分发时请保留版权与许可声明；单独发布本目录时，一并附上项目根目录的 LICENSE。第三方模型、数据或依赖仍遵循各自授权。
