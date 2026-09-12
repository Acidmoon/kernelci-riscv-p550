#!/usr/bin/env bash
# p550-serial.sh — P550 串口控制台助手（带外通道，不依赖网络）
#
# 背景:
#   P550 后置 Type-C(USB2.0) 把 JTAG + SoC debug UART + MCU UART 一起带出来，
#   在 PC 上枚举成 4 个 /dev/ttyUSB*。经验映射:
#     SoC console = 第 3 个（by-id 里的 if02，通常是 /dev/ttyUSB2）  ← 看 U-Boot/内核日志、登录
#     MCU console = 比 SoC 高一位（if03，通常 /dev/ttyUSB3）         ← ifconfig/setmac/version
#   波特率均为 115200 8N1。
#
# 子命令:
#   list                列出串口设备 + 检查 brltty 抢占
#   open [soc|mcu|N]    用 picocom 打开（默认 soc）
#   probe               逐个通道试读 3 秒并自动判断是 SoC 还是 MCU
#   help
#
# 依赖: picocom（sudo apt install -y picocom）；用户在 dialout 组中
set -u

BAUD=${BAUD:-115200}

info() { printf '[info] %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
die() { printf '[err ] %s\n' "$*" >&2; exit 1; }

all_ports() { ls /dev/ttyUSB* 2>/dev/null | sort -V; }

byid_dev() { # byid_dev <FTDI 接口号> → 稳定设备路径
  local p
  for p in /dev/serial/by-id/*-if0"$1"-port0 /dev/serial/by-id/*-if0"$1"; do
    [ -e "$p" ] && { readlink -f "$p"; return 0; }
  done
  return 1
}

resolve() {
  case "${1:-soc}" in
    soc | auto)
      byid_dev 2 || { [ -e /dev/ttyUSB2 ] && echo /dev/ttyUSB2; }
      ;;
    mcu)
      byid_dev 3 || { [ -e /dev/ttyUSB3 ] && echo /dev/ttyUSB3; }
      ;;
    /dev/*) echo "$1" ;;
    ttyUSB*) echo "/dev/$1" ;;
    [0-9]) echo "/dev/ttyUSB$1" ;;
    *) die "不认识的目标: $1（用 soc | mcu | ttyUSB2 | 2）" ;;
  esac
}

cmd_list() {
  echo "=== /dev/serial/by-id ==="
  if ls /dev/serial/by-id/ >/dev/null 2>&1; then
    ls -l /dev/serial/by-id/
  else
    echo "（无 by-id 条目）"
  fi
  echo
  echo "=== /dev/ttyUSB* ==="
  all_ports | while read -r p; do
    printf '%s -> %s\n' "$p" "$(udevadm info -q property -n "$p" 2>/dev/null | grep -E 'ID_VENDOR_ID|ID_MODEL|ID_SERIAL_SHORT' | paste -sd' ' -)"
  done
  echo
  echo "=== 经验映射 ==="
  printf 'SoC console: %s\n' "$(resolve soc || echo '<未找到>')"
  printf 'MCU console: %s\n' "$(resolve mcu || echo '<未找到>')"
  echo
  echo "=== brltty 抢占检查（Linux 上常见的 FTDI 串口被抢）==="
  if systemctl is-active brltty >/dev/null 2>&1; then
    warn "brltty 正在运行，可能抢占 /dev/ttyUSB*；建议: sudo systemctl stop brltty-udev.service && sudo apt remove -y brltty"
  else
    echo "brltty 未运行（正常）"
  fi
  echo
  echo "=== 权限 ==="
  id -nG "$USER" | tr ' ' '\n' | grep -qx dialout \
    && echo "用户在 dialout 组 ✓" \
    || warn "不在 dialout 组，串口会 permission denied：sudo usermod -aG dialout \$USER 然后注销重登"
}

cmd_open() {
  command -v picocom >/dev/null 2>&1 || die "没装 picocom: sudo apt install -y picocom"
  local dev
  dev=$(resolve "${1:-soc}")
  [ -n "$dev" ] || die "找不到设备，先跑: $0 list"
  [ -e "$dev" ] || die "设备不存在: $dev"
  info "打开 $dev @ ${BAUD}8N1（退出: Ctrl-A 然后 Ctrl-X）"
  info "提示: 先开这个终端，再按板上 PWR 键(S3)上电，才能看到完整启动日志"
  exec picocom -b "$BAUD" "$dev"
}

classify() { # classify <抓到的文本>
  local t=$1
  if echo "$t" | grep -qiE 'U-Boot|Linux version|login:|systemd\[|ubuntu@'; then
    echo "SoC console（U-Boot/内核/登录提示）"
  elif echo "$t" | grep -qiE 'setmac|account-[gs]|boot mode|MCU'; then
    echo "MCU console（ifconfig/setmac/version 命令可用）"
  else
    echo "未知（无输出或不是终端；可能板子没在打印，按回车或上电重试）"
  fi
}

cmd_probe() {
  command -v stty >/dev/null 2>&1 || die "缺 stty（coreutils/util-linux）"
  local ports p out
  ports=$(all_ports)
  [ -n "$ports" ] || die "没找到 /dev/ttyUSB*，检查 USB-C 线是否插好、是否是数据线"
  for p in $ports; do
    echo "--- $p ---"
    stty -F "$p" "$BAUD" raw -echo 2>/dev/null || { warn "打不开 $p（权限？）"; continue; }
    printf '\n' >"$p" 2>/dev/null
    out=$(timeout 3 cat "$p" 2>/dev/null | tr -d '\0' | head -c 2000)
    if [ -n "$out" ]; then
      echo "$out" | head -8
    else
      echo "(3 秒内无输出)"
    fi
    echo "判定: $(classify "$out")"
    echo
  done
  info "典型结果: if02/ttyUSB2 = SoC console, if03/ttyUSB3 = MCU console"
}

case "${1:-list}" in
  list) cmd_list ;;
  open) shift; cmd_open "${1:-soc}" ;;
  probe) cmd_probe ;;
  help | -h | --help) sed -n '2,22p' "$0" ;;
  *) die "未知子命令: $1（试 $0 help）" ;;
esac
