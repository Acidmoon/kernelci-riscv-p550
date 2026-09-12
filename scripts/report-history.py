#!/usr/bin/env python3
"""report-history.py — 扫描 results/history/*/results.json，生成回归趋势表 results/trend.md

用法: python3 scripts/report-history.py
（run-board-tests.sh 末尾会自动调用；也可手动跑）

设计要点（比 li3a 版增强）:
  - 目标平台从每条 results.json 的 "target" 字段读取，不再写死
  - 支持 SKIP 状态（例如 P550 若没有 V 扩展，vector 项就是 SKIP 而不是 FAIL）
  - 额外呈现 h / v / zpm 三个 SOW 重点扩展的存在性
"""
import glob
import json
import os
import sys
from datetime import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HISTORY = os.path.join(ROOT, "results", "history")
TREND = os.path.join(ROOT, "results", "trend.md")


def cell(value):
    if value is None or value == "":
        return "-"
    return str(value)


def flag(value):
    if value is True:
        return "yes"
    if value is False:
        return "no"
    return "-"


rows = []
for path in sorted(glob.glob(os.path.join(HISTORY, "*", "results.json"))):
    try:
        with open(path, encoding="utf-8") as fh:
            rows.append(json.load(fh))
    except Exception as exc:  # noqa: BLE001 - 归档文件损坏不应中断趋势生成
        print(f"跳过 {path}: {exc}", file=sys.stderr)

if not rows:
    print("没有历史数据（results/history/ 为空）")
    sys.exit(0)

target = rows[-1].get("target", "unknown")
lines = [
    f"# Real-hardware regression history ({target})",
    "",
    f"Runs: {len(rows)} | target: {target} | 生成于: "
    f"{datetime.now().strftime('%Y-%m-%d %H:%M')}",
    "",
    "| date | board-info | cpuinfo | h | v | zpm | vector | bench(ms) | bootchain | hypervisor | kselftest(P/F/S) | hwprobe | profile | overall |",
    "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|",
]

for row in rows:
    tests = row.get("tests") or {}
    board = row.get("board") or {}
    ext = board.get("ext") or {}
    bench = tests.get("vector_bench") or {}
    ks = tests.get("kselftest") or {}
    ks_cell = "-"
    if ks:
        ks_cell = "{}/{}/{}".format(ks.get("pass", 0), ks.get("fail", 0), ks.get("skip", 0))
    hw = tests.get("hwprobe") or {}
    hw_cell = "-"
    if hw:
        hw_cell = "{}".format(hw.get("status", "-"))
        if hw.get("mismatch"):
            hw_cell += "(!{})".format(hw["mismatch"])
    pr = tests.get("profile") or {}
    pr_cell = "-"
    if pr:
        pr_cell = str(pr.get("status", "-"))
        if pr.get("mismatch"):
            pr_cell += "(!{})".format(pr["mismatch"])
    ms = cell(bench.get("ms")).replace("ms", "")
    lines.append(
        "| {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |".format(
            cell(row.get("date")),
            cell(tests.get("board_info")),
            cell(tests.get("cpuinfo")),
            flag(ext.get("h")),
            flag(ext.get("v")),
            flag(ext.get("zpm")),
            cell(tests.get("vector")),
            ms,
            cell(tests.get("bootchain")),
            cell(tests.get("hypervisor")),
            ks_cell,
            hw_cell,
            pr_cell,
            cell(row.get("overall")),
        )
    )

with open(TREND, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")

print(f"趋势表已更新: {TREND}（共 {len(rows)} 次运行，target={target}）")
