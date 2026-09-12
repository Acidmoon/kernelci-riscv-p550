#!/usr/bin/env bash
# riscv-hwprobe.sh — riscv_hwprobe(2) 权威探针 + 与 /proc/cpuinfo 交叉验证（板子侧）
#
# 为什么需要它
#   扩展矩阵此前以 /proc/cpuinfo 的 `isa` 字段为准，那只是"内核汇总出来的字符串"。
#   `riscv_hwprobe(2)` 是内核提供给用户态的**权威结构化**能力接口：
#     - 机器可读（键值对），不受 ISA 字符串拼写/顺序差异影响
#     - 能给出 isa 字符串给不出的信息（非对齐访问性能档位、块大小、最高虚拟地址）
#   两者**不一致**本身就是 SOW 要的"配置漂移"证据，所以这里做交叉验证而不是二选一。
#
# ⚠️ 边界: hwprobe **不覆盖 H（Hypervisor）** 等特权扩展 → H 的结论仍来自设备树/cpuinfo。
#
# 机器可读: HWPROBE_STATUS=PASS|FAIL|SKIP  HWPROBE_MISMATCH=n
set -u
cd "$(dirname "$0")" || exit 1

BIN=./riscv_hwprobe_dump
[ -x "$BIN" ] || { echo "缺可执行文件 $BIN（应由本机交叉编译后同步）"; echo "HWPROBE_STATUS=SKIP"; echo "HWPROBE_MISMATCH=0"; exit 0; }

out=$("$BIN" 2>&1)
rc=$?
echo "$out"

# hwprobe 不存在（老内核）→ SKIP
if printf '%s' "$out" | grep -q '^HWPROBE_STATUS=SKIP'; then
  echo "HWPROBE_MISMATCH=0"
  exit 0
fi
if [ "$rc" != 0 ]; then
  echo "HWPROBE_STATUS=FAIL"
  echo "HWPROBE_MISMATCH=0"
  exit 1
fi

# 与 cpuinfo 的 isa 交叉验证（两边都有的扩展才比较）
if [ -r ./lib-isa.sh ]; then
  # shellcheck source=lib-isa.sh
  . ./lib-isa.sh
  if isa_load; then
    echo
    echo "== 交叉验证: hwprobe vs /proc/cpuinfo isa =="
    echo "  cpuinfo isa: $ISA"
    MISMATCH=0
    # 注意: hwprobe 的 **一个位** 可能对应 cpuinfo 里的 **多个** 单字母扩展。
    #   例: IMA_FD 位 = F 与 D 都有；若直接拿 "fd" 去 isa 里找会永远找不到（我就这么误报过一次）。
    # 所以这里显式给出映射: <hwprobe名>:<cpuinfo扩展,逗号分隔>
    for pair in fd:f,d c:c v:v zba:zba zbb:zbb zbs:zbs zbc:zbc zbkb:zbkb \
                zicboz:zicboz zicbom:zicbom zicbop:zicbop zicond:zicond \
                zacas:zacas ztso:ztso zfh:zfh zihintpause:zihintpause zihintntl:zihintntl; do
      ext=${pair%%:*}; ci_list=${pair##*:}
      hw=$(printf '%s\n' "$out" | grep -m1 "^HWPROBE_EXT_${ext}=" | cut -d= -f2)
      [ -z "$hw" ] && continue           # 该内核对这个 IMA_EXT_0 位无定义
      ci=present
      for e in $(echo "$ci_list" | tr ',' ' '); do
        has_ext "$e" || ci=absent
      done
      if [ "$hw" = "$ci" ]; then
        printf '  [一致] %-12s hwprobe=%-7s cpuinfo(%s)=%s\n' "$ext" "$hw" "$ci_list" "$ci"
      else
        printf '  [不一致] %-10s hwprobe=%-7s cpuinfo(%s)=%s   ← 配置漂移，需追查\n' "$ext" "$hw" "$ci_list" "$ci"
        MISMATCH=$((MISMATCH + 1))
      fi
    done
    echo "  不一致项: $MISMATCH"
    echo "  （H 不在此列：hwprobe 不覆盖特权扩展，见本脚本头部说明）"
    echo "HWPROBE_MISMATCH=$MISMATCH"
    echo "HWPROBE_STATUS=PASS"
    exit 0
  fi
fi

echo "HWPROBE_MISMATCH=0"
echo "HWPROBE_STATUS=PASS"
exit 0
