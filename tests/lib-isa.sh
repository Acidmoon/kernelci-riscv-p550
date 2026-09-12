#!/usr/bin/env bash
# lib-isa.sh — 共享库: RISC-V isa 字符串解析（用 `. lib-isa.sh` 引入）
#
# 为什么需要它:
#   内核 /proc/cpuinfo 的 isa 格式是  rv64<单字母扩展>_<多字母扩展>_<多字母扩展>...
#   两种常见的写错方式:
#     假阳性 —— 把整串做子串匹配: "h" 会被 zihintpause 命中、"v" 会被 svpbmt 命中、
#               "i"/"c"/"m" 会被 zicbom 命中，于是"有 H/V 扩展"这类结论完全不可信。
#     假阴性 —— 只取 rv64 之后的单字母段（li3a 原脚本 EXTS=${BASE#rv64} 的做法）:
#               多字母扩展（zpm / zicbom / sstc / zba ...）永远判不到，
#               实测 li3a 的 isa 里明明有 zicbom，脚本仍报"没有"。
#   正确规则:
#     - 单字母扩展: 只在 rv64/rv32 之后的连续字母段里逐字符判断
#     - 多字母扩展: 按 _ 切分后精确匹配，允许数字版本后缀（如 zicbom1p0）
#
# 提供的函数/变量:
#   isa_parse <isa字符串>    设置 ISA / BASE / SINGLE / MULTI
#   isa_load [cpuinfo路径]   从文件（默认 /proc/cpuinfo）读取 isa 并解析；失败返回 1
#   has_ext <扩展名>         0 = 有，1 = 没有

isa_parse() {
  ISA=$1
  BASE=${ISA%%_*}                     # rv64imafdcv
  MULTI_STR=""
  [ "$ISA" != "$BASE" ] && MULTI_STR=${ISA#*_}   # sscofpmf_sstc_svpbmt...
  SINGLE=${BASE#rv64}
  [ "$SINGLE" = "$BASE" ] && SINGLE=${BASE#rv32} # 兼容 rv32
  MULTI=$(echo "$MULTI_STR" | tr '_' ' ')
}

isa_load() {
  local f=${1:-/proc/cpuinfo} s
  s=$(grep -m1 '^isa' "$f" 2>/dev/null | awk -F':[[:space:]]*' '{print $2}')
  [ -n "$s" ] || return 1
  isa_parse "$s"
}

has_ext() {
  local e=$1 m
  if [ "${#e}" -eq 1 ]; then
    case "$SINGLE" in *"$e"*) return 0 ;; *) return 1 ;; esac
  fi
  for m in $MULTI; do
    case "$m" in "$e" | "$e"[0-9]*) return 0 ;; esac
  done
  return 1
}
