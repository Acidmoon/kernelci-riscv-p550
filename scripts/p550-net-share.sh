#!/usr/bin/env bash
# p550-net-share.sh — 本机(有线网口) ↔ P550 直连共享网络
#
# 背景（为什么不用校园网直连）:
#   校园网通常需要 Portal/客户端认证或 MAC 注册，且接入交换机常开客户端隔离，
#   未认证设备插上就不通。所以让本机完成认证，P550 通过本机 NAT 出去最稳。
#
# 子命令:
#   status            查看网口/共享连接/默认路由/板子邻居
#   setup [iface]     创建并启用共享连接（省略 iface 则自动挑空闲有线网口）
#   find              在共享网段里找板子 IP
#   ssh-hint          打印 ~/.ssh/config 的 p550 片段
#   write-ssh-config  把 p550 片段追加进 ~/.ssh/config（自动备份，重复不写）
#   teardown          停用并删除共享连接
#   help
#
# 依赖: NetworkManager(nmcli)、dnsmasq-base（shared 模式需要）、可选 arp-scan
set -u

CON=${CON:-p550-shared}
SUBNET=${SUBNET:-10.42.0}

info() { printf '[info] %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
die() { printf '[err ] %s\n' "$*" >&2; exit 1; }

need_nmcli() { command -v nmcli >/dev/null 2>&1 || die "找不到 nmcli（本机没装 NetworkManager？）"; }

ethernet_devices() {
  nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="ethernet"{print $1}'
}

pick_iface() {
  local def dev
  def=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
  for dev in $(ethernet_devices); do
    [ "$dev" = "$def" ] && continue
    echo "$dev"
    return 0
  done
  return 1
}

con_iface() {
  nmcli -t -f connection,device,state device status 2>/dev/null \
    | awk -F: -v c="$CON" '$1==c{print $2; exit}'
}

cmd_status() {
  need_nmcli
  echo "=== 网口 ==="
  nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status
  echo
  echo "=== 共享连接 ($CON) ==="
  if nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$CON"; then
    nmcli -t -f connection,device,ip4.address connection show "$CON" 2>/dev/null || true
    nmcli -g IP4.ADDRESS,IP4.METHOD connection show "$CON" 2>/dev/null | paste -sd' ' -
  else
    echo "未创建（可运行: $0 setup）"
  fi
  echo
  echo "=== 默认路由（应仍走 WiFi/校园网）==="
  ip route show default
  echo
  echo "=== 板子邻居（共享网段 $SUBNET.0/24）==="
  local found=0
  for d in $(ethernet_devices); do
    if ip neigh show dev "$d" 2>/dev/null | grep -q "^$SUBNET\."; then
      ip neigh show dev "$d" | grep "^$SUBNET\."
      found=1
    fi
  done
  [ "$found" = 0 ] && echo "（暂时没看到 $SUBNET.x，板子上电并 DHCP 成功后运行: $0 find）"
}

cmd_setup() {
  need_nmcli
  local iface=${1:-}
  if [ -z "$iface" ]; then
    iface=$(pick_iface) || die "找不到空闲有线网口。可用: $(ethernet_devices | paste -sd' ')；或手动指定: $0 setup <网口>"
    info "自动选中网口: $iface"
  fi
  ip link show "$iface" >/dev/null 2>&1 || die "网口 $iface 不存在"

  command -v dnsmasq >/dev/null 2>&1 \
    || warn "未找到 dnsmasq：shared 模式需要它，请先 sudo apt install -y dnsmasq-base"

  if nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$CON"; then
    info "连接 $CON 已存在，更新网口绑定后启用"
    nmcli con modify "$CON" ifname "$iface" ipv4.method shared
  else
    info "创建连接 $CON（ipv4.method shared）"
    nmcli con add type ethernet ifname "$iface" con-name "$CON" ipv4.method shared
  fi
  # 防止共享网口抢走默认路由导致本机断网
  nmcli con modify "$CON" ipv4.never-default yes ipv4.ignore-auto-dns yes
  nmcli con up "$CON" || die "启用失败，检查 dnsmasq / ufw"

  echo
  cmd_status
  echo
  info "下一步: 板子上电 + 网线接板子 end0，然后运行 '$0 find'"
}

cmd_find() {
  local iface
  iface=$(con_iface)
  [ -z "$iface" ] && iface=$(pick_iface || true)
  echo "=== 邻居表 ==="
  [ -n "$iface" ] && ip neigh show dev "$iface" 2>/dev/null | grep "^$SUBNET\." || true
  echo
  echo "=== mDNS（Ubuntu 默认 avahi，能通就直接用）==="
  if getent hosts ubuntu.local >/dev/null 2>&1; then
    getent hosts ubuntu.local
  else
    echo "ubuntu.local 暂不可解析（可能未启动或不在同一二层）"
  fi
  echo
  if command -v arp-scan >/dev/null 2>&1 && [ -n "$iface" ]; then
    echo "=== arp-scan（需要 sudo）==="
    sudo arp-scan --interface="$iface" "$SUBNET.0/24" 2>/dev/null | grep -v '^$' || true
  else
    echo "（装了 arp-scan 会更准: sudo apt install -y arp-scan）"
  fi
  echo
  echo "找到板子后: ssh ubuntu@$SUBNET.<x>  或 $0 write-ssh-config"
}

board_ip() {
  local iface ip
  iface=$(con_iface)
  [ -z "$iface" ] && iface=$(pick_iface || true)
  [ -z "$iface" ] && return 1
  ip=$(ip neigh show dev "$iface" 2>/dev/null | awk -v p="^$SUBNET\\." '$1 ~ p {print $1; exit}')
  [ -n "$ip" ] || return 1
  echo "$ip"
}

cmd_ssh_hint() {
  local ip
  ip=$(board_ip) || ip="$SUBNET.<x>"
  cat <<EOF
把下面这段加到 ~/.ssh/config:

Host p550
    HostName $ip
    User ubuntu
    IdentityFile ~/.ssh/id_ed25519

然后:
  ssh-copy-id p550      # 密码用板上 cloud-init 之后你设置的密码
  ssh p550 'uname -a'
EOF
}

cmd_write_ssh_config() {
  local ip cfg="$HOME/.ssh/config"
  ip=$(board_ip) || die "还没发现板子 IP，先运行: $0 find"
  mkdir -p "$HOME/.ssh"
  touch "$cfg"
  chmod 600 "$cfg"
  if grep -qE '^Host[[:space:]]+p550([[:space:]]|$)' "$cfg"; then
    info "~/.ssh/config 里已有 Host p550，未改动（如需更新请手动编辑）"
    return 0
  fi
  cp "$cfg" "$cfg.bak.$(date +%Y%m%d-%H%M%S)"
  {
    echo ""
    echo "Host p550"
    echo "    HostName $ip"
    echo "    User ubuntu"
    echo "    IdentityFile ~/.ssh/id_ed25519"
  } >>"$cfg"
  info "已写入 Host p550（HostName=$ip），原文件已备份为 $cfg.bak.*"
  info "测试: ssh p550 'uname -m; ip -br a'"
}

cmd_teardown() {
  need_nmcli
  nmcli con down "$CON" 2>/dev/null || true
  nmcli con delete "$CON" 2>/dev/null || true
  info "已停用并删除连接 $CON"
}

case "${1:-status}" in
  status) cmd_status ;;
  setup) shift; cmd_setup "${1:-}" ;;
  find) cmd_find ;;
  ssh-hint) cmd_ssh_hint ;;
  write-ssh-config) cmd_write_ssh_config ;;
  teardown) cmd_teardown ;;
  help | -h | --help)
    sed -n '2,25p' "$0"
    ;;
  *)
    die "未知子命令: $1（试 $0 help）"
    ;;
esac
