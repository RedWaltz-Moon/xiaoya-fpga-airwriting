# 独立轨迹识别与UART回传

`pen_uart_reply.py` 接收 FPGA 确认后的64点轨迹，加载 NPZ 最近模板模型，预测一个字符，并用同一序号回传。单个脚本可复制运行，内置协议、CRC、特征和分类器，不依赖采集、训练或游戏目录。

脚本名中的 PEN 表示现有模型来源；PEN/HAND 轨迹均可使用该模型，脚本不能从 V1 帧判断板端模式。

[快速开始](#quick-start) · [模型策略](#model) · [UART协议](#uart) · [游戏接入](#game) · [许可证](#license)

<a id="environment"></a>

## 环境与输入输出

- NumPy、pyserial；不需要 pygame、PyTorch、YOLO、GPU 或 NPU。
- 输入：覆盖全部62类的 PEN 或兼容的无模式字段 NPZ，以及115200 8N1的 V1轨迹。
- 输出：终端预测信息、11字节结果帧；不会生成训练数据、模型或学习成绩档案。
- 不会自动安装依赖。当前主机推理已用于 Windows 与香橙派 Python 3.9.2；其他环境需要验证。

模型原理、当前模板与报告见[模型说明](../../models/README.md)。

<a id="quick-start"></a>

## 快速开始

从项目根目录执行，COM3换成实际端口：

```bash
python tools/trajectory_infer/pen_uart_reply.py COM3 --model models/pen_tr01_to_val01_62_baseline.npz --bd-shape
```

Linux可用：

```bash
python3 tools/trajectory_infer/pen_uart_reply.py /dev/ttyUSB0 --model models/pen_tr01_to_val01_62_baseline.npz --bd-shape
```

端口必须显式指定，不提供交互选择。启动前关闭游戏、采集器、串口助手和其他串口服务。

| 模式 | 书写 | 确认 | 下一笔清空 |
| --- | --- | --- | --- |
| PEN | 红笔头 | S4/红外4 | S3/红外3 |
| HAND | 佩戴绿手套，伸出单食指 | 比耶 | 五指张开 |

确认后 FPGA 进入 WAIT，收到合法回传后进入 DONE并显示字符；清空后再写下一字。Ctrl+C停止服务。HAND的S3/S4用于阈值调整，不是清空/确认。

<a id="model"></a>

## 模型与策略

使用128维特征、最近模板距离，输出62类之一。无效短轨迹不编造字符；有效但不属于62类的形状仍可能被归为最近字符，当前没有通用拒识。

`--bd-shape` 只在初始结果为大写B或D时启用8×8空间笔形复核；去掉参数恢复纯最近模板基线。加载带 `bdshape_probe` 名称的NPZ不等于自动开启复核。

加载器检查类别顺序、特征版本、完整62类及训练模式。随附模型无 `input_mode` 字段，仍可加载；新 PEN 模型可加载，标为 HAND 的新模型会拒绝。**这限制的是模型来源，不是 HAND 轨迹输入。**

PEN/HAND共用模板不意味着HAND与PEN识别率相同；当前报告仅针对PEN采集数据。游戏对C/c、S/s、O/o、Z/z的题目容错位于游戏层，不在本工具中修改预测值。

<a id="uart"></a>

## UART与异常处理

上行138字节，包含64个8位XY点；下行11字节，包含一个ASCII数字或英文字母。CRC16初值FFFF、多项式1021，覆盖version至载荷，CRC低字节先发。

```text
上行：A5 5A 01 01 seq 40 80 00 [x0 y0 ... x63 y63]  crc_lo crc_hi
下行：A5 5A 01 81 seq 01 01 00 ascii                crc_lo crc_hi
```

- 格式/CRC不合法帧不产生识别结果；坐标跨度小于4时拒绝回传。
- 半帧等待1秒后丢弃，串口异常2秒后重连；恢复后在FPGA清空重写。
- seq是8位协议号，复位归零或回绕正常，不能当作累计字符数。
- 本独立服务对每个合法输入帧回传，不提供游戏层的去重导航/计分策略。
- 若仍停在WAIT，检查端口/线缆/CRC及终端异常，恢复后清空重写，不能把WAIT当作模型已经判错。

<a id="game"></a>

## 与游戏的关系

游戏调用本脚本的模型/协议函数，但使用自己的后台服务处理事件、日志和页面。正常玩游戏只需：

```bash
python3 orange_pi_game/start.py --windowed
```

该命令从项目根目录执行；游戏目录内可执行 `python3 start.py --windowed`。**不要同时开本独立串口服务。**

<a id="portability"></a>

## 单脚本迁移与检查

只复制脚本与需要的模型，使用实际模型路径：

```bash
python pen_uart_reply.py COM3 --model models/model.npz --bd-shape
python pen_uart_reply.py --help
```

<a id="license"></a>

## 许可证

自研代码及项目随附模型采用 [MIT License](../../LICENSE)，Copyright (c) 2026 RedWaltz。第三方模型和依赖保留原许可。
