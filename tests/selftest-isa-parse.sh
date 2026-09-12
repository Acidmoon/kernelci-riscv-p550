#!/usr/bin/env bash
# selftest-isa-parse.sh — ISA 解析自检（任何架构都能跑，CI 会执行）
#
# 存在的意义: isa 解析是本仓库最容易写错、又最难在 x86 上发现的一环。
# 这个自检用固定的 isa 样本验证解析逻辑，覆盖两类典型错误:
#   假阳性 —— zihintpause 的 h 被当成 H 扩展、svpbmt 的 v 被当成 V 扩展
#   假阴性 —— 只解析单字母段导致 zpm/zicbom/sstc 等多字母扩展永远判不到
#              （li3a 原脚本 li3a-cpuinfo.sh 就是这个问题，实测已确认）
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib-isa.sh
. "$HERE/lib-isa.sh"

FAIL=0
check() { # check <isa> <ext> <present|absent>
  isa_parse "$1"
  if has_ext "$2"; then got=present; else got=absent; fi
  if [ "$got" = "$3" ]; then
    printf '  ok    %-12s = %-7s  (%s)\n' "$2" "$got" "$1"
  else
    printf '  FAIL  %-12s = %-7s  期望 %s   (%s)\n' "$2" "$got" "$3" "$1"
    FAIL=1
  fi
}

LI3A="rv64imafdcv_sscofpmf_sstc_svpbmt_zicbom_zicboz_zicbop_zihintpause"
echo "== Lichee Pi 3A 实测字符串 =="
check "$LI3A" v present
check "$LI3A" h absent            # 关键: zihintpause 里有 h，不能误判
check "$LI3A" zpm absent
check "$LI3A" zihintpause present
check "$LI3A" zicbom present
check "$LI3A" i present
check "$LI3A" zba absent

echo
echo "== 构造的 RV64GC（无 V/H）样本 =="
GC="rv64imafdc_zicsr_zifencei_zba_zbb_zbs_zicbom_zicboz_zicbop_sstc_sscofpmf_svpbmt_zihintpause"
check "$GC" v absent              # 关键: svpbmt 里有 v，不能误判
check "$GC" h absent
check "$GC" zba present
check "$GC" zbs present
check "$GC" g absent              # 内核一般打印展开形式 imafdc，此时字面量里没有 g
check "rv64gc_zicsr_zifencei" g present   # 若内核打印简写 g，则应识别为 present

echo
echo "== 构造的带 H/V 样本 =="
GCVH="rv64imafdcvh_zicsr_zifencei"
check "$GCVH" v present
check "$GCVH" h present
check "$GCVH" zpm absent

echo
echo "== 多字母扩展版本后缀 =="
check "rv64imafdc_zicbom1p0_sstc" zicbom present
check "rv64imafdc_zicbom1p0_sstc" sstc present
check "rv64imafdc_zicbom1p0_sstc" zacas absent

echo
if [ "$FAIL" = 0 ]; then
  echo "ISA 解析自检: PASS"
  exit 0
else
  echo "ISA 解析自检: FAIL"
  exit 1
fi
