#!/usr/bin/env bash
# riscv-ext-scan.sh — RISC-V 扩展存在性扫描（生成跨平台对照矩阵）
#
# 用法:
#   bash riscv-ext-scan.sh                     # 用内置默认扩展清单
#   bash riscv-ext-scan.sh h v zpm zba zbb    # 自定义清单（空格分隔）
#
# 语义: 本脚本是"信息采集"，永远 PASS。
#       某扩展"缺失"不是失败 —— 差异本身就是 KernelCI / SOW 想要的结论。
#       需要"必须有"的扩展请用 riscv-cpuinfo.sh 的 REQUIRED 参数。
#
# 机器可读输出（供 run-board-tests.sh 解析）:
#   EXT_<name>=present|absent
#   EXTSCAN=ok
#
# isa 解析逻辑在 lib-isa.sh（含自检 tests/selftest-isa-parse.sh）:
#   单字母扩展只在 rv64 之后的连续字母段里找，多字母按 _ 精确匹配；
#   既不把 svpbmt 的 v / zihintpause 的 h 当成扩展（假阳性），
#   也不漏掉 zpm/zicbom 这类多字母扩展（假阴性）。
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-isa.sh
. "$HERE/lib-isa.sh"

DEFAULT_EXTS="g h v zicsr zifencei zihintpause zicntr zicbom zicboz zicbop zihintntl \
sstc sscofpmf svpbmt zba zbb zbs zbc zbkb zicond zacas ztso zpm zfh zic64b \
ziccamoa ziccif ziccrse za64rs sv48 sv57"
EXTS="${*:-$DEFAULT_EXTS}"

if ! isa_load; then
  echo "无法从 /proc/cpuinfo 读到 isa 字段"
  echo "EXTSCAN=fail"
  exit 1
fi

echo "扩展扫描 — isa: $ISA"
echo "（present=内核 isa 字段里有；absent=没有。缺失不代表失败，只代表差异）"
echo
printf '%-14s %s\n' "扩展" "状态"
printf '%-14s %s\n' "--------------" "------"
for ext in $EXTS; do
  if has_ext "$ext"; then S=present; else S=absent; fi
  printf '%-14s %s\n' "$ext" "$S"
  echo "EXT_$ext=$S"
done

echo
echo "mmu: $(grep -m1 '^mmu' /proc/cpuinfo 2>/dev/null | awk -F':[[:space:]]*' '{print $2}')"
echo
echo "EXTSCAN=ok"
exit 0
