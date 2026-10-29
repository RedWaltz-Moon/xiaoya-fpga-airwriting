"""简短启动入口：复用现有游戏，固定验收模型和B/D复核，不改识别逻辑。"""

import argparse
import os
import sys
from pathlib import Path


# 入口位于orange_pi_game内，模型、工具和既有用户数据仍位于上一级项目根目录。
# 不依赖终端当前目录，避免脚本移动后误找模型或新建另一份学习档案。
ROOT = Path(__file__).resolve().parent.parent
MODEL = ROOT / "models/pen_tr01_to_val01_62_baseline.npz"


def choose_port():
    """只枚举端口、不打开设备；由用户选择，避免误连其他串口设备。"""
    from serial.tools import list_ports

    ports = sorted(list_ports.comports(), key=lambda port: port.device)
    for index, port in enumerate(ports, 1):
        print(f"{index}. {port.device} — {port.description}")
    if not ports:
        print("未枚举到串口，请检查连接；也可以手动输入端口名。")
    answer = input("输入串口编号或端口名：").strip()
    # 数字视为列表编号，其他输入视为完整设备名；枚举失败时仍可手填Linux设备路径。
    if answer.isdecimal():
        index = int(answer) - 1
        if 0 <= index < len(ports):
            return ports[index].device
        raise ValueError("串口编号不在列表内")
    if not answer:
        raise ValueError("未选择串口")
    return answer


def main(argv=None):
    parser = argparse.ArgumentParser(description="小芽游戏启动：列出串口，人工选择后进入游戏")
    parser.add_argument("port", nargs="?", help="串口名；省略时交互选择")
    parser.add_argument("--windowed", action="store_true", help="窗口模式，默认全屏")
    args = parser.parse_args(argv)
    if not MODEL.is_file():
        parser.error(f"部署文件缺失：{MODEL}")
    try:
        # 直接执行子目录脚本时，将项目根目录加入模块搜索路径。
        # 工作目录固定到项目根目录，保留既有logs/game及其他相对路径的含义。
        if str(ROOT) not in sys.path:
            sys.path.insert(0, str(ROOT))
        game_args = [
            "--port", args.port or choose_port(), "--model", str(MODEL), "--bd-shape"]
        # 短入口使用真实串口与既定模型；不悄悄切换到回放或固定字符演示。
        if args.windowed:
            game_args.append("--windowed")
        os.chdir(ROOT)
        from orange_pi_game.app import main as run_game
        return run_game(game_args)
    except (EOFError, KeyboardInterrupt):
        print("已取消启动。")
        return 130
    except (ImportError, OSError, ValueError) as error:
        print(f"启动失败：{error}；请检查已有环境和部署文件，未安装软件。", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
