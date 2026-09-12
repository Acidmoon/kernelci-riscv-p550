#!/usr/bin/env python3
"""p550-serial-capture.py — 非交互串口抓取工具（不需要 picocom，可被脚本/AI 调用）

为什么需要它:
  - picocom 是交互式的，无法在脚本里"抓 8 秒输出然后退出"
  - 有些板子的 UART 收发器依赖 DTR/RTS 电平，纯 `stty + cat` 可能收不到任何数据
  - 需要不依赖当前会话的 dialout 组（配合 sg dialout 使用）

用法:
  # 抓单个通道 8 秒（先发一个回车，帮助把提示符打出来）
  python3 scripts/p550-serial-capture.py /dev/ttyUSB2 --seconds 8 --send-enter

  # 扫描所有 /dev/ttyUSB* 并自动判断哪个是 SoC / MCU
  python3 scripts/p550-serial-capture.py --all --seconds 5

  # 若当前会话没生效 dialout 组
  sg dialout -c 'python3 scripts/p550-serial-capture.py --all --seconds 5'

退出码: 0 = 至少一个通道有输出；1 = 全部通道无输出
"""
from __future__ import annotations

import argparse
import fcntl
import glob
import os
import re
import select
import struct
import sys
import termios
import time

SOC_PAT = re.compile(rb"U-Boot|Linux version|login:|Password:|systemd\[|ubuntu@|Booting|OpenSBI", re.I)
MCU_PAT = re.compile(rb"#cmd:|setmac|account-[gs]|boot ?mode|MCU|Carrierboard|Somboard", re.I)


def open_port(dev: str, baud: int) -> int:
    fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    iflag, oflag, cflag, lflag, _ispeed, _ospeed, cc = termios.tcgetattr(fd)
    iflag &= ~(
        termios.IGNBRK
        | termios.BRKINT
        | termios.PARMRK
        | termios.ISTRIP
        | termios.INLCR
        | termios.IGNCR
        | termios.ICRNL
        | termios.IXON
        | termios.IXOFF
        | termios.IXANY
    )
    oflag &= ~termios.OPOST
    lflag &= ~(
        termios.ECHO
        | termios.ECHONL
        | termios.ICANON
        | termios.ISIG
        | termios.IEXTEN
    )
    cflag &= ~(termios.CSIZE | termios.PARENB | termios.CRTSCTS)
    cflag |= termios.CS8 | termios.CREAD | termios.CLOCAL
    speed = getattr(termios, f"B{baud}", termios.B115200)
    termios.tcsetattr(fd, termios.TCSANOW, [iflag, oflag, cflag, lflag, speed, speed, cc])
    # 拉高 DTR + RTS：部分板卡的 UART 收发器靠这两个信号使能
    try:
        fcntl.ioctl(fd, termios.TIOCMBIS, struct.pack("I", termios.TIOCM_DTR | termios.TIOCM_RTS))
    except OSError:
        pass
    termios.tcflush(fd, termios.TCIFLUSH)
    return fd


def classify(data: bytes) -> str:
    if SOC_PAT.search(data):
        return "SoC console"
    if MCU_PAT.search(data):
        return "MCU console"
    return "未知/无输出"


def capture(dev: str, baud: int, seconds: float, sends: list[str], send_delay: float = 0.5) -> bytes:
    fd = open_port(dev, baud)
    buf = bytearray()
    try:
        for s in sends:
            os.write(fd, s.encode())
            time.sleep(send_delay)
        deadline = time.time() + seconds
        while time.time() < deadline:
            r, _, _ = select.select([fd], [], [], min(0.5, max(0.0, deadline - time.time())))
            if not r:
                continue
            try:
                chunk = os.read(fd, 4096)
            except BlockingIOError:
                continue
            except OSError:
                break
            if not chunk:
                continue
            buf += chunk
    finally:
        os.close(fd)
    return bytes(buf)


def main() -> int:
    ap = argparse.ArgumentParser(description="P550 串口非交互抓取")
    ap.add_argument("device", nargs="?", help="如 /dev/ttyUSB2")
    ap.add_argument("--all", action="store_true", help="扫描所有 /dev/ttyUSB*")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--seconds", type=float, default=6.0)
    ap.add_argument("--send", action="append", default=[], help="抓取前发送的字符串（原样，不加换行；可多次）")
    ap.add_argument(
        "--send-line",
        action="append",
        default=[],
        help="抓取前发送的一整行命令（自动补换行；可多次，按顺序执行）",
    )
    ap.add_argument("--send-delay", type=float, default=0.5, help="两条发送之间的间隔秒数（默认 0.5）")
    ap.add_argument("--send-enter", action="store_true", help="抓取前先发一个回车")
    args = ap.parse_args()

    sends = list(args.send) + [line + "\n" for line in args.send_line]
    if args.send_enter:
        sends.append("\n")

    if args.all:
        devices = sorted(glob.glob("/dev/ttyUSB*"))
    elif args.device:
        devices = [args.device]
    else:
        ap.error("需要给定设备，或用 --all")

    if not devices:
        print("没找到 /dev/ttyUSB*（板子/线没接？）", file=sys.stderr)
        return 1

    hit = False
    for dev in devices:
        print(f"--- {dev} @ {args.baud} 抓取 {args.seconds:g}s " + "-" * 20)
        try:
            data = capture(dev, args.baud, args.seconds, sends)
        except PermissionError:
            print(f"    权限不足：当前会话不在 dialout 组。")
            print(f"    临时办法: sg dialout -c 'python3 {sys.argv[0]} {dev} --seconds {args.seconds:g}'")
            print(f"    永久办法: 注销并重新登录（或重插 USB 后新开会话）")
            continue
        except OSError as exc:
            print(f"    打不开: {exc}")
            continue
        text = data.decode("utf-8", "replace").replace("\r", "")
        if text.strip():
            hit = True
            print(text[:3000])
        else:
            print("    (无输出)")
        print(f"    判定: {classify(data)}")
        print()
    return 0 if hit else 1


if __name__ == "__main__":
    sys.exit(main())
