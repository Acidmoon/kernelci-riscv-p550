#!/usr/bin/env python3
"""kcidb-emit.py — 把本仓库的真机测试归档转成 KCIDB 报告（KernelCI 的数据交换格式）

为什么用它（Phase 3 的上游集成路径）
    `kernelci-core/config/core/test-configs.yaml` 已标注为 **LEGACY**（"do not send any new
    patches for this file"），现代路径是 Maestro pipeline 配置或 **KCIDB 提交**。
    KCIDB 提交是**自服务**的：一个 HTTPS POST + JWT，不需要改上游任何代码，也不需要提 PR。
    本脚本负责把 `results/history/<ts>/` 的产出翻译成 KCIDB（version 5.3）报告。

两种模式
   1) 自包含（默认）：输出 checkouts + builds + tests。需要 `--kernel-git-url/--kernel-commit`
      描述被测内核来自哪里。
   2) Hybrid（`--build-id maestro:<id>`）：只输出 tests，`build_id` 指向别人的 Maestro build。
      官方推荐给"自己只有 lab、内核由 Maestro 构建"的场景；我们的板子测的是**出厂预装内核**，
      所以真实提交时更适合先把内核版本信息放进 misc 并联系 KernelCI 约定 origin。
      详见 integration/kernelci/README.md。

用法
   python3 scripts/kcidb-emit.py --latest --print
   python3 scripts/kcidb-emit.py results/history/20260912-161648 --origin p550-lab
   python3 scripts/kcidb-emit.py --latest --build-id maestro:67d409f9f378f0c5986dc7df
   python3 scripts/kcidb-emit.py --latest --validate      # 若装了 kcidb-io 则跑官方校验

退出码: 0 正常；1 结构自检失败；2 输入缺失
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
from datetime import datetime, timezone

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HISTORY = os.path.join(REPO_ROOT, "results", "history")
KCIDB_OUT = os.path.join(REPO_ROOT, "results", "kcidb")

KCIDB_VERSION = {"major": 5, "minor": 3}
VALID_STATUS = {"PASS", "FAIL", "ERROR", "MISS", "DONE", "SKIP"}

# 我们的状态 → KCIDB 状态
STATUS_MAP = {"PASS": "PASS", "FAIL": "FAIL", "SKIP": "SKIP", "ERROR": "ERROR"}

# 板侧测试项 → KCIDB 的 dotted test path
PATH_MAP = {
    "board_info": "board-info.identity",
    "cpuinfo": "riscv-cpuinfo.isa-required-extensions",
    "ext_scan": "riscv-ext-scan.matrix",
    "vector": "riscv-vector.additive",
    "vector_bench": "riscv-vector.bench",
    "bootchain": "bootchain.firmware-evidence",
    "hypervisor": "riscv-hypervisor.kvm-smoke",
    "hwprobe": "riscv-hwprobe.authoritative-vs-isa",
    "profile": "riscv-profile.expectation-consistency",
}


def log(msg: str) -> None:
    print(msg, file=sys.stderr)


def die(msg: str, code: int = 2):
    log(f"错误: {msg}")
    sys.exit(code)


def pick_archive(arg: str | None) -> str:
    if arg and arg != "--latest":
        path = arg if os.path.isabs(arg) else os.path.join(REPO_ROOT, arg)
        if not os.path.isdir(path):
            die(f"归档目录不存在: {path}")
        return path
    dirs = sorted(d for d in glob.glob(os.path.join(HISTORY, "*")) if os.path.isdir(d))
    if not dirs:
        die("results/history/ 下没有归档，先跑 scripts/run-board-tests.sh")
    return dirs[-1]


def parse_ts(date_str: str) -> str:
    """归档名 20260912-161648 → RFC3339 UTC。无法解析时用当前时间。"""
    try:
        dt = datetime.strptime(date_str, "%Y%m%d-%H%M%S").replace(tzinfo=timezone.utc)
        return dt.isoformat().replace("+00:00", "Z")
    except ValueError:
        return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def parse_kselftest(log_path: str) -> list[dict]:
    """从 kselftest.log 里抽取每个测试项的 PASS/FAIL/SKIP（比只有汇总值更有用）。"""
    items: list[dict] = []
    if not os.path.isfile(log_path):
        return items
    pat = re.compile(r"^\s*\[(PASS|FAIL|SKIP)\]\s+(\S+)\s*(.*)$")
    with open(log_path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = pat.match(line)
            if not m:
                continue
            status, name, comment = m.group(1), m.group(2), m.group(3).strip()
            items.append({"name": name, "status": status, "comment": comment})
    return items


def build_environment(info: dict, board: dict) -> dict:
    # environment.compatible 在 KCIDB schema 里是**数组**（有序的 DT compatible 列表），不是字符串
    compatible = [c for c in (info.get("compatible") or "").split() if c]
    desc = "{} / {} / kernel {}".format(
        board.get("model", "-"), info.get("os", "-"), info.get("kernel", "-")
    )
    return {
        "compatible": compatible or ["riscv"],
        "comment": desc,          # schema 里 environment 只允许 compatible/comment/misc
        "misc": {
            "board_model": board.get("model"),
            "board_compatible": info.get("compatible"),
            "kernel": info.get("kernel"),
            "os": info.get("os"),
            "nproc": info.get("nproc"),
            "isa": board.get("isa"),
            "extensions": board.get("ext"),
        },
    }


def emit(archive: str, origin: str, build_id: str | None,
         kernel_git_url: str | None, kernel_commit: str | None) -> dict:
    results_path = os.path.join(archive, "results.json")
    if not os.path.isfile(results_path):
        die(f"{archive} 里没有 results.json")
    with open(results_path, encoding="utf-8") as fh:
        res = json.load(fh)

    date = res.get("date", os.path.basename(archive))
    start = parse_ts(date)
    board = res.get("board") or {}
    tests_in = res.get("tests") or {}
    overall = res.get("overall", "-")

    # board-info.log 里的补充信息（compatible / os / kernel / nproc）
    info: dict = {}
    bi = os.path.join(archive, "board-info.log")
    if os.path.isfile(bi):
        with open(bi, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = re.match(r"^([A-Z_]+)=(.*)$", line.strip())
                if m:
                    info[m.group(1).lower()] = m.group(2)

    env = build_environment(info, board)
    report: dict = {"version": KCIDB_VERSION}
    checkout_id = f"{origin}:p550-{date}"
    if build_id:
        my_build_id = build_id                                   # hybrid: 指向别人的 build
    else:
        my_build_id = f"{origin}:kernel-{info.get('kernel', 'unknown')}-{date}"

    mode = "hybrid" if build_id else ("self-contained" if kernel_commit else "unlinked")

    if mode == "self-contained" and not re.fullmatch(r"[0-9a-f]{40}", kernel_commit or ""):
        die(f"--kernel-commit 必须是 40 位十六进制 commit id（官方 schema 要求），收到: {kernel_commit!r}")

    if mode == "self-contained":
        # 自包含模式：带上 checkout 与 build（必须有真实 commit，否则 schema 不通过）
        checkout: dict = {
            "id": checkout_id,
            "origin": origin,
            "git_repository_url": kernel_git_url or "https://github.com/torvalds/linux.git",
            "patchset_hash": "",
        }
        # 官方 schema: git_commit_hash 若出现必须匹配 ^[0-9a-f]{40}$ → 不知道就省略，别填空串
        if kernel_commit:
            checkout["git_commit_hash"] = kernel_commit
        report["checkouts"] = [checkout | {
            "start_time": start,
            "misc": {
                "note": "被测内核来源（--kernel-commit/--kernel-git-url 由调用方提供）",
                "kernel_version": info.get("kernel"),
                "root_device": board.get("rootdev"),
            },
        }]
        report["builds"] = [{
            "id": my_build_id,
            "origin": origin,
            "checkout_id": checkout_id,
            "architecture": "riscv",
            "config_name": "eswin-vendor-defconfig",
            "compiler": "eswin-vendor",
            "status": "PASS",
            "start_time": start,
            "misc": {
                "note": "本流水线不构建内核，这是对预装内核运行结果的一次性 build 包装"
            },
        }]

    tests: list[dict] = []

    # 1) 汇总型测试项
    for key, status in tests_in.items():
        if isinstance(status, dict):
            kstatus = status.get("status", "SKIP")
            extra = {k: v for k, v in status.items() if k != "status"}
        else:
            kstatus = status
            extra = {}
        path = PATH_MAP.get(key, key.replace("_", "-"))
        tests.append({
            "id": f"{origin}:{date}:{path}",
            "origin": origin,
            "build_id": my_build_id,
            "path": path,
            "status": STATUS_MAP.get(kstatus, "ERROR"),
            "start_time": start,
            "environment": env,
            "misc": dict(extra, source_test=key, archive=os.path.basename(archive)),
        })

    # 2) kselftest 细粒度项（每个测试一条），比只有汇总值更符合 KCIDB 的 per-test 模型
    ks_items = parse_kselftest(os.path.join(archive, "kselftest.log"))
    ks_extra = tests_in.get("kselftest") if isinstance(tests_in.get("kselftest"), dict) else {}
    for item in ks_items:
        path = f"riscv-kselftest.{item['name']}"
        tests.append({
            "id": f"{origin}:{date}:{path}",
            "origin": origin,
            "build_id": my_build_id,
            "path": path,
            "status": STATUS_MAP.get(item["status"], "ERROR"),
            "start_time": start,
            "environment": env,
            **({"comment": item["comment"]} if item["comment"] else {}),
            "misc": {"source": "kselftest", "archive": os.path.basename(archive),
                     "suite_totals": {k: v for k, v in ks_extra.items() if k != "status"}},
        })
    if not ks_items and ks_extra:
        tests.append({
            "id": f"{origin}:{date}:riscv-kselftest.summary",
            "origin": origin,
            "build_id": my_build_id,
            "path": "riscv-kselftest.summary",
            "status": STATUS_MAP.get(ks_extra.get("status", "SKIP"), "ERROR"),
            "start_time": start,
            "environment": env,
            "misc": {k: v for k, v in ks_extra.items() if k != "status"},
        })

    report["tests"] = tests
    report["_meta"] = {  # 下划线前缀=本地元数据，提交前会被剥掉
        "archive": os.path.basename(archive),
        "overall": overall,
        "mode": mode,
    }
    if mode == "unlinked":
        report["_meta"]["warning"] = (
            "unlinked 模式：build_id 只是一个本地占位标识，KernelCI 侧无法解析。"
            "仅用于本地校验/预览，**不可直接提交** —— 提交请用 --build-id（hybrid，"
            "指向 Maestro build）或 --kernel-commit（自包含，需真实 commit）。"
        )
    return report


def self_check(report: dict) -> list[str]:
    """结构自检：这些是最容易违反 KCIDB 约定、又最容易被服务器打回的地方。"""
    errs: list[str] = []
    ver = report.get("version", {})
    if ver.get("major") != 5:
        errs.append(f"version.major 应为 5，实际 {ver.get('major')}")
    objs = [o for kind in ("checkouts", "builds", "tests") for o in report.get(kind, [])]
    if not objs:
        errs.append("报告里没有任何对象")
    origins = {o.get("origin") for o in objs}
    for o in objs:
        oid = o.get("id", "")
        if ":" not in oid:
            errs.append(f"id 必须形如 <origin>:<...>：{oid!r}")
        elif oid.split(":", 1)[0] != o.get("origin"):
            errs.append(f"id 前缀与 origin 不一致：{oid!r} vs {o.get('origin')!r}")
        if "status" in o and o["status"] not in VALID_STATUS:
            errs.append(f"非法 status：{o['status']!r}")
    if len(origins) > 1:
        errs.append(f"一个报告里出现多个 origin：{origins}")
    if not report.get("tests"):
        errs.append("没有 tests 对象")
    if report.get("builds"):
        co_ids = {c["id"] for c in report.get("checkouts", [])}
        for b in report["builds"]:
            if b.get("checkout_id") not in co_ids:
                errs.append(f"build {b['id']} 的 checkout_id 不在本报告的 checkouts 里")
    for t in report.get("tests", []):
        if not t.get("build_id"):
            errs.append(f"test {t['id']} 缺 build_id")
    return errs


def official_validate(report: dict) -> bool:
    """若装了官方 kcidb-io，则用它的 schema 校验（与服务器同一套）。"""
    try:
        import kcidb_io  # type: ignore
    except ImportError:
        log("（未安装 kcidb-io，跳过官方校验；pip install kcidb-io 可启用）")
        return True
    payload = {k: v for k, v in report.items() if not k.startswith("_")}
    validator = kcidb_io.schema.V5_3()   # 返回 Version 对象，直接 .validate()
    try:
        import jsonschema  # kcidb-io 的依赖，随它一起装
    except ImportError:
        validator.validate(payload)
        log("官方 kcidb-io 校验: PASS（schema v5.3）")
        return True
    try:
        validator.validate(payload)
    except jsonschema.ValidationError as exc:
        log(f"  官方校验失败 @ {list(exc.absolute_path)} → {exc.message[:220]}")
        log("官方 kcidb-io 校验: FAIL")
        return False
    log("官方 kcidb-io 校验: PASS（schema v5.3）")
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description="把真机结果归档转成 KCIDB 报告")
    ap.add_argument("archive", nargs="?", help="归档目录（默认最新）")
    ap.add_argument("--latest", action="store_true", help="用最新归档")
    ap.add_argument("--origin", default="p550_lab",
                    help="KCIDB origin（需与 KernelCI 约定；只允许 ^[a-z0-9_]+，不能有连字符）")
    ap.add_argument("--build-id", help="hybrid 模式：指向别人的 Maestro build id")
    ap.add_argument("--kernel-git-url", help="自包含模式：被测内核 git 仓库")
    ap.add_argument("--kernel-commit", help="自包含模式：被测内核 commit")
    ap.add_argument("--out", help="输出路径（默认 results/kcidb/<date>.json）")
    ap.add_argument("--print", dest="to_stdout", action="store_true", help="打印到 stdout")
    ap.add_argument("--validate", action="store_true", help="跑官方 kcidb-io 校验")
    args = ap.parse_args()

    archive = pick_archive(args.archive if not args.latest else None)
    report = emit(archive, args.origin, args.build_id, args.kernel_git_url, args.kernel_commit)

    errs = self_check(report)
    if errs:
        for e in errs:
            log(f"  结构自检失败: {e}")
        return 1
    mode = report["_meta"]["mode"]
    log(f"结构自检: PASS（{len(report['tests'])} 个 test 对象，模式={mode}）")
    for key in ("warning",):
        if key in report["_meta"]:
            log(f"⚠️  {report['_meta'][key]}")

    if args.validate and not official_validate(report):
        return 1

    payload = {k: v for k, v in report.items() if not k.startswith("_")}
    text = json.dumps(payload, indent=2, ensure_ascii=False)
    if args.to_stdout:
        print(text)
    else:
        out = args.out or os.path.join(KCIDB_OUT, f"{os.path.basename(archive)}.json")
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
        log(f"已写出 KCIDB 报告: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
