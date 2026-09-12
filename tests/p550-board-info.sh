#!/usr/bin/env bash
# p550-board-info.sh — HiFive Premier P550 系统/板卡身份快照（只读，无需 sudo）
#
# 目的: 一次性抓齐"真机证据" —— 板卡型号、固件/引导链、存储、内存、首次启动状态。
#       这些是 QEMU 侧生成不了的数据（SOW 要的"真实硬件行为差异"）。
#
# 机器可读输出（供 run-board-tests.sh 解析）:
#   MODEL= COMPATIBLE= KERNEL= OS= OS_ID= ROOTDEV= MEM= NPROC= EFI=
#   BOARDINFO_STATUS=PASS
set -u

read_dt() { [ -r "$1" ] && tr -d '\0' <"$1" 2>/dev/null | tr -s ' \n' ' '; }

echo "===== uname ====="
uname -a
echo

echo "===== 发行版 ====="
if [ -r /etc/os-release ]; then
  grep -E '^(PRETTY_NAME|VERSION_ID|ID)=' /etc/os-release
fi
echo

echo "===== 板卡身份（设备树）====="
MODEL=$(read_dt /sys/firmware/devicetree/base/model)
COMPATIBLE=$(read_dt /sys/firmware/devicetree/base/compatible)
echo "model:      ${MODEL:-<无>}"
echo "compatible: ${COMPATIBLE:-<无>}"
echo

echo "===== 引导链 / 固件 ====="
if [ -d /sys/firmware/efi ]; then EFI=yes; else EFI=no; fi
echo "EFI stub 启动(UEFI 变量表存在): $EFI"
echo "内核命令行: $(cat /proc/cmdline 2>/dev/null)"
echo "/sys/firmware 内容: $(ls /sys/firmware 2>/dev/null | tr '\n' ' ')"
if [ -d /sys/firmware/devicetree/base/chosen ]; then
  echo "chosen/bootargs: $(read_dt /sys/firmware/devicetree/base/chosen/bootargs)"
fi
echo

echo "===== 存储 ====="
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT 2>/dev/null || echo "(lsblk 不可用)"
echo

echo "===== 内存 / CPU ====="
free -h 2>/dev/null | head -2
NPROC=$(nproc 2>/dev/null || echo 0)
echo "nproc: $NPROC"
echo

echo "===== 首次启动痕迹 ====="
if command -v cloud-init >/dev/null 2>&1; then
  echo "cloud-init: $(cloud-init status 2>/dev/null | head -1)"
else
  echo "cloud-init: 未安装"
fi
echo "开机时长: $(uptime -p 2>/dev/null || uptime)"

echo
# ---------- 机器可读汇总 ----------
OS_NAME=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")
OS_ID=$(. /etc/os-release 2>/dev/null && echo "${ID:-unknown}")
echo "MODEL=${MODEL:-unknown}"
echo "COMPATIBLE=${COMPATIBLE:-unknown}"
echo "KERNEL=$(uname -r)"
echo "OS=${OS_NAME:-unknown}"
echo "OS_ID=${OS_ID:-unknown}"
echo "ROOTDEV=$(findmnt -no SOURCE / 2>/dev/null || echo unknown)"
echo "MEM=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')"
echo "NPROC=$NPROC"
echo "EFI=$EFI"
echo "BOARDINFO_STATUS=PASS"
