#!/usr/bin/env bash
# build-kselftest.sh — 在本机交叉编译 riscv kselftest 子集，暂存到 build/kselftest-riscv/
#
# 为什么需要: 板上没有 gcc（实测确认），所以 kselftest 必须本机交叉编译后再同步。
#
# 用法:
#   KERNEL_TREE=/home/Acidmoon/kernelci-work/linux bash scripts/build-kselftest.sh
#   # 或第一个参数指定内核树
#   bash scripts/build-kselftest.sh /path/to/linux
#
# 环境变量:
#   KERNEL_TREE  内核树根目录（内含 tools/testing/selftests/riscv）
#   CROSS_COMPILE 默认 riscv64-linux-gnu-
#   CC            默认 ${CROSS_COMPILE}gcc
#
# 已知限制（如实记录）:
#   - vector 组需要 GCC 13+（RVV intrinsics）与 asm/vendor/thead.h，gcc 12.3 编不出来
#   - cfi 组需要支持 CFI 的工具链，gcc 12.3 不支持（上游 Makefile 会自行跳过）
#   - 因此这里只编「能在 6.6/7.x 内核上跑且不依赖 V」的 7 个测试
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(dirname "$HERE")
KERNEL_TREE=${KERNEL_TREE:-${1:-}}
CROSS_COMPILE=${CROSS_COMPILE:-riscv64-linux-gnu-}
CC=${CC:-${CROSS_COMPILE}gcc}
STAGE="$REPO_ROOT/build/kselftest-riscv"

# 需要在板上运行的测试（相对 tools/testing/selftests/riscv/ 的路径）
TESTS="abi/pointer_masking hwprobe/hwprobe mm/mmap_bottomup mm/mmap_default \
sigreturn/sigreturn vector/vstate_exec_nolibc vector/v_exec_initval_nolibc"

die() { echo "错误: $*" >&2; exit 1; }

[ -n "$KERNEL_TREE" ] || die "需要内核树: KERNEL_TREE=/path/to/linux bash $0  （或第一个参数传入）"
[ -d "$KERNEL_TREE/tools/testing/selftests/riscv" ] || die "$KERNEL_TREE 里没有 tools/testing/selftests/riscv"
command -v "$CC" >/dev/null 2>&1 || die "找不到交叉编译器 $CC"

echo "== 交叉编译 riscv kselftest =="
echo "  内核树: $KERNEL_TREE"
echo "  编译器: $($CC --version | head -1)"

( cd "$KERNEL_TREE" && make -C tools/testing/selftests TARGETS=riscv \
    ARCH=riscv CROSS_COMPILE="$CROSS_COMPILE" CC="$CC" -j"$(nproc)" ) 2>&1 | tail -5

rm -rf "$STAGE"
missing=""
for t in $TESTS; do
  src="$KERNEL_TREE/tools/testing/selftests/riscv/$t"
  if [ -x "$src" ]; then
    mkdir -p "$STAGE/$(dirname "$t")"
    cp "$src" "$STAGE/$t"
  else
    missing="$missing $t"
  fi
done

echo
echo "== 暂存结果: $STAGE =="
( cd "$STAGE" && find . -type f | sort | sed 's/^/  /' )
[ -n "$missing" ] && echo "  ! 未编出:$missing"
echo
echo "下一步: bash scripts/run-board-tests.sh      # 会自动同步并在板上运行"
