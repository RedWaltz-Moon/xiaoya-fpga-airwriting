# 轨迹采集、训练与串口工具

本目录提供三项独立正式工具与一组可选 UART 排错工具。采集、训练、推理通过 JSONL/NPZ 文件交接，不需要同时运行。

```text
FPGA轨迹 + 人工标签 → collect.py → JSONL
                                     ↓
                                train.py → NPZ + 评估报告
                                              ↓
FPGA确认轨迹 → pen_uart_reply.py → 同seq字符回传
```

模型是64点轨迹最近模板分类器，不是 YOLO 或神经网络；原理、当前模型与结果见[模型说明](../models/README.md)。

[工具索引](#tools) · [运行环境](#environment) · [常用命令](#quick-start) · [游戏接入](#game) · [许可证](#license)

<a id="tools"></a>

## 工具索引与独立性

| 目录 | 用途 | Python依赖 | 可单独复制 |
| --- | --- | --- | --- |
| [trajectory_collect](trajectory_collect/README.md) | FPGA轨迹＋人工标签 → JSONL | pyserial | 单个 collect.py |
| [trajectory_train](trajectory_train/README.md) | 训练/验证JSONL → NPZ＋报告 | NumPy | 单个 train.py，另带数据 |
| [trajectory_infer](trajectory_infer/README.md) | 模型＋FPGA轨迹 → 字符回传 | NumPy、pyserial | 单个 pen_uart_reply.py，另带模型 |
| [uart](uart/README.md) | 固定A回传、手动造帧、轨迹图片 | 固定A需pyserial，图片需Pillow | 需保留 tools/uart 与 tools/trajectory_collect 结构 |

三个正式脚本均内置自身协议和校验逻辑，不互相导入、不依赖游戏；同名功能的内置实现用于保持单脚本可迁移。UART 辅助工具复用采集模块，不是自包含脚本，须用模块方式启动。

游戏调用推理脚本里的模型/协议函数，并由自己的后台服务管理串口；运行游戏时不要再开独立推理服务。

<a id="environment"></a>

## 环境与命令位置

使用已配置好依赖的 Python 环境；工具不会自动安装依赖。采集与训练建议使用 Python 3.10+ 环境；当前主机推理已用于香橙派 Python 3.9.2，其他环境需验证。

以下命令均在项目根目录执行，Windows 使用 `python`，Linux 可改为 `python3`。COM3、/dev/ttyUSB0 是示例，需替换为实际端口。

`tools/` 根目录没有 `__init__.py`，使用命名空间包；模块入口仍须从含 tools 的项目根目录执行。

<a id="quick-start"></a>

## 常用操作

### 采集新场次

```bash
python tools/trajectory_collect/collect.py data/full/train/pen_p01_tr02.jsonl --writer p01 --session tr02 --mode PEN
```

省略端口会列出串口供选择，收到一笔后人工输入标签并回车保存。同文件、同参数可续采；FPGA seq归零不影响保存计数。新场次示例不改动已有 tr01 数据。

### 训练并生成新模型

```bash
python tools/trajectory_train/train.py --mode PEN --train data/full/train/pen_p01_tr01.jsonl --val data/full/val/pen_p01_val01.jsonl --output models/pen_new_62.npz --report models/pen_new_62_report.json
```

当前示例使用已有完整数据；输出必须不存在。正常游戏无需重新训练。

### 独立实写推理

```bash
python tools/trajectory_infer/pen_uart_reply.py COM3 --model models/pen_tr01_to_val01_62_baseline.npz --bd-shape
```

支持当前模型处理 PEN/HAND 的64点输入；`--bd-shape` 显式启用 B/D 复核，不是切换另一种模型。

### UART 排错

```bash
python -m tools.uart.m4d_uart_auto_reply COM3
python -m tools.uart.make_result_uart_frame 0 A
python -m tools.uart.render_trajectory_uart test.txt -o tmp/trajectory.png
```

三条命令各自独立运行：固定A验证链路，造帧只打印不发送，渲染只读取十六进制文本生成图片。详细用途见[UART说明](uart/README.md)。

<a id="game"></a>

## 与游戏的关系

在游戏目录运行 `python3 start.py --windowed`，或在项目根目录运行：

```bash
python3 orange_pi_game/start.py --windowed
```

游戏自行接收、识别、回传，不需要同时启动上述工具。游戏依赖本目录的推理脚本，但不依赖采集、训练或UART辅助目录。完整部署见[游戏说明](../orange_pi_game/README.md)。

<a id="checks"></a>

## 不连接设备的检查

```bash
python tools/trajectory_collect/collect.py --help
python tools/trajectory_train/train.py --help
python tools/trajectory_infer/pen_uart_reply.py --help
python -m tools.uart.m4d_uart_auto_reply --help
python -m tools.uart.make_result_uart_frame --help
python -m tools.uart.render_trajectory_uart --help
```

帮助检查不会采集、训练或打开串口，但不能替代真实收发与识别测试。同一串口只允许一个服务占用。

<a id="license"></a>

## 数据与许可

人工标签数据在 [data/](../data/README.md)，模型在 [models/](../models/README.md)，游戏日志与学习档案是不同运行产物。模型预测或固定A回传不是真实人工标签，不应直接当作训练数据。

自研工具代码、项目数据集和模型均采用 [MIT License](../LICENSE)，Copyright (c) 2026 RedWaltz。第三方库、外部数据和素材遵循各自授权。
