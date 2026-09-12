#!/usr/bin/env bash
# repro-upstream-findings.sh — **无硬件**复现 upstream-findings.md 的发现 1 / 2
#
# 原理
#   QEMU 的**用户态**模拟器支持按能力配置 CPU（`-cpu rv64,v=false`），
#   于是"一个没有 V 扩展的 RISC-V 平台"可以在本机**秒级**造出来 ——
#   不需要真机、不需要启动虚拟机、不需要 rootfs。
#   这让我们的上游发现不再依赖那块 P550，任何人都能复现。
#
# 前置（两步，都不需要 sudo）
#   1) 编一个用户态模拟器（约 2-3 分钟）：
#        mkdir -p ~/qemu-user-build && cd ~/qemu-user-build
#        /path/to/qemu-src/configure --target-list=riscv64-linux-user --disable-system --disable-docs
#        ninja                     # 产出 ./qemu-riscv64
#   2) 交叉编译 kselftest（板上没有 gcc）：
#        KERNEL_TREE=/path/to/linux bash scripts/build-kselftest.sh
#
# 用法
#   QEMU_RISCV64=~/qemu-user-build/qemu-riscv64 bash scripts/repro-upstream-findings.sh
#
# 退出码: 0 = 三条发现都复现；1 = 有未复现的；2 = 前置条件缺失
set -u
cd "$(dirname "$0")/.." || exit 1

QEMU=${QEMU_RISCV64:-$(command -v qemu-riscv64 2>/dev/null || true)}
if [ -z "$QEMU" ] || [ ! -x "$QEMU" ]; then
  cat >&2 <<'MSG'
找不到 qemu-riscv64（用户态模拟器）。构建方法（无需 sudo）：
  mkdir -p ~/qemu-user-build && cd ~/qemu-user-build
  /path/to/qemu-src/configure --target-list=riscv64-linux-user --disable-system --disable-docs
  ninja
然后: QEMU_RISCV64=~/qemu-user-build/qemu-riscv64 bash scripts/repro-upstream-findings.sh
MSG
  exit 2
fi

STAGE=build/kselftest-riscv
SIGRET="$STAGE/sigreturn/sigreturn"
VSTATE="$STAGE/vector/vstate_exec_nolibc"
VEXEC="$STAGE/vector/v_exec_initval_nolibc"
for b in "$SIGRET" "$VSTATE" "$VEXEC"; do
  [ -x "$b" ] || { echo "缺 $b（先跑: KERNEL_TREE=<linux> bash scripts/build-kselftest.sh）" >&2; exit 2; }
done

echo "== 无硬件复现上游发现（QEMU 用户态；$($QEMU --version | head -1)）=="
echo

fails=0
run() { # run <说明> <期望> <cmd...>
  local desc=$1 expect=$2; shift 2
  local out rc
  out=$(timeout 60 "$@" 2>&1); rc=$?
  printf '  %-46s exit=%-4s ' "$desc" "$rc"
  if printf '%s' "$out" | grep -q "$expect"; then
    echo "✓ 复现（匹配: $expect）"
    return 0
  fi
  echo "✗ 未复现（期望匹配: $expect）"
  printf '%s\n' "$out" | head -4 | sed 's/^/        /'
  fails=$((fails + 1))
  return 1
}

echo "--- 有 V 的对照（-cpu rv64,v=true）---"
run "sigreturn（应能运行，不 SIGILL）" "TAP version" "$QEMU" -cpu rv64,v=true "$SIGRET"
echo
echo "--- 无 V（-cpu rv64,v=false）---"
run "sigreturn（发现 1：应 SIGILL）" "signal 4" "$QEMU" -cpu rv64,v=false "$SIGRET"
run "vstate_exec_nolibc（发现 2：应 exit 255 而非 SKIP=4）" "PR_RISCV_V_GET_CONTROL is not supported" "$QEMU" -cpu rv64,v=false "$VSTATE"
# v_exec_initval_nolibc 是 core dump（无可靠输出可匹配）→ 只按退出码判断（见下）
out=$(timeout 60 "$QEMU" -cpu rv64,v=false "$VEXEC" 2>&1); rc=$?
if [ "$rc" = 132 ]; then
  echo "  v_exec_initval_nolibc 退出码 = 132（128+4 = SIGILL）✓ 复现"
else
  echo "  v_exec_initval_nolibc 退出码 = $rc（期望 132）✗ 未复现"
  fails=$((fails + 1))
fi
out=$(timeout 60 "$QEMU" -cpu rv64,v=false "$VSTATE" 2>&1); rc=$?
if [ "$rc" = 255 ]; then
  echo "  vstate_exec_nolibc 退出码 = 255（应为 kselftest 约定的 SKIP=4）✓ 复现"
else
  echo "  vstate_exec_nolibc 退出码 = $rc（期望 255）✗ 未复现"
  fails=$((fails + 1))
fi

echo
if [ "$fails" = 0 ]; then
  echo "REPRO_STATUS=PASS（发现 1 / 2 / 2b 全部在纯 QEMU 上复现，不依赖真机）"
  exit 0
fi
echo "REPRO_STATUS=FAIL（$fails 项未复现）"
exit 1
