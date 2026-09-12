#!/usr/bin/env bash
# p550-kvm-setup.sh — 让真机 Hypervisor 测试可以被自动化跑起来（在**板子上**以 root 执行）
#
# 背景:
#   P550 是唯一带 H 扩展的真机，`kvm.ko` 也在，但:
#     1) /dev/kvm 默认是 crw------- root root → 普通用户/CI 打不开
#     2) kvm 模块默认不加载（重启后 /dev/kvm 就消失）
#   本脚本做三件标准、可逆的事:
#     - /etc/modules-load.d/kvm.conf          开机自动加载 kvm
#     - /etc/udev/rules.d/60-p550-kvm.rules   /dev/kvm 归 kvm 组、0660
#     - usermod -aG kvm <用户>                 让该用户可以打开 /dev/kvm
#
# 用法（在板上）:
#   sudo bash p550-kvm-setup.sh             # 应用（用户默认取 $SUDO_USER，否则 ubuntu）
#   sudo bash p550-kvm-setup.sh --user bob  # 指定要加入 kvm 组的用户
#   sudo bash p550-kvm-setup.sh --status    # 只看状态
#   sudo bash p550-kvm-setup.sh --undo      # 完全撤销（三个改动全部还原）
#
# 安全性: 只影响 /dev/kvm 权限与 kvm 模块加载，不碰网络/SSH/登录/密码。
set -u

MODLOAD=/etc/modules-load.d/kvm.conf
UDEVRULE=/etc/udev/rules.d/60-p550-kvm.rules
TARGET_USER=${SUDO_USER:-ubuntu}

while [ $# -gt 0 ]; do
  case "$1" in
    --user) TARGET_USER=$2; shift 2 ;;
    --user=*) TARGET_USER=${1#*=}; shift ;;
    --status) ACTION=status; shift ;;
    --undo) ACTION=undo; shift ;;
    -h | --help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done
ACTION=${ACTION:-apply}

[ "$(id -u)" = 0 ] || { echo "需要 root（sudo bash $0）"; exit 1; }

status() {
  echo "== 状态 =="
  printf 'modules-load 文件 : %s\n' "$([ -f "$MODLOAD" ] && echo 存在 || echo 缺失)"
  printf 'udev 规则         : %s\n' "$([ -f "$UDEVRULE" ] && echo 存在 || echo 缺失)"
  printf 'kvm 模块          : %s\n' "$(lsmod | grep -q '^kvm ' && echo 已加载 || echo 未加载)"
  printf '/dev/kvm          : %s\n' "$([ -e /dev/kvm ] && ls -l /dev/kvm | awk '{print $1, $3, $4}' || echo 不存在)"
  printf '用户在 kvm 组     : %s\n' "$(id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx kvm && echo 是 || echo 否)"
}

case "$ACTION" in
  status)
    status
    ;;

  apply)
    echo "== 应用一次性配置（用户: $TARGET_USER）=="

    echo kvm >"$MODLOAD"
    echo "  + $MODLOAD"

    cat >"$UDEVRULE" <<'EOF'
# /dev/kvm 归 kvm 组，允许组内用户使用（Debian/Ubuntu qemu-kvm 包的标准做法）
KERNEL=="kvm", GROUP="kvm", MODE="0660"
EOF
    echo "  + $UDEVRULE"

    if getent group kvm >/dev/null 2>&1; then
      usermod -aG kvm "$TARGET_USER" && echo "  + $TARGET_USER 加入 kvm 组（新登录会话生效）"
    else
      echo "  ! 系统没有 kvm 组，跳过加组"
    fi

    udevadm control --reload-rules 2>/dev/null && udevadm trigger 2>/dev/null
    modprobe kvm 2>/dev/null && echo "  + kvm 模块已加载"
    sleep 1
    echo
    status
    echo
    echo "验证: sudo -u $TARGET_USER test -r /dev/kvm && echo 可读"
    echo "注意: 组成员身份对**新登录会话**生效；已有 SSH 会话需重连。"
    ;;

  undo)
    echo "== 撤销 =="
    rm -f "$MODLOAD" && echo "  - $MODLOAD"
    rm -f "$UDEVRULE" && echo "  - $UDEVRULE"
    gpasswd -d "$TARGET_USER" kvm >/dev/null 2>&1 && echo "  - $TARGET_USER 移出 kvm 组"
    udevadm control --reload-rules 2>/dev/null
    udevadm trigger 2>/dev/null
    echo "  （kvm 模块如需卸载: modprobe -r kvm）"
    echo
    status
    ;;

  *)
    echo "未知动作: $ACTION"; exit 1 ;;
esac
