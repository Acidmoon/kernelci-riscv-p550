# 本仓库与 SOW 的对应关系

SOW: [riscv-admin/dev-partners#49 — KernelCI: Statement of Work](https://github.com/riscv-admin/dev-partners/issues/49)
姐妹仓库: [Acidmoon/kernelci-riscv-li3a](https://github.com/Acidmoon/kernelci-riscv-li3a)（真机 #1）

## 阶段映射

| SOW 阶段 | 交付要求（SOW 原文要点） | 本仓库对应物 |
|---|---|---|
| **Phase 1** Setup & Initial PR | 本地容器化测试流水线初始化；跟踪 issue；首个校验脚本能本地解析 | `scripts/run-board-tests.sh`（一条命令闭环）+ `tests/*.sh`（板子侧）+ `results/history/<ts>/results.json` |
| **Phase 2** Core Logic / Feature | 主执行逻辑部署；自动捕捉配置漂移；对目标扩展（如 Vector/Hypervisor）测回归通过率 | `tests/riscv-ext-scan.sh` + `tests/riscv-cpuinfo.sh`（扩展/配置漂移检测）+ `scripts/report-history.py`（回归趋势表，SKIP 语义）+ `docs/extension-matrix.md`（跨平台矩阵） |
| **Phase 3** Upstream / Integration | 向 KernelCI 主代码库提正式 PR，集成 RISC-V 测试 profile | 🟡 **profile 已实体化**（`profile/riscv-extensions.json` + `scripts/check-profile.py`，期望值可执行断言 + 漂移检测）；KCIDB 结果格式已打通（`scripts/kcidb-emit.py`，官方 schema 校验通过）；**PR 尚未提**（按指示按住）。注意上游现状：`kernelci-core/test-configs.yaml` 已 LEGACY，现代路径是 `kernelci-pipeline` 配置或 KCIDB 提交 |
| **Phase 4** Documentation & Demo | 测试执行 runbook；技术博客草稿；demo 录制 | `docs/p550-bringup.md`（runbook 已成型）+ `docs/extension-matrix.md` + 本文件 |

## 本仓库相对 li3a 的增量（不只是换块板子）

| 增量 | 价值 |
|---|---|
| **第二块真机**（不同 SoC/微架构：EIC7700 4×P550 vs K1 8×X60） | 满足 SOW "hardware behavior variance across early-adopter development boards" |
| **修正 ISA 解析缺陷** | li3a 版 `li3a-cpuinfo.sh` 只把 `rv64` 之后的**单字母段**当扩展集（`EXTS=imafdcv`），因此**多字母扩展永远判为"没有"（假阴性）**：实测 `zicbom` 明明在 li3a 的 isa 串里，脚本仍报 absent。对 `v` 这类单字母检测碰巧正确，但 SOW 矩阵要的 `zpm`/`zba`/`zicbom` 全都会误报。本仓库用 `tests/lib-isa.sh` 正确解析两类扩展，并用 `tests/selftest-isa-parse.sh`（21 条断言，x86 上可跑、已接入 CI）把它钉住 |
| **SKIP 语义** | 平台合理缺失（如无 V 扩展）记为 SKIP 而非 FAIL，差异作为结论保留；趋势表能同时呈现"通过率"和"能力差异" |
| **`DRY_RUN=1` 本地自检** | 不接触板子即可验证流水线逻辑，已接入 CI 的 lint 任务；降低"改脚本 → 上板才发现错"的成本 |
| **带外优先的接入设计** | 串口（带外）+ NAT 共享（带内）+ 体检脚本，把"板子连不上"从玄学变成有清单的检查项 |
| **为学生/校园网环境设计** | 绕开 Portal 认证与客户端隔离，不需要网络中心配合即可完成真机测试 |

## 已完成（2026-09-12 首次真机实测）

- [x] **上板并跑通真机流水线**：`bash scripts/run-board-tests.sh` → `OVERALL: PASS`
      （board-info / cpuinfo / ext-scan / bootchain 全 PASS；vector 按设计 `SKIP`，因硬件无 V）
- [x] **回填 `docs/extension-matrix.md` 的 P550 一列**（含身份、启动链、扩展存在性、性能）
- [x] **产出 `results/2026-09-12-bootchain.md`**（P550 启动链快照：U-Boot→GRUB→EFI stub→内核）
- [x] **产出 `results/2026-09-12-mcu-board-info.md`**（MCU 只读采集：SN / MAC / bootsel / 温度）

### 实测带来的关键结论（对 SOW 有直接价值）

1. **P550 有 H 扩展、li3a 有 V 扩展** → 两块真机恰好互补，任何单块板都无法覆盖
   "真机 Hypervisor + 真机 Vector" 两条路径。这正是 SOW 要求"跨早期采用开发板的硬件行为差异"的现实理由。
2. **真机 KVM 路径存在**：ISA 有 `h`，`kvm.ko` 也在（`/lib/modules/6.6.92-2025-eic7700/kernel/arch/riscv/kvm/kvm.ko`），
   只是尚未加载。加载后 P550 可跑真机 KVM guest —— 这是 li3a（无 H）**根本做不到**的测试维度。
3. **配置漂移实例**：厂商内核开了 `CONFIG_RISCV_ISA_V/SVPBMT/ZICBOM/ZICBOZ=y`，
   但硬件 `isa` 里没有 → 只信内核配置会得出错误的能力结论。可作为 Phase 2"自动捕捉配置漂移"的真实样本。
4. **地址空间差异**：P550 `sv48` vs li3a `sv39` vs QEMU 由 `-cpu max` 决定。
5. **启动链差异**：P550 是 U-Boot → GRUB → EFI stub（`efivars` 条目为 0、`efi=noruntime`），
   li3a 是 U-Boot → OpenSBI 直启，QEMU 是 `-kernel` 直启 —— 三种都不同。

## 未完成 / 下一步

- [x] **真机 Hypervisor/KVM 测试**：`modprobe kvm` + 一次性配置后，客户机在 H 扩展上真实执行（PASS）
- [x] **板上跑 riscv kselftest 子集**（3P/0F/4S）：`hwprobe` 真机 PASS；缺 V/ZPM 的 4 个用例按平台能力 SKIP（与 QEMU 的 9P/0S/1X 同口径对照）
- [x] **接入 `riscv_hwprobe(2)` 权威探针**：`IMA_EXT_0=0x1b`、非对齐访问=slow；与 cpuinfo 交叉验证 17 项全一致；并发现"厂商内核对未定义 key 返回 0"这一行为差异
- [ ] Phase 3：向 KernelCI 上游提交 RISC-V test profile（Maestro/kci-dev 路径）
- [ ] 后期 lab 化：串口按 `/dev/serial/by-id/` 固定 + MCU 电源控制 + LAVA device-type（参考 RISE RP012 / Collabora 的公开文档）
- [x] **CI 真机自动化落地**：自托管 runner `acidmoon-deepin-p550`（label `p550`）+ 仓库变量
      `P550_RUNNER=ready` / `KERNEL_TREE` + workflow 写权限；`gh workflow run` 验证全绿，
      结果由 `ci-bot` 自动提交回 `results/`
- [ ] Phase 4：补博客草稿与 demo 脚本

## 与上游生态的衔接（避免重复造轮子）

- **RISE RP012**（Enabling Linux Kernel CI Testing on RISC-V Boards）已由 Collabora 把 **HiFive Premier P550 接入公开 LAVA lab**，做法：MCU 串口做电源/boot mode 控制 + BootROM fastboot 刷引导链 + Boardswarm。
  博客: <https://test.www.collabora.com/news-and-blog/news-and-events/tested-on-real-silicon-automating-risc-v-hardware-in-the-loop.html>
  板级文档: <https://lava.pages.collabora.com/docs/boards/eic7700-hifive-premier-p550/>（有反爬，浏览器打开）
- 本仓库 Phase 1–2 的定位是"**低门槛、可复现的真机回归闭环**"，Phase 3 再对齐上游 LAVA/KernelCI 的接口。
