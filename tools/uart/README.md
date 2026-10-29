# UART排错与轨迹渲染

本目录提供固定A回传、手动结果帧生成和轨迹图片渲染。它们用于区分串口链路、轨迹形状和模型问题，不是真实字符推理，也不是游戏必需组件。

[固定A回传](#fixed-a) · [手动造帧](#frame) · [轨迹渲染](#rendering) · [迁移方式](#portability) · [许可证](#license)

<a id="dependencies"></a>

## 文件与依赖

| 文件 | 作用 | 依赖 |
| --- | --- | --- |
| `m4d_uart_auto_reply.py` | 收到合法轨迹后同seq固定回传A | pyserial＋采集模块 |
| `make_result_uart_frame.py` | 打印单字符结果帧，不发送串口 | 采集模块 |
| `render_trajectory_uart.py` | 十六进制轨迹文本转PNG | Pillow＋采集模块 |
| `__init__.py` | 包标记 | 保留 |

工具均使用 UART V1 协议。辅助脚本使用相对导入，**不是单脚本自包含工具**。

<a id="portability"></a>

## 启动位置与迁移

从含 `tools/` 的项目根目录运行模块命令，不要直接用 `python tools/uart/xxx.py`。

迁移时至少保留：

```text
tools/
├── trajectory_collect/
│   └── collect.py
└── uart/
    ├── __init__.py
    ├── m4d_uart_auto_reply.py
    ├── make_result_uart_frame.py
    └── render_trajectory_uart.py
```

使用相应工具时准备其依赖；不会自动安装。Windows使用 `python`，Linux可改为 `python3`。

<a id="fixed-a"></a>

## 固定A回传：验证链路

```bash
python -m tools.uart.m4d_uart_auto_reply COM3
```

收到完整且CRC合法的轨迹后，无论写什么都回传大写A，保留原seq。FPGA应从WAIT进入DONE，显示A；具备音频功能的工程会播放回传提示音。这只说明链路可用，**不代表识别正确**。

适用于PEN/HAND确认后的同类V1帧；程序不读取板端模式。参数默认115200、半帧超时1秒、异常重连2秒，可通过 `--help` 查看。Ctrl+C退出。

运行前关闭游戏、采集器、推理工具和串口助手；一个端口只开一个服务。

<a id="frame"></a>

## 手动造帧：不打开串口

```bash
python -m tools.uart.make_result_uart_frame 0 A
```

输出：

```text
A5 5A 01 81 00 01 01 00 41 4E C1
```

参数一是0～255的seq，也可写十六进制，例如 `0x0F`；参数二是单个 `0–9/A–Z/a–z` 字符。实际回传必须取本次FPGA上行帧第5字节的seq，不要每次都用0。

造帧工具仅打印十六进制字节。需手动测试时，再由串口助手以十六进制发送；FPGA必须处于有效轨迹的WAIT接收窗口。不要直接发送字符串“A”或整个单词。

<a id="rendering"></a>

## 轨迹图片：观察笔形与时间方向

先在串口助手保存上行帧的十六进制文本，再运行：

```bash
python -m tools.uart.render_trajectory_uart test.txt -o tmp/trajectory.png
```

输入是包含 `A5 5A` 的十六进制轨迹文本，**不是采集JSONL，也不是游戏JSONL日志**。

程序生成各帧图集，并在终端显示seq、点数、范围与CRC状态。绿色标起点，红色标终点，蓝到橙显示时间方向；Y轴向下，与FPGA坐标一致。

不指定 `-o` 时，在输入文件旁生成 `原文件名_trajectory.png`。输出同名图片可能被覆盖，重要结果使用新路径或先备份。

渲染工具可显示CRC失败帧并标记FAIL，便于观察异常；**能画出来不等于协议合法**。PNG不是模型训练输入，不用图片替代原64点人工标签数据。

<a id="checks"></a>

## 不连接设备的检查

```bash
python -m tools.uart.m4d_uart_auto_reply --help
python -m tools.uart.make_result_uart_frame --help
python -m tools.uart.make_result_uart_frame 0 A
python -m tools.uart.render_trajectory_uart --help
```

真实字符识别见[推理工具](../trajectory_infer/README.md)，人工标签采集见[采集工具](../trajectory_collect/README.md)。

<a id="license"></a>

## 许可证

自研代码采用 [MIT License](../../LICENSE)，Copyright (c) 2026 RedWaltz。第三方库保留原许可。
