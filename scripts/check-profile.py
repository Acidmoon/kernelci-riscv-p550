#!/usr/bin/env python3
"""check-profile.py — 把 profile 期望值与真实结果对照（SOW Phase 2 的"自动捕捉配置漂移"）

做两件事
  1) --selfcheck       校验 profile 自身的一致性（引用的 suite 是否存在、必填字段、id 唯一）
  2) --archive <dir>   把某次真机/模拟器运行的 results.json 与 profile 的期望值逐项比对
                       不一致就是"配置漂移"——例如板子换内核后 H 扩展消失、或 hwprobe 与 isa 分叉

为什么它重要
  文档里的"扩展矩阵"是死的；profile 化之后它变成**可执行断言**：
  每次跑完流水线自动比对，违反了就先在 CI/本地报出来，而不是等人事后翻文档。

用法
  python3 scripts/check-profile.py --selfcheck
  python3 scripts/check-profile.py --archive results/history/<ts> --target p550
  python3 scripts/check-profile.py --latest                      # 自动按 results.json 的 target 匹配

退出码: 0 一致；1 有漂移或 profile 有问题；2 输入错误
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROFILE_PATH = os.path.join(REPO_ROOT, "profile", "riscv-extensions.json")


def log(msg: str) -> None:
    print(msg, file=sys.stderr)


def load_profile() -> dict:
    with open(PROFILE_PATH, encoding="utf-8") as fh:
        return json.load(fh)


# --------------------------------------------------------------------------- #
# 1) profile 自身一致性
# --------------------------------------------------------------------------- #
def selfcheck(profile: dict) -> list[str]:
    errs: list[str] = []
    prof = profile.get("profile") or {}
    for field in ("name", "version", "description"):
        if field not in prof:
            errs.append(f"profile 缺少字段 {field}")

    suites = profile.get("suites") or []
    if not suites:
        errs.append("没有任何 suite")
    ids = [s.get("id") for s in suites]
    if len(ids) != len(set(ids)):
        errs.append(f"suite id 重复: {ids}")
    for s in suites:
        for field in ("id", "results_key", "script", "kind", "purpose"):
            if field not in s:
                errs.append(f"suite {s.get('id')} 缺少 {field}")
        if s.get("kind") not in ("info", "capability", "extension", "regression"):
            errs.append(f"suite {s.get('id')} 的 kind 非法: {s.get('kind')}")
        script = s.get("script")
        if script and not os.path.isfile(os.path.join(REPO_ROOT, script)):
            errs.append(f"suite {s.get('id')} 的 script 不存在: {script}")
        known_ext = {"v", "h", "zpm"}
        for r in s.get("requires", []):
            if r not in known_ext:
                errs.append(f"suite {s.get('id')} 的 requires 里有未知扩展: {r}")

    targets = profile.get("targets") or {}
    if not targets:
        errs.append("没有任何 target")
    valid_keys = {s.get("results_key") for s in suites} | {"vector_bench"}
    for tname, t in targets.items():
        if not t.get("results_target"):
            errs.append(f"target {tname} 缺少 results_target")
        if not t.get("isa_regex"):
            errs.append(f"target {tname} 缺少 isa_regex")
        expect = t.get("expect") or {}
        for ext in (expect.get("ext") or {}):
            if ext not in {"v", "h", "zpm"}:
                errs.append(f"target {tname} 的 expect.ext 有未知扩展: {ext}")
        for key in (expect.get("results") or {}):
            if key not in valid_keys:
                errs.append(f"target {tname} 的 expect.results 引用了未知 results_key: {key}")
    return errs


# --------------------------------------------------------------------------- #
# 2) 期望值 vs 实测
# --------------------------------------------------------------------------- #
def status_of(value):
    """results.json 里的测试项可能是字符串，也可能是 {"status": ...} 字典。"""
    if isinstance(value, dict):
        return value.get("status")
    return value


def compare(profile: dict, target_key: str, results: dict) -> tuple[list[str], list[str]]:
    """返回 (一致项说明, 漂移项说明)"""
    target = profile["targets"][target_key]
    expect = target.get("expect") or {}
    ok: list[str] = []
    bad: list[str] = []

    board = results.get("board") or {}
    tests = results.get("tests") or {}

    # 目标标识
    if results.get("target") and target.get("results_target") and \
            results["target"] != target["results_target"]:
        bad.append(f"target 标识不符: profile={target['results_target']}, 实测={results['target']}")
    else:
        ok.append(f"target 标识 = {results.get('target')}")

    # isa 形状
    isa = board.get("isa") or ""
    rx = target.get("isa_regex")
    if rx:
        if re.search(rx, isa):
            ok.append(f"isa 匹配 {rx}（{isa}）")
        else:
            bad.append(f"isa 不匹配 {rx} ← 实测 {isa}")

    # 扩展存在性（真机/模拟器行为矩阵的核心）
    for ext, want in (expect.get("ext") or {}).items():
        got = (board.get("ext") or {}).get(ext)
        if got == want:
            ok.append(f"ext.{ext} = {got}")
        else:
            bad.append(f"ext.{ext}: profile={want}, 实测={got} ← 配置漂移")

    # 各测试项状态
    for key, want in (expect.get("results") or {}).items():
        got = status_of(tests.get(key))
        if got == want:
            ok.append(f"{key} = {got}")
        else:
            bad.append(f"{key}: profile={want}, 实测={got}")

    # kselftest 计数下限
    ks = tests.get("kselftest")
    if isinstance(ks, dict) and target.get("expect", {}).get("kselftest_min"):
        for field, minimum in target["expect"]["kselftest_min"].items():
            got = ks.get(field)
            if got is None:
                bad.append(f"kselftest.{field} 缺失（profile 要求 >= {minimum}）")
            elif got < minimum:
                bad.append(f"kselftest.{field}={got} < profile 下限 {minimum} ← 回归")
            else:
                ok.append(f"kselftest.{field} = {got} (>= {minimum})")

    # 若无 hwprobe 交叉验证不一致数，顺带断言
    hw = tests.get("hwprobe")
    if isinstance(hw, dict) and hw.get("mismatch") is not None:
        if hw["mismatch"] == 0:
            ok.append("hwprobe 与 isa 交叉验证 0 处不一致")
        else:
            bad.append(f"hwprobe 与 isa 有 {hw['mismatch']} 处不一致 ← 需追查")
    return ok, bad


def pick_archive(arg: str | None, latest: bool) -> str:
    if arg and not latest:
        path = arg if os.path.isabs(arg) else os.path.join(REPO_ROOT, arg)
        if not os.path.isdir(path):
            log(f"错误: 归档目录不存在: {path}")
            sys.exit(2)
        return path
    dirs = sorted(d for d in glob.glob(os.path.join(REPO_ROOT, "results", "history", "*"))
                  if os.path.isdir(d))
    if not dirs:
        log("错误: results/history/ 下没有归档")
        sys.exit(2)
    return dirs[-1]


def main() -> int:
    ap = argparse.ArgumentParser(description="profile 期望值 vs 实测结果")
    ap.add_argument("--archive", help="归档目录")
    ap.add_argument("--latest", action="store_true", help="用最新归档")
    ap.add_argument("--target", help="profile 里的 target key（默认按 results.json 的 target 自动匹配）")
    ap.add_argument("--selfcheck", action="store_true", help="只校验 profile 自身")
    ap.add_argument("--quiet", action="store_true", help="只打印漂移项")
    args = ap.parse_args()

    profile = load_profile()

    if args.selfcheck:
        errs = selfcheck(profile)
        if errs:
            for e in errs:
                log(f"  profile 问题: {e}")
            return 1
        print(f"profile 自检: PASS（{len(profile['suites'])} 个 suite，{len(profile['targets'])} 个 target）")
        return 0

    archive = pick_archive(args.archive, args.latest)
    rpath = os.path.join(archive, "results.json")
    if not os.path.isfile(rpath):
        log(f"错误: {rpath} 不存在")
        return 2
    with open(rpath, encoding="utf-8") as fh:
        results = json.load(fh)

    target_key = args.target
    if not target_key:
        for k, t in profile["targets"].items():
            if t.get("results_target") == results.get("target"):
                target_key = k
                break
    if not target_key:
        log(f"提示: results.json 的 target={results.get('target')!r} 在 profile 里没有对应项，跳过比对")
        return 0

    ok, bad = compare(profile, target_key, results)
    if not args.quiet:
        for line in ok:
            print(f"  [一致]   {line}")
    for line in bad:
        print(f"  [漂移]   {line}")
    print(f"profile 一致性: {'PASS' if not bad else 'FAIL'}"
          f"（{len(ok)} 项一致 / {len(bad)} 项不一致, target={target_key}, 归档={os.path.basename(archive)}）")
    print(f"PROFILE_STATUS={'PASS' if not bad else 'FAIL'}")
    print(f"PROFILE_MISMATCH={len(bad)}")
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
