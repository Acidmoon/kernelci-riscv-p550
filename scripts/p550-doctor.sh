#!/usr/bin/env bash
# p550-doctor.sh — P550 上板前体检（本机侧）
#
# 一句话: 把"本机 ↔ P550"打通所需的条件逐项检查，缺什么直接告诉你下一步命令。
#
# 用法: bash scripts/p550-doctor.sh [ssh别名]     # 默认 p550
set -u

TARGET=${1:-p550}
OK=0
WARN=0
BAD=0
NEED=()

pass() { printf '  ✅ %s\n' "$*"; OK=$((OK + 1)); }
warn() { printf '  ⚠️  %s\n' "$*"; WARN=$((WARN + 1)); NEED+=("$*"); }
bad() { printf '  ❌ %s\n' "$*"; BAD=$((BAD + 1)); NEED+=("$*"); }
section() { printf '\n== %s ==\n' "$*"; }

section "1. 本机工具链"
for t in ssh scp picocom nmcli python3; do
  if command -v "$t" >/dev/null 2>&1; then pass "$t"; else bad "缺少 $t"; fi
done
command -v dnsmasq >/dev/null 2>&1 \
  && pass "dnsmasq（shared 模式需要）" \
  || bad "缺少 dnsmasq → sudo apt install -y dnsmasq-base"
command -v arp-scan >/dev/null 2>&1 && pass "arp-scan（可选）" || warn "没有 arp-scan（可选）→ sudo apt install -y arp-scan"

section "2. USB-C 串口（带外通道）"
PORTS=$(ls /dev/ttyUSB* 2>/dev/null | sort -V)
if [ -n "$PORTS" ]; then
  pass "串口设备: $(echo "$PORTS" | paste -sd' ' -)"
  [ -d /dev/serial/by-id ] && ls /dev/serial/by-id/ | sed 's/^/     /'
  # 注意: `id -nG` 看的是当前进程真实生效的补充组；`id -nG $USER` 查的是组数据库。
  # usermod 之后不注销重登，两者会不一致 —— 这正是"明明加了组还是权限不够"的原因。
  if id -nG | tr ' ' '\n' | grep -qx dialout; then
    pass "当前会话在 dialout 组（串口可直开）"
  elif id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx dialout; then
    bad "组数据库有 dialout 但当前会话未生效 → 注销重登；临时可用: sg dialout -c '<命令>'"
  else
    bad "不在 dialout 组 → sudo usermod -aG dialout \$USER 后注销重登"
  fi
  if systemctl is-active brltty >/dev/null 2>&1; then
    bad "brltty 在运行，会抢占 FTDI 串口 → sudo systemctl stop brltty-udev.service; sudo apt remove -y brltty"
  else
    pass "brltty 未运行"
  fi
  # ModemManager 是 Debian/Ubuntu 系上 FTDI 串口"打不开"的头号原因（Device or resource busy）
  if systemctl is-active ModemManager >/dev/null 2>&1; then
    if [ -f /etc/udev/rules.d/99-p550-serial.rules ]; then
      pass "ModemManager 在跑，但已安装忽略规则（/etc/udev/rules.d/99-p550-serial.rules）"
    else
      bad "ModemManager 在跑且无忽略规则，可能占用串口 → sudo cp udev/99-p550-serial.rules /etc/udev/rules.d/ && sudo udevadm control --reload-rules && sudo udevadm trigger，然后重插 USB-C"
    fi
  else
    pass "ModemManager 未运行"
  fi
else
  warn "没看到 /dev/ttyUSB*（板子没接？线是充电线？）→ 接好后跑 scripts/p550-serial.sh list"
fi

section "3. SSH 别名 ($TARGET)"
HOST_FROM_SSH=$(ssh -G "$TARGET" 2>/dev/null | awk '/^hostname /{print $2; exit}')
USER_FROM_SSH=$(ssh -G "$TARGET" 2>/dev/null | awk '/^user /{print $2; exit}')
if [ -n "$HOST_FROM_SSH" ] && [ "$HOST_FROM_SSH" != "$TARGET" ]; then
  pass "已配置: Host $TARGET → $USER_FROM_SSH@$HOST_FROM_SSH"
else
  warn "~/.ssh/config 里还没有 Host $TARGET → bash scripts/p550-net-share.sh write-ssh-config"
fi

section "4. 本机共享网络"
CON=${CON:-p550-shared}
if command -v nmcli >/dev/null 2>&1; then
  if nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$CON"; then
    pass "共享连接 $CON 已存在"
    nmcli -t -f connection,device,ip4.address connection show "$CON" 2>/dev/null | sed 's/^/     /'
  else
    warn "共享连接 $CON 未创建 → bash scripts/p550-net-share.sh setup"
  fi
  echo "     网口状态:"
  nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status 2>/dev/null | sed 's/^/     /'
fi
echo "     默认路由（应仍是 WiFi/校园网）:"
ip route show default | sed 's/^/     /'

section "5. 板子可达性"
if ssh -o ConnectTimeout=5 -o BatchMode=yes "$TARGET" 'echo OK' >/dev/null 2>&1; then
  pass "ssh $TARGET 直连成功"
  section "6. 板子侧关键项"
  INFO=$(ssh -o ConnectTimeout=5 "$TARGET" 'uname -r; . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"; nproc' 2>/dev/null)
  echo "$INFO" | sed 's/^/     /'

  # MAC 是否有效（SiFive 特定批次出厂未烧 MAC → 8c:00:... 或 8c:1f:00:...）
  MACS=$(ssh -o ConnectTimeout=5 "$TARGET" "ip -br link | grep -E '^(end0|end1) '" 2>/dev/null)
  if echo "$MACS" | grep -qE '8c:(00|1f):00:00:00:00'; then
    bad "板载网口 MAC 疑似未烧录（出厂批次问题）→ 见 docs/p550-bringup.md 第 4 节，用 MCU 串口 setmac 修复后完全断电重启"
  elif [ -n "$MACS" ]; then
    pass "网口 MAC 看起来正常"
    echo "$MACS" | sed 's/^/     /'
  fi

  ISA=$(ssh -o ConnectTimeout=5 "$TARGET" "grep -m1 '^isa' /proc/cpuinfo" 2>/dev/null)
  if [ -n "$ISA" ]; then
    echo "     $ISA"
    echo "     （v/h/zpm 等扩展存在性请用 tests/riscv-ext-scan.sh，别用 grep 猜）"
  fi

  if ssh -o ConnectTimeout=5 "$TARGET" 'ss -tln 2>/dev/null | grep -q ":22 "' >/dev/null 2>&1; then
    pass "板子 sshd 在监听 22"
  else
    warn "板子 22 端口没在监听 → 串口里执行: sudo systemctl enable --now ssh"
  fi
else
  warn "ssh $TARGET 不通（板子没上电/没拿到 IP/别名没配）"
fi

section "体检结果"
printf '  通过 %d 项 / 警告 %d 项 / 阻塞 %d 项\n' "$OK" "$WARN" "$BAD"
if [ ${#NEED[@]} -gt 0 ]; then
  echo
  echo "  需要你处理:"
  for n in "${NEED[@]}"; do echo "    - $n"; done
else
  echo "  全部就绪 → 直接跑: bash scripts/run-board-tests.sh"
fi
[ "$BAD" -eq 0 ]
