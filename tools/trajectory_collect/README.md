# 独立轨迹采集工具

`collect.py` 从 FPGA 串口等待确认后的64点轨迹，再由人工输入真实标签，逐笔保存 UTF-8 JSONL。保存后同序号回显人工标签，仅用于采集反馈，**不是模型预测**。

单个脚本可复制到其他目录运行；协议、CRC、标签与续采校验均已内置，不依赖训练、推理或游戏代码。

[快速开始](#quick-start) · [逐笔操作](#workflow) · [续采计数](#resume) · [数据划分](#dataset-split) · [许可证](#license)

<a id="environment"></a>

## 环境与输入输出

- 建议使用 Python 3.10+ 与 pyserial；不需要 NumPy、pygame、Pillow 或模型。
- 输入：FPGA UART V1、115200 8N1、64点轨迹，以及人工指定的 writer/session/mode/label。
- 输出：每笔一行 JSONL；立即 flush，不承诺突然断电时最后一笔已物理落盘。
- 固定标签：`0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz`，严格区分大小写。

记录包含 UTC 时间、采集者编号、场次、PEN/HAND来源、标签、类别索引、FPGA序号、64组整数坐标和原始帧。字段解释及现有数据见[数据说明](../../data/README.md)。

<a id="quick-start"></a>

## 快速开始

在项目根目录执行，Windows 使用 `python`，Linux 可使用 `python3`：

```bash
python tools/trajectory_collect/collect.py data/full/train/pen_p01_tr02.jsonl --writer p01 --session tr02 --mode PEN
```

未指定端口时列出串口，按编号选择；也可显式指定：

```bash
python tools/trajectory_collect/collect.py data/full/train/pen_p01_tr02.jsonl --writer p01 --session tr02 --mode PEN --port COM3
```

writer 使用编号，不填写真实姓名。模式由人工指定，V1没有模式字段；程序不能自动判断板端模式。关闭游戏、串口助手和其他占用该端口的服务。

<a id="workflow"></a>

## 逐笔操作

1. 等终端出现“等待下一笔”，在 FPGA 清空旧轨迹。
2. 写一个字符并确认：PEN用S4/红外4，HAND用比耶。
3. 收到轨迹后输入实际写的单字符标签，按回车保存。
4. 等下一条等待提示，再清空并书写下一字。

PEN用S3/红外3清空，HAND用五指张开清空；HAND的S3/S4是颜色阈值调节，不是清空/确认。

- 空标签回车：放弃这一笔，不保存、不回显，先清空再写。
- `:q`：在输入标签时退出；等待串口期间可用 Ctrl+C 中断。
- 标签输错未保存时可重新输入；已保存数据不要随意手工改字段，先备份再核对。
- 同批收到多帧、过短轨迹或半帧异常会拒绝/丢弃，不应给下一笔补上上一笔的标签。
- 保存完成后会等待串口静默并排除旧数据，避免迟到帧与下一标签错配。
- 若提示“JSONL已保存”但标签回显失败，先核对保存计数，不要盲目重复补录。

<a id="resume"></a>

## 续采与计数

使用相同输出文件、writer、session和mode，再运行同一命令即可恢复计数。终端显示文件累计样本数及每类数量；`sequence` 是8位协议序号，复位归零或回绕不会重置文件计数。

续采会检查已有 JSONL 的格式、标签、元数据、原始帧/CRC和点列一致性。冲突或损坏时拒绝继续追加，先备份与排错，不通过修改序号掩盖问题。

<a id="dataset-split"></a>

## 训练、验证与最终测试

建议训练15笔/类、验证5笔/类；每份完整数据覆盖62类。建议包含不同速度和正常范围内的笔形差异，不只重复同一条理想轨迹。

验证必须另开场次，不从训练集复制：

```bash
python tools/trajectory_collect/collect.py data/full/val/pen_p01_val02.jsonl --writer p01 --session val02 --mode PEN
```

最终测试再采不同场次，例如 `test02`，保留作未参与选型的评估。跨人评估需另用采集者编号；PEN/HAND来源分别记录。

现有 tr01/val01 已完整，正常游戏不必重采。若要另外采 HAND，将输出文件名和 `--mode HAND` 一起改为对应来源；当前游戏不要求新增 HAND 数据或模型。

<a id="portability"></a>

## 单脚本迁移与检查

只带 `collect.py` 即可：

```bash
python collect.py samples/pen.jsonl --writer p02 --session tr01 --mode PEN
python collect.py --help
```

依赖仍须在目标 Python 环境中准备。采集程序不会自动安装软件。

输出可交给[训练工具](../trajectory_train/README.md)。模块入口 `python -m tools.trajectory_collect.collect` 也可从项目根目录使用。

<a id="license"></a>

## 许可证

自研代码及项目随附数据集采用 [MIT License](../../LICENSE)，Copyright (c) 2026 RedWaltz。新增其他采集者的数据须确认公开授权；第三方依赖保留原许可。
