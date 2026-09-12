#!/usr/bin/env bash
# riscv-hypervisor.sh — 真机 Hypervisor(H/KVM) 测试（板子侧）
#
# 为什么重要: SOW 点名的扩展轴是 Vector 与 Hypervisor。Vector 我们有 Lichee Pi 3A；
#             **H 扩展只有 P550 有**，所以这是唯一能做真机 Hypervisor 测试的平台。
#
# 依赖: 同目录下的 riscv_kvm_smoke 二进制（板子上没有 gcc，由本机交叉编译后同步过来）
#
# 判定:
#   isa 无 h              → SKIP（平台不支持，非失败）
#   /dev/kvm 不存在        → SKIP（h 有但 kvm 模块未加载；提示 sudo modprobe kvm）
#   /dev/kvm 仅 root 可用   → SKIP（提示一次性设置，见 docs/p550-bringup.md）
#   KVM 报错/退出原因不符   → FAIL
#   客户机执行并产生 MMIO 退出 → PASS
#
# 机器可读输出: HYPERVISOR_STATUS=PASS|FAIL|SKIP  /  hypervisor: PASS|FAIL|SKIP
set -u
cd "$(dirname "$0")" || exit 1

BIN=./riscv_kvm_smoke

isa_has_h() {
  local isa base
  isa=$(grep -m1 '^isa' /proc/cpuinfo 2>/dev/null | awk -F':[[:space:]]*' '{print $2}')
  [ -z "$isa" ] && return 1
  base=${isa%%_*}
  case "${base#rv64}" in *h*) return 0 ;; *) return 1 ;; esac
}

if ! isa_has_h; then
  echo "板上 isa 无 h 扩展 → 该平台无法做真机 Hypervisor 测试"
  echo "hypervisor: SKIP（无 H 扩展）"
  echo "HYPERVISOR_STATUS=SKIP"
  exit 0
fi

if [ ! -e /dev/kvm ]; then
  echo "isa 有 h，但 /dev/kvm 不存在（kvm 模块未加载）"
  echo "  修复: sudo modprobe kvm      # 可逆，重启即恢复"
  echo "hypervisor: SKIP（kvm 模块未加载）"
  echo "HYPERVISOR_STATUS=SKIP"
  exit 0
fi

[ -x "$BIN" ] || { echo "缺可执行文件 $BIN（应由本机交叉编译后同步）"; echo "hypervisor: SKIP（缺测试二进制）"; echo "HYPERVISOR_STATUS=SKIP"; exit 0; }

run_bin() { "$BIN"; }

echo "运行 $BIN ..."
set +e
out=$(run_bin 2>&1)
rc=$?
set -e 2>/dev/null || true

if [ "$rc" = 3 ]; then
  # /dev/kvm 默认 crw------- root root；尝试免密 sudo
  if sudo -n true 2>/dev/null; then
    echo "  (以 root 重试：/dev/kvm 仅 root 可用)"
    set +e
    out=$(sudo -n "$BIN" 2>&1)
    rc=$?
    set -e 2>/dev/null || true
  else
    echo "$out"
    echo "  /dev/kvm 权限不足，且无免密 sudo。一次性设置（三选一，见 docs/p550-bringup.md）:"
    echo "    A) udev 规则: KERNEL==\"kvm\", GROUP=\"kvm\", MODE=\"0660\" + 用户加入 kvm 组"
    echo "    B) sudoers 免密: ubuntu ALL=(root) NOPASSWD: $PWD/riscv_kvm_smoke"
    echo "    C) 每次手动: ssh p550 sudo modprobe kvm && ssh p550 sudo $PWD/riscv_kvm_smoke"
    echo "hypervisor: SKIP（/dev/kvm 仅 root 可用，未配置免密）"
    echo "HYPERVISOR_STATUS=SKIP"
    exit 0
  fi
fi

echo "$out"

case "$rc" in
  0) echo "hypervisor: PASS"; echo "HYPERVISOR_STATUS=PASS" ;;
  2) echo "hypervisor: SKIP（/dev/kvm 不存在）"; echo "HYPERVISOR_STATUS=SKIP" ;;
  3) echo "hypervisor: SKIP（权限不足）"; echo "HYPERVISOR_STATUS=SKIP" ;;
  *) echo "hypervisor: FAIL（退出码 $rc）"; echo "HYPERVISOR_STATUS=FAIL"; exit 1 ;;
esac
exit 0
