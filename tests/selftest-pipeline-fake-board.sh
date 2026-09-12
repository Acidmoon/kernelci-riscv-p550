#!/usr/bin/env bash
# selftest-pipeline-fake-board.sh — 用"假板子"验证整条流水线的编排逻辑
#
# 为什么需要它:
#   run-board-tests.sh 里最容易出错的是编排部分（状态判定、JSON 汇总、verdict、趋势表），
#   而这些在 x86 上、在没接板子的时候完全测不到。本脚本用假的 ssh/scp 顶替板子，
#   跑三种场景并断言 results.json / trend.md 的内容，因此可以在 CI 里每次 push 都跑。
#
# 覆盖场景:
#   A) 板上无 v（预期: vector/bench = SKIP，overall = PASS，退出码 0）
#   B) 板上有 v 且基准跑通（预期: 全 PASS，bench ms 有值）
#   C) cpuinfo 缺必需扩展（预期: cpuinfo = FAIL，overall = FAIL，退出码 1）
#
# 用法: bash tests/selftest-pipeline-fake-board.sh
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname "$HERE")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAIL=0
note() { printf '  %s\n' "$*"; }
ok() { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; FAIL=1; }

# ---------- 1. 造一份仓库副本（隔离，绝不污染真实 results/） ----------
COPY="$TMP/repo"
mkdir -p "$COPY"
rsync -a --exclude '.git' --exclude 'results/history/*' "$REPO_ROOT/" "$COPY/" 2>/dev/null \
  || { echo "rsync 复制失败"; exit 2; }
mkdir -p "$COPY/results/history"

# ---------- 2. 造假 ssh / scp ----------
FAKE="$TMP/fakebin"
STAGE="$TMP/stage"
mkdir -p "$FAKE" "$STAGE"

cat >"$FAKE/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
cmd="${*: -1}"
case "$cmd" in
  *'echo OK'*) echo OK; exit 0 ;;
  *p550-board-info.sh*) cat "$FAKE_DIR/board-info.log"; exit 0 ;;
  *riscv-cpuinfo.sh*) cat "$FAKE_DIR/cpuinfo.log"; exit 0 ;;
  *riscv-ext-scan.sh*) cat "$FAKE_DIR/ext.log"; exit 0 ;;
  *p550-bootchain.sh*) cat "$FAKE_DIR/bootchain.log"; exit 0 ;;
  *'p550-vector.sh bench'*) cat "$FAKE_DIR/bench.log"; exit 0 ;;
  *'p550-vector.sh add'*) cat "$FAKE_DIR/vector.log"; exit 0 ;;
  *) echo "fake-ssh: 未预期命令: $cmd" >&2; exit 1 ;;
esac
FAKE_SSH

cat >"$FAKE/scp" <<'FAKE_SCP'
#!/usr/bin/env bash
exit 0
FAKE_SCP

chmod +x "$FAKE/ssh" "$FAKE/scp"
export FAKE_DIR="$STAGE"

# ---------- 3. 造各种场景的板子日志 ----------
write_logs() { # write_logs <h:present|absent> <v:present|absent> <zpm:present|absent> <cpuinfo_ok:yes|no>
  local h=$1 v=$2 zpm=$3 cpu_ok=$4
  cat >"$STAGE/board-info.log" <<EOF
===== uname =====
Linux p550 6.6.21-10-premier #7 SMP PREEMPT riscv64 GNU/Linux
MODEL=SiFive HiFive Premier P550
COMPATIBLE=eswin,eic7700
KERNEL=6.6.21-10-premier
OS=Ubuntu 24.04.2 LTS
ROOTDEV=/dev/mmcblk0p2
MEM=15Gi
NPROC=4
EFI=yes
BOARDINFO_STATUS=PASS
EOF

  local isa="rv64imafdc_zicsr_zifencei_zba_zbb_zbs_zicbom_zicboz_sstc_sscofpmf_svpbmt_zihintpause"
  [ "$v" = present ] && isa="rv64imafdcv_zicsr_zifencei_zba_zbb_zbs_zicbom_zicboz_sstc_sscofpmf_svpbmt_zihintpause"
  {
    echo "架构: riscv64"
    echo "isa:  $isa"
    echo "ISA=$isa"
    if [ "$cpu_ok" = yes ]; then echo "CPUINFO_STATUS=PASS"; else echo "结果: FAIL（缺少:,v）"; echo "CPUINFO_STATUS=FAIL"; fi
  } >"$STAGE/cpuinfo.log"

  cat >"$STAGE/ext.log" <<EOF
扩展扫描 — isa: $isa
EXT_h=$h
EXT_v=$v
EXT_zpm=$zpm
EXTSCAN=ok
EOF

  printf 'vector: PASS\nVLEN = 256 bits\nvector_add: PASS\n' >"$STAGE/vector.log"
  printf 'vector bench: 4194304 元素加法耗时 12.345 ms\n结果校验: PASS\n' >"$STAGE/bench.log"
  printf 'BOOTCHAIN_STATUS=PASS\n内核命令行: root=/dev/mmcblk0p2\n' >"$STAGE/bootchain.log"
}

run_case() { # run_case <名字> [额外 env...]
  local name=$1
  shift
  PATH="$FAKE:$PATH" OUT="$COPY/results/history/$name" env "$@" \
    bash "$COPY/scripts/run-board-tests.sh" >"$TMP/$name.out" 2>&1
  echo $? >"$TMP/$name.rc"
}

expect_json() { # expect_json <case> <python 断言表达式>
  local case=$1 expr=$2
  if python3 - "$COPY/results/history/$case/results.json" "$expr" <<'PY'
import json
import sys

path, expr = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    r = json.load(fh)
t, b, board = r["tests"], r["tests"], r["board"]
bench = t["vector_bench"]
value = eval(expr)  # noqa: S307 - 测试内固定表达式，非用户输入
sys.exit(0 if value else 1)
PY
  then ok "$case: $expr"; else bad "$case: $expr"; fi
}

# ---------- 场景 A: 无 v，向量应 SKIP 且整体 PASS ----------
echo "== 场景 A: 板上无 v（应 SKIP 且 overall=PASS）=="
write_logs absent absent absent yes
run_case caseA BOARD=p550
rc=$(cat "$TMP/caseA.rc")
[ "$rc" = 0 ] && ok "退出码 0" || { bad "退出码 $rc（期望 0）"; sed 's/^/     /' "$TMP/caseA.out"; }
expect_json caseA 't["vector"] == "SKIP" and bench["status"] == "SKIP" and r["overall"] == "PASS"'
expect_json caseA 'board["ext"] == {"h": False, "v": False, "zpm": False}'
expect_json caseA 'board["model"] == "SiFive HiFive Premier P550" and board["rootdev"] == "/dev/mmcblk0p2"'

# ---------- 场景 B: 有 v，基准应 PASS 且有 ms ----------
echo
echo "== 场景 B: 板上有 v（应全 PASS 并记录 bench ms）=="
write_logs absent present absent yes
run_case caseB BOARD=p550
rc=$(cat "$TMP/caseB.rc")
[ "$rc" = 0 ] && ok "退出码 0" || { bad "退出码 $rc（期望 0）"; sed 's/^/     /' "$TMP/caseB.out"; }
expect_json caseB 't["vector"] == "PASS" and bench["status"] == "PASS" and bench["ms"] == "12.345ms" and r["overall"] == "PASS"'
expect_json caseB 'board["ext"]["v"] is True'

# ---------- 场景 C: cpuinfo 缺必需扩展 → FAIL ----------
echo
echo "== 场景 C: cpuinfo FAIL（应 overall=FAIL、退出码 1）=="
write_logs absent absent absent no
run_case caseC BOARD=p550
rc=$(cat "$TMP/caseC.rc")
[ "$rc" = 1 ] && ok "退出码 1" || { bad "退出码 $rc（期望 1）"; sed 's/^/     /' "$TMP/caseC.out"; }
expect_json caseC 't["cpuinfo"] == "FAIL" and r["overall"] == "FAIL"'

# ---------- 趋势表应包含三次运行 ----------
echo
echo "== 趋势表 =="
if [ -f "$COPY/results/trend.md" ] && [ "$(grep -c '^| case' "$COPY/results/trend.md")" -eq 3 ]; then
  ok "trend.md 含 3 行记录"
  sed 's/^/     /' "$COPY/results/trend.md"
else
  bad "trend.md 行数不对"; sed 's/^/     /' "$COPY/results/trend.md" 2>/dev/null
fi

# ---------- 真实仓库必须保持干净 ----------
echo
echo "== 隔离性 =="
if [ -z "$(ls -A "$REPO_ROOT/results/history" 2>/dev/null | grep -v '^\.gitkeep$')" ]; then
  ok "真实仓 results/history 未被污染"
else
  bad "真实仓 results/history 被污染"
fi

echo
if [ "$FAIL" = 0 ]; then echo "流水线假板自检: PASS"; else echo "流水线假板自检: FAIL"; fi
exit "$FAIL"
