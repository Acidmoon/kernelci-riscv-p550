#!/usr/bin/env bash
# riscv-cpuinfo.sh — RISC-V 真机 CPU 能力与身份探测（板卡无关，P550 / li3a 通用）
#
# 用法:
#   bash riscv-cpuinfo.sh [必需扩展,逗号分隔]
#     bash riscv-cpuinfo.sh i,m,a,f,d,c      # 只要求 RV64GC 基础
#     bash riscv-cpuinfo.sh i,m,a,f,d,c,v    # 额外要求向量扩展
#
# 退出码: 0 = 必需扩展齐全；1 = 有缺失或读不到 isa
#
# 机器可读输出（供 run-board-tests.sh 解析）:
#   ISA=<完整 isa 字符串>
#   EXTSTATE_<ext>=present|absent
#   CPUINFO_STATUS=PASS|FAIL
#
# isa 解析逻辑在 lib-isa.sh（含自检 tests/selftest-isa-parse.sh）:
#   整串子串匹配会让 zihintpause 的 h 冒充 H 扩展（假阳性）；
#   只取单字母段又会让 zpm/zicbom 这类多字母扩展永远判不到（假阴性）。两者都要避开。
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-isa.sh
. "$HERE/lib-isa.sh"

REQUIRED=${1:-i,m,a,f,d,c}

if ! isa_load; then
  echo "无法从 /proc/cpuinfo 读到 isa 字段（内核太老或非 RISC-V？）"
  echo "CPUINFO_STATUS=FAIL"
  exit 1
fi

echo "架构: $(uname -m)"
echo "isa:  $ISA"
echo "基础: $BASE（单字母段: $SINGLE）"
echo "多字母: ${MULTI:-<无>}"
echo

echo "--- 板上身份（真机签名；模拟器一般不会一致）---"
grep -E '^(processor|hart|model name|mmu|mvendorid|marchid|mimpid)' /proc/cpuinfo | head -12
echo "核数: $(grep -c '^processor' /proc/cpuinfo)"
echo

echo "--- 必需扩展检查（REQUIRED=$REQUIRED）---"
STATUS=PASS
MISSING=""
for ext in $(echo "$REQUIRED" | tr ',' ' '); do
  [ -z "$ext" ] && continue
  if has_ext "$ext"; then
    echo "  扩展 $ext : 有 ✓"
    echo "EXTSTATE_$ext=present"
  else
    echo "  扩展 $ext : 没有 ✗"
    echo "EXTSTATE_$ext=absent"
    STATUS=FAIL
    MISSING="$MISSING,$ext"
  fi
done

echo
echo "ISA=$ISA"
echo "结果: $STATUS${MISSING:+（缺少:$MISSING）}"
echo "CPUINFO_STATUS=$STATUS"
[ "$STATUS" = "PASS" ]
