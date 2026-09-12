#!/usr/bin/env bash
# p550-vector.sh — P550 向量(RVV)测试（按板上 isa 自适应；无 v 则 SKIP）
#
# 用法:
#   bash p550-vector.sh add      # 向量加法功能 + VLEN 读取
#   bash p550-vector.sh bench    # 向量加法性能基准
#
# 语义:
#   - 板上 isa 没有 v  → 输出 "vector: SKIP"（P550 是否带 V 待实测，缺 V 不是失败）
#   - 板上没有 gcc     → SKIP（缺工具链，不是内核问题）
#   - 有 v 但编译失败  → FAIL（例如板子 gcc 太老不支持 RVV 内建，这是可行动的发现）
#
# 退出码: 0 = PASS 或 SKIP；1 = FAIL
set -u
cd "$(dirname "$0")" || exit 1
# shellcheck source=lib-isa.sh
. ./lib-isa.sh

MODE=${1:-add}

HAS_V=no
if isa_load; then
  has_ext v && HAS_V=yes
  echo "板上 isa: $ISA"
fi

if [ "$HAS_V" != yes ]; then
  echo "板上 isa 无 v 扩展: ${ISA:-<读不到>}"
  echo "vector: SKIP（该平台不支持 RVV，符合预期，非失败）"
  exit 0
fi

if ! command -v gcc >/dev/null 2>&1; then
  echo "板上没有 gcc，无法编译 RVV 测试"
  echo "vector: SKIP（缺 gcc）"
  exit 0
fi

echo "gcc: $(gcc --version | head -1)"

case "$MODE" in
  add)
    SRC=riscv_vector_add.c
    BIN=/tmp/riscv_vector_add
    ;;
  bench)
    SRC=riscv_vector_bench.c
    BIN=/tmp/riscv_vector_bench
    ;;
  *)
    echo "未知模式: $MODE（可用: add | bench）"
    exit 1
    ;;
esac

[ -f "$SRC" ] || { echo "缺 $SRC"; exit 1; }

echo "编译 $SRC ..."
if ! gcc -O2 -static -march=rv64gcv -mabi=lp64d "$SRC" -o "$BIN" 2>&1; then
  echo "vector: FAIL（编译失败 —— 板子 gcc 可能不支持 RVV 内建，需要 GCC 13+）"
  exit 1
fi

echo "运行 $BIN ..."
OUT=$("$BIN") || { echo "$OUT"; rm -f "$BIN"; echo "vector: FAIL（运行失败）"; exit 1; }
echo "$OUT"
rm -f "$BIN"

echo "判定"
echo "$OUT" | grep -q PASS || { echo "vector: FAIL"; exit 1; }

if [ "$MODE" = add ]; then
  echo "vector: PASS"
else
  echo "vector_bench: PASS"
fi
exit 0
