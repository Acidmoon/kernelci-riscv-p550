#!/usr/bin/env bash
# riscv-kselftest.sh — 在板上运行预编译好的 riscv kselftest 子集（板子侧）
#
# 为什么需要它
#   SOW Phase 2 要求「自动测扩展的回归通过率」。QEMU 侧基线是 **9 pass / 0 skip / 1 xfail**
#   （v7.2-rc7 全量 riscv kselftest）。这里用**同一套 kselftest 源码**交叉编译后在 P550 真机运行，
#   做同口径对照 —— 差异就是结论。
#
# 两条关键设计（都来自实测踩坑）
#   1) 板上没有 gcc → 二进制由本机 `scripts/build-kselftest.sh` 编好后同步到 ./kselftest-riscv/
#   2) **测试适用性取决于平台扩展**：需要 V 的（sigreturn / vector/*）与需要 ZPM 的
#      （abi/pointer_masking）在缺该扩展的平台上必须记 SKIP，而不是 FAIL —— 否则真机回归
#      信号会被一堆"平台本来就没有这个扩展"的失败淹没。实测：P550 上直接跑这些会 SIGILL。
#      上游 runner 的调用细节也要照抄，例如 mmap_bottomup 必须在 `ulimit -s unlimited` 下运行
#      （否则默认 TOP_DOWN 布局会让它误报失败）。
#
# 机器可读输出:
#   KSELFTEST_STATUS=PASS|FAIL|SKIP
#   KSELFTEST_PASS=n  KSELFTEST_FAIL=n  KSELFTEST_SKIP=n
set -u
cd "$(dirname "$0")" || exit 1

DIR=${KSELFTEST_DIR:-./kselftest-riscv}
TIMEOUT=${KSELFTEST_TIMEOUT:-120}

if [ ! -d "$DIR" ]; then
  echo "找不到 $DIR（需要先在本机跑 scripts/build-kselftest.sh 并同步过来）"
  echo "kselftest: SKIP（未准备测试二进制）"
  echo "KSELFTEST_STATUS=SKIP"
  exit 0
fi

# 平台扩展探测（用与其它测试相同的解析库）
HAS_V=no
HAS_ZPM=no
if [ -r ./lib-isa.sh ]; then
  # shellcheck source=lib-isa.sh
  . ./lib-isa.sh
  if isa_load; then
    has_ext v && HAS_V=yes
    has_ext zpm && HAS_ZPM=yes
  fi
fi

PASS=0
FAIL=0
SKIP=0

report() { # report <判定> <名称> <说明>
  printf '  [%-4s] %-24s %s\n' "$1" "$2" "${3:-}"
}

# run_one <名称> <相对路径> <gate> <run_mode>
#   gate: "" | v | zpm   —— 缺对应扩展则 SKIP（不跑，因为跑了必然 SIGILL/报不支持）
#   run_mode: "" | ulimit —— ulimit 表示需要 `ulimit -s unlimited`（照抄上游 run_mmap.sh）
run_one() {
  local name=$1 rel=$2 gate=$3 mode=$4
  local bin="$DIR/$rel" out rc totals

  if [ ! -x "$bin" ]; then
    report SKIP "$name" "缺二进制 $rel"
    SKIP=$((SKIP + 1))
    return
  fi

  case "$gate" in
    v) [ "$HAS_V" = yes ] || { report SKIP "$name" "平台无 v 扩展（该测试需要 RVV，跑下去会 SIGILL）"; SKIP=$((SKIP + 1)); return; } ;;
    zpm) [ "$HAS_ZPM" = yes ] || { report SKIP "$name" "平台无 zpm 扩展（pointer masking 未实现）"; SKIP=$((SKIP + 1)); return; } ;;
  esac

  if [ "$mode" = ulimit ]; then
    out=$(timeout "$TIMEOUT" bash -c "ulimit -s unlimited; exec '$bin'" 2>&1)
  else
    out=$(timeout "$TIMEOUT" "$bin" 2>&1)
  fi
  rc=$?

  totals=$(printf '%s\n' "$out" | grep -m1 '^# Totals:' || true)

  # 判定: 0=PASS；4=kselftest 约定 SKIP；其它为 FAIL
  # 特例: 上游 pointer_masking 在无 ZPM 时以 "Bail out! Failed to enable pointer masking"
  #       退出且 rc=1 —— 语义上是"平台不支持"，记 SKIP（上面的 zpm gate 一般已拦下）
  if [ "$rc" = 0 ]; then
    report PASS "$name" "${totals:-}"
    PASS=$((PASS + 1))
  elif [ "$rc" = 4 ] || printf '%s' "$out" | grep -q 'Failed to enable pointer masking'; then
    report SKIP "$name" "${totals:-平台不支持}"
    SKIP=$((SKIP + 1))
  else
    report FAIL "$name" "exit=$rc ${totals:-}"
    printf '%s\n' "$out" | grep -E '^not ok|FAIL|signal' | head -4 | sed 's/^/         /'
    FAIL=$((FAIL + 1))
  fi
}

echo "== riscv kselftest（真机；对照 QEMU 基线 9P/0S/1X）=="
echo "  平台扩展: v=$HAS_V zpm=$HAS_ZPM"
echo
run_one hwprobe            hwprobe/hwprobe                   ""    ""
run_one mmap_default       mm/mmap_default                   ""    ""
run_one mmap_bottomup      mm/mmap_bottomup                  ""    ulimit
run_one pointer_masking    abi/pointer_masking               zpm   ""
run_one sigreturn          sigreturn/sigreturn               v     ""
run_one vstate_exec_nolibc vector/vstate_exec_nolibc         v     ""
run_one v_exec_initval     vector/v_exec_initval_nolibc      v     ""
echo

STATUS=PASS
[ "$FAIL" -gt 0 ] && STATUS=FAIL
[ "$PASS" -eq 0 ] && [ "$FAIL" -eq 0 ] && STATUS=SKIP

echo "kselftest: $STATUS（pass=$PASS fail=$FAIL skip=$SKIP）"
echo "KSELFTEST_STATUS=$STATUS"
echo "KSELFTEST_PASS=$PASS"
echo "KSELFTEST_FAIL=$FAIL"
echo "KSELFTEST_SKIP=$SKIP"
[ "$STATUS" != FAIL ]
