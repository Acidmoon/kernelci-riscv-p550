# kernelci-riscv-p550

KernelCI RISC-V real-hardware validation: **SiFive HiFive Premier P550**（ESWIN EIC7700 SoC，4×SiFive P550）
作为 RISC-V Development Partners SOW 的**第二块真机平台**。

KernelCI RISC-V 真机验证：**真机 #2 = HiFive Premier P550**，与
[kernelci-riscv-li3a](https://github.com/Acidmoon/kernelci-riscv-li3a)（真机 #1 = Lichee Pi 3A / SpacemiT K1）
使用**同一套测试标准与流水线**，共同支撑
[riscv-admin/dev-partners#49](https://github.com/riscv-admin/dev-partners/issues/49)
中"跨微架构硬件行为差异"的验证目标。

## 平台定位

| | P550（本仓库） | Lichee Pi 3A（姊妹仓库） | QEMU |
|---|---|---|---|
| SoC / 核心 | ESWIN EIC7700 / 4×SiFive P550 | SpacemiT K1 / 8×X60 | `qemu-system-riscv64 -cpu max`（TCG） |
| 系统 | 出厂 Ubuntu 24.04（eMMC） | Bianbu 0.6 / 内核 6.1.15 | openKylin 2.0 SP2 guest |
| 接入 | **USB-C 串口（带外）+ 有线网络（本机 NAT 共享）** | WiFi/局域网 SSH 免密 | 本地进程 `-snapshot` |
| 扩展能力 | **待实测**（h/v/zpm 由板上 `riscv-ext-scan.sh` 判定） | 有 V(VLEN=256)，无 H，无 ZPM | 含 H / ZPM 模拟 |

## 目录结构

```
docs/     上板 runbook、跨平台扩展矩阵、SOW 阶段映射
tests/    板子侧脚本（身份/扩展/启动链/向量），板卡无关命名以复用
scripts/  本机侧流水线（一键测试、趋势表）与接入助手（串口、网络共享、体检）
.github/  CI（云端 lint + dry-run；自托管 runner 跑真机）
results/  运行存档（history/ 自动归档 + trend.md 趋势表）
```

## 快速开始

```bash
# 0. 体检：本机 ↔ P550 还差什么（会直接告诉你下一步命令）
bash scripts/p550-doctor.sh

# 1. 串口控制台（带外，保命通道；先开终端再按板子 PWR 键上电）
bash scripts/p550-serial.sh list
bash scripts/p550-serial.sh probe
bash scripts/p550-serial.sh open soc

# 2. 本机有线网口共享给板子（校园网走 WiFi，板子走 RJ45 → NAT）
bash scripts/p550-net-share.sh setup

# 3. 配好 ssh p550 免密别名
bash scripts/p550-net-share.sh write-ssh-config
ssh-copy-id p550

# 4. 一条命令跑全套真机测试（同步→测试→归档→verdict→趋势表）
bash scripts/run-board-tests.sh

# 5. 看回归趋势
cat results/trend.md
```

**不接触板子验证流水线逻辑**（改脚本时很有用，CI 也跑这个）：

```bash
DRY_RUN=1 bash scripts/run-board-tests.sh
```

上板详细步骤、预期输出、验收标准与故障排查见 **[docs/p550-bringup.md](docs/p550-bringup.md)**。

## 接入架构

```
         校园网(需认证)
              │ WiFi（本机认证）
        ┌─────┴─────┐
        │   本机     │  10.42.0.1 = DHCP + NAT
        └──┬─────┬──┘
     USB-C │     │ RJ45
   (串口带外) │     │ (带内)
        ┌──┴─────┴──┐
        │   P550    │  end0 = 10.42.0.x
        └───────────┘
```

为什么不让板子直接插校园网：Portal/客户端认证 + 客户端隔离 + MAC 绑定，
未认证设备插上就是不通。让本机完成认证、板子走 NAT，是最省事且不依赖网络中心配合的做法。

## 测试项

| 测试 | 脚本 | 判定 |
|---|---|---|
| 板卡身份/存储/内存/首次启动 | `tests/p550-board-info.sh` | 输出 `BOARDINFO_STATUS=PASS` |
| CPU 身份 + 必需扩展 | `tests/riscv-cpuinfo.sh` | 缺必需扩展（默认 RV64GC）→ FAIL |
| 扩展矩阵扫描 | `tests/riscv-ext-scan.sh` | 只记录不判失败（差异是结论） |
| 向量功能/性能 | `tests/p550-vector.sh add\|bench` | 无 v 或无 gcc → **SKIP**；有 v 但编译失败 → FAIL |
| 启动链/固件证据 | `tests/p550-bootchain.sh` | 输出 `BOOTCHAIN_STATUS=PASS` |

> `SKIP` 语义：平台合理缺失（例如 P550 若不带 V）记为 SKIP 而不是 FAIL，
> 趋势表同时呈现"通过率"和"能力差异"。详见 [results/README.md](results/README.md)。

## CI 接入

- 云端 `lint`：每次 push 跑 `bash -n`、Python 语法检查、以及 `DRY_RUN=1` 的流水线自检（完全不碰板子）。
- 自托管 `board-tests`：在你自己电脑上跑真机全套 → 归档 → 趋势表 → `ci-bot` 提交回仓库。
- 保险丝：`if: github.repository == 'Acidmoon/kernelci-riscv-p550'`，不监听 PR，防止 fork 借 runner。

**需要一次性的 runner 注册**（GitHub 的 self-hosted runner 是仓库级的，li3a 那个实例不能复用）：

```bash
# 1) 取注册 token（需要仓库 admin 权限）
gh api -X POST /repos/Acidmoon/kernelci-riscv-p550/actions/runners/registration-token --jq .token

# 2) 新开一个 runner 目录（不要和 li3a 的 runner 目录混用）
mkdir -p ~/actions-runner-p550 && cd ~/actions-runner-p550
#    下载 actions-runner-linux-x64-*.tar.gz（或复用你已有的安装包）并解压
./config.sh --url https://github.com/Acidmoon/kernelci-riscv-p550 \
            --token <上一步的TOKEN> --labels p550
sudo ./svc.sh install && sudo ./svc.sh start
```

> workflow 用的是 `runs-on: [self-hosted, p550]`，所以 **`--labels p550` 是必须的**。

## 已知边界（如实记录）

- **P550 无 WiFi**（M.2 E-Key SDIO WiFi 明确不支持）→ 只走有线；NAT 共享模式下板子**不能被外部主动访问**，因此只适用于 Phase 1–2，lab 化需换独立路由器或给板子做校园网注册。
- **板子是否带 V / H / ZPM 未实测** → 矩阵中标为"待实测"；若不带 V，向量测试记 SKIP（不影响整体 PASS）。
- **本机交叉 gcc 12.3 不支持 RVV 内建**（需 GCC 13+）→ 向量测试由板子 native gcc 编译；板子 gcc 若 < 13，向量项会 FAIL（属可行动发现，不是平台缺陷）。
- **出厂 MAC 未烧录批次**（特定序列号）→ 不先修 MAC，DHCP/SSH 必然失败。
- `riscv_hwprobe(2)` 权威探针尚未接入（当前以 `/proc/cpuinfo` 的 `isa` 为依据），列为下一步。

## 计划

- [x] 上板 runbook（串口 + MAC + NAT 共享 + SSH 别名 + 验收/排查）
- [x] 真机流水线（身份/扩展/启动链/向量，含 DRY_RUN 自检）
- [x] 跨平台扩展矩阵模板（P550 / li3a / QEMU）
- [x] CI（云端 lint + 自托管真机任务）
- [ ] 上板实测，回填矩阵与 `results/`
- [ ] 接入 `riscv_hwprobe(2)` 权威探针（与 `/proc/cpuinfo` 交叉验证）
- [ ] Phase 3：向上游 KernelCI 提交 RISC-V test profile
- [ ] Phase 4：runbook / 博客 / demo / LF 徽章

详见 [docs/sow-mapping.md](docs/sow-mapping.md)。
