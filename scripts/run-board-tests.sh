#!/usr/bin/env bash
#
# run-board-tests.sh — HiFive Premier P550 真机一键测试流水线
#
# 步骤:
#   [0] 板子可达性   [1] 本机交叉编译   [2] 同步文件+二进制   [3] 执行测试
#   [4] 汇总 JSON + verdict   [5] 更新回归趋势表
#
# 注意: 板上没有 gcc（实测确认），所以需要编译的测试一律在本机交叉编译后同步过去。
#
# 测试项:
#   2.1 board-info      板卡身份/存储/内存/首次启动快照（只读，无需 sudo）
#   2.2 cpuinfo         RV64GC 必需扩展 + CPU 身份（REQUIRED 可调）
#   2.3 ext-scan        扩展矩阵扫描（h/v/zpm/zba/... 存在性，只记录不判失败）
#   2.4 vector          仅当 isa 含 v 才跑；否则 SKIP（P550 是否带 V 待实测）
#   2.5 vector-bench    同上
#   3.6 bootchain       启动链/固件证据（U-Boot/GRUB/EFI/设备树/根设备）
#   3.7 hypervisor      真机 H/KVM 功能测试（P550 独有；无 H 或无 /dev/kvm 则 SKIP）
#
# 环境变量:
#   BOARD     SSH 目标（默认 p550，配置见 docs/p550-bringup.md）
#   TESTS_DIR 板上测试目录（默认 /home/ubuntu/KernelCI-pipeline）
#   REQUIRED  必需扩展，逗号分隔（默认 i,m,a,f,d,c = RV64GC 基础）
#   OUT       归档目录（默认 results/history/<时间戳>）
#   DRY_RUN   1 = 不碰板子，只打印计划（本地自检与 CI lint 用）
#
# 退出码: 0=无 FAIL；1=有 FAIL；2=环境/可达性问题
set -u

BOARD=${BOARD:-p550}
TESTS_DIR=${TESTS_DIR:-/home/ubuntu/KernelCI-pipeline}
REQUIRED=${REQUIRED:-i,m,a,f,d,c}
DRY_RUN=${DRY_RUN:-0}

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(dirname "$HERE")
TS=$(date +%Y%m%d-%H%M%S)

if [ "$DRY_RUN" = 1 ]; then
  OUT=${OUT:-"$(mktemp -d)/p550-dry-run"}
else
  OUT=${OUT:-"$REPO_ROOT/results/history/$TS"}
fi
mkdir -p "$OUT"

FILES="lib-isa.sh riscv-cpuinfo.sh riscv-ext-scan.sh p550-board-info.sh p550-bootchain.sh \
p550-vector.sh riscv-hypervisor.sh p550-kvm-setup.sh riscv_vector_add.c riscv_vector_bench.c"

# 需要在本机交叉编译后同步到板子的二进制（板子上没有 gcc）
HOST_CC=${HOST_CC:-riscv64-linux-gnu-gcc}
HOST_BINS="riscv_kvm_smoke"

fail() { echo "FAIL: $1"; exit 2; }

# remote <日志名> <板子上要执行的命令>
remote() {
  local log=$1 cmd=$2
  if [ "$DRY_RUN" = 1 ]; then
    echo "  [dry-run] ssh $BOARD \"$cmd\" > $log"
    : > "$OUT/$log"
    return 0
  fi
  ssh -o ConnectTimeout=10 "$BOARD" "$cmd" 2>&1 | tee "$OUT/$log"
}

# log_status <日志> <PASS 模式> [SKIP 模式]
log_status() {
  local log=$1 pass=$2 skip=${3:-}
  if [ -n "$skip" ] && grep -q "$skip" "$log" 2>/dev/null; then
    echo SKIP
    return
  fi
  if grep -q "$pass" "$log" 2>/dev/null; then echo PASS; else echo FAIL; fi
}

echo "========== [0] 开发板可达性: $BOARD =========="
if [ "$DRY_RUN" = 1 ]; then
  echo "  [dry-run] 跳过（假定可达）"
else
  ssh -o ConnectTimeout=5 -o BatchMode=yes "$BOARD" 'echo OK' >/dev/null 2>&1 \
    || fail "板子不可达。检查 ~/.ssh/config 的 p550 条目与网络共享，见 docs/p550-bringup.md"
  echo "  OK"
fi

echo "========== [1] 本机交叉编译板子测试二进制 =========="
# 板上没有 gcc（实测确认），所以需要编译的测试一律在本机交叉编译后同步
HOST_BUILT=""
for b in $HOST_BINS; do
  src="$REPO_ROOT/tests/${b}.c"
  [ -f "$src" ] || continue
  if [ "$DRY_RUN" = 1 ]; then
    echo "  [dry-run] $HOST_CC -static -O2 tests/${b}.c -o build/$b"
    continue
  fi
  if ! command -v "$HOST_CC" >/dev/null 2>&1; then
    echo "  ! 找不到交叉编译器 $HOST_CC → 跳过 $b（相关测试会记 SKIP）"
    continue
  fi
  mkdir -p "$REPO_ROOT/build"
  if "$HOST_CC" -static -O2 -Wall -o "$REPO_ROOT/build/$b" "$src" 2>"$OUT/build-$b.log"; then
    echo "  $b ✓"
    HOST_BUILT="$HOST_BUILT $b"
  else
    echo "  ! $b 编译失败（详见 build-$b.log）"
  fi
done

echo "========== [2] 同步测试文件到开发板 =========="
if [ "$DRY_RUN" = 1 ]; then
  echo "  [dry-run] ssh $BOARD \"mkdir -p $TESTS_DIR\""
else
  # 板上目录可能还不存在（新板子/首次运行），先确保存在；
  # 否则 scp 会以很费解的 'dest open "...": Failure' 失败
  ssh -o ConnectTimeout=10 "$BOARD" "mkdir -p \"$TESTS_DIR\"" \
    || fail "无法在板子上创建 $TESTS_DIR（权限？路径？）"
fi
for f in $FILES; do
  if [ "$DRY_RUN" = 1 ]; then
    echo "  [dry-run] scp tests/$f $BOARD:$TESTS_DIR/"
    continue
  fi
  scp -q "$REPO_ROOT/tests/$f" "$BOARD:$TESTS_DIR/" || fail "同步 $f 失败"
  echo "  $f ✓"
done
for b in $HOST_BUILT; do
  scp -q "$REPO_ROOT/build/$b" "$BOARD:$TESTS_DIR/" || fail "同步二进制 $b 失败"
  echo "  $b (binary) ✓"
done

echo "========== [3] 执行测试 =========="

echo "--- [3.1] board-info ---"
remote board-info.log "bash $TESTS_DIR/p550-board-info.sh"
INFO_STATUS=$(log_status "$OUT/board-info.log" '^BOARDINFO_STATUS=PASS')

echo "--- [3.2] cpuinfo（REQUIRED=$REQUIRED）---"
remote cpuinfo.log "bash $TESTS_DIR/riscv-cpuinfo.sh $REQUIRED"
CPU_STATUS=$(log_status "$OUT/cpuinfo.log" '^CPUINFO_STATUS=PASS')

echo "--- [3.3] ext-scan（扩展矩阵）---"
remote ext.log "bash $TESTS_DIR/riscv-ext-scan.sh"
EXT_STATUS=$(log_status "$OUT/ext.log" '^EXTSCAN=ok')

# 板上 isa 是否含 v，决定向量测试跑还是 SKIP
HAS_V=no
grep -q '^EXT_v=present' "$OUT/ext.log" 2>/dev/null && HAS_V=yes
HAS_H=no
grep -q '^EXT_h=present' "$OUT/ext.log" 2>/dev/null && HAS_H=yes
HAS_ZPM=no
grep -q '^EXT_zpm=present' "$OUT/ext.log" 2>/dev/null && HAS_ZPM=yes
echo "  探测结果: h=$HAS_H v=$HAS_V zpm=$HAS_ZPM"

echo "--- [3.4] vector（功能）---"
if [ "$DRY_RUN" = 1 ]; then
  echo "  [dry-run] 向量测试（取决于板上 isa 是否有 v）"
  : > "$OUT/vector.log"
  VEC_STATUS=SKIP
elif [ "$HAS_V" = no ]; then
  printf 'vector: SKIP（isa 无 v 扩展，平台不支持 RVV）\n' | tee "$OUT/vector.log"
  VEC_STATUS=SKIP
else
  remote vector.log "cd $TESTS_DIR && bash p550-vector.sh add"
  VEC_STATUS=$(log_status "$OUT/vector.log" 'vector: PASS' 'vector: SKIP')
fi

echo "--- [3.5] vector bench（性能）---"
BENCH_MS=""
if [ "$DRY_RUN" = 1 ]; then
  echo "  [dry-run] 向量基准（取决于板上 isa 是否有 v）"
  : > "$OUT/bench.log"
  BENCH_STATUS=SKIP
elif [ "$HAS_V" = no ]; then
  printf 'vector_bench: SKIP（isa 无 v 扩展）\n' | tee "$OUT/bench.log"
  BENCH_STATUS=SKIP
else
  remote bench.log "cd $TESTS_DIR && bash p550-vector.sh bench"
  BENCH_STATUS=$(log_status "$OUT/bench.log" '结果校验: PASS' 'vector: SKIP')
  BENCH_MS=$(grep -oE '[0-9]+\.[0-9]+ ms' "$OUT/bench.log" 2>/dev/null | head -1 | tr -d ' ')
fi

echo "--- [3.6] bootchain（启动链证据）---"
remote bootchain.log "bash $TESTS_DIR/p550-bootchain.sh"
BOOT_STATUS=$(log_status "$OUT/bootchain.log" '^BOOTCHAIN_STATUS=PASS')

echo "--- [3.7] hypervisor（H/KVM —— P550 独有轴）---"
remote hypervisor.log "cd $TESTS_DIR && bash riscv-hypervisor.sh"
HYPER_STATUS=$(log_status "$OUT/hypervisor.log" '^HYPERVISOR_STATUS=PASS' '^HYPERVISOR_STATUS=SKIP')

if [ "$DRY_RUN" = 1 ]; then
  echo "========== [dry-run] 结束（未写归档、未更新趋势）=========="
  exit 0
fi

echo "========== [4] 汇总 =========="
MODEL=$(grep -m1 '^MODEL=' "$OUT/board-info.log" 2>/dev/null | cut -d= -f2-)
ISA=$(grep -m1 '^ISA=' "$OUT/cpuinfo.log" 2>/dev/null | cut -d= -f2-)
ROOTDEV=$(grep -m1 '^ROOTDEV=' "$OUT/board-info.log" 2>/dev/null | cut -d= -f2-)

python3 - "$OUT" "$INFO_STATUS" "$CPU_STATUS" "$EXT_STATUS" "$VEC_STATUS" \
  "$BENCH_STATUS" "$BENCH_MS" "$BOOT_STATUS" "$HYPER_STATUS" "$MODEL" "$ISA" "$ROOTDEV" \
  "$HAS_H" "$HAS_V" "$HAS_ZPM" <<'PY'
import json
import os
import sys

(out, info, cpu, ext, vec, bench, bench_ms, boot, hyper, model, isa, rootdev, h, v, zpm) = sys.argv[1:16]

statuses = [info, cpu, ext, vec, bench, boot, hyper]
overall = "FAIL" if any(s == "FAIL" for s in statuses) else "PASS"

res = {
    "date": os.path.basename(out),
    "target": "sifive-hifive-premier-p550",
    "board": {
        "model": model or "-",
        "isa": isa or "-",
        "rootdev": rootdev or "-",
        "ext": {"h": h == "yes", "v": v == "yes", "zpm": zpm == "yes"},
    },
    "tests": {
        "board_info": info,
        "cpuinfo": cpu,
        "ext_scan": ext,
        "vector": vec,
        "vector_bench": {"status": bench, "ms": bench_ms or None},
        "bootchain": boot,
        "hypervisor": hyper,
    },
    "overall": overall,
}

with open(os.path.join(out, "results.json"), "w", encoding="utf-8") as fh:
    json.dump(res, fh, indent=2, ensure_ascii=False)
print(json.dumps(res, ensure_ascii=False, indent=2))
PY

echo "========== [5] VERDICT =========="
if [ "$INFO_STATUS" = PASS ] && [ "$CPU_STATUS" = PASS ] && [ "$EXT_STATUS" = PASS ] \
  && [ "$VEC_STATUS" != FAIL ] && [ "$BENCH_STATUS" != FAIL ] && [ "$BOOT_STATUS" = PASS ] \
  && [ "$HYPER_STATUS" != FAIL ]; then
  echo "OVERALL: PASS（vector=$VEC_STATUS, bench=$BENCH_STATUS, hypervisor=$HYPER_STATUS）"
  echo "归档: $OUT"
  VERDICT=0
else
  echo "OVERALL: FAIL（详见子日志）"
  echo "归档: $OUT"
  VERDICT=1
fi

echo "========== [6] 更新回归趋势表 =========="
python3 "$REPO_ROOT/scripts/report-history.py" || echo "(趋势表更新失败，不影响本次结果)"

exit "$VERDICT"
