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
| SoC / 核心 | ESWIN EIC7700 / **4×SiFive P550** | SpacemiT K1 / 8×X60 | `qemu-system-riscv64 -cpu max`（TCG, 4 核/4G） |
| 系统 | **Ubuntu 24.04.3 LTS / 内核 6.6.92-2025-eic7700** | Bianbu 0.6 / 内核 6.1.15 | openKylin 2.0 SP2 guest |
| 内存 / mmu | 9.6 GiB 可用 / **sv48** | 8 GB / sv39 | 4 G / — |
| 接入 | **USB-C 串口（带外）+ 校园网直连 SSH 免密** | 局域网 SSH 免密 | 本地进程 `-snapshot` |
| **扩展能力（实测）** | **有 H（唯一能跑真机 KVM）；无 V；无 ZPM** | 有 V（VLEN=256）；无 H；无 ZPM | 含 H / V / ZPM 模拟 |

> 结论：**P550 与 li3a 恰好互补** —— P550 提供真机 Hypervisor 路径，li3a 提供真机向量路径。
> 详见 [docs/extension-matrix.md](docs/extension-matrix.md)。

**真机实测（2026-09-12）**：`OVERALL: PASS`（cpuinfo / ext-scan / board-info / bootchain 全 PASS；
vector 因无 V 扩展按设计记 `SKIP`）。证据：[results/2026-09-12-bootchain.md](results/2026-09-12-bootchain.md)、
[results/2026-09-12-mcu-board-info.md](results/2026-09-12-mcu-board-info.md)。

## 目录结构

```
docs/     上板 runbook、跨平台扩展矩阵、SOW 阶段映射
tests/    板子侧脚本（身份/扩展/启动链/向量/hypervisor）；含两个可脱离硬件跑的自检
          （板上没有 gcc，需要编译的测试在本机交叉编译后同步）
scripts/  本机侧流水线（一键测试、趋势表）、交叉编译（KVM/kselftest）与接入助手
udev/     让 ModemManager 忽略 P550 串口的规则（解决串口 Device or resource busy）
profile/  RISC-V 扩展测试 profile（机器可读的期望值 + 漂移检测，SOW Phase 3 的交付物实体）
integration/kernelci/  Phase 3 集成工作区：KCIDB 报告生成与上游 Maestro 配置草案（尚未提 PR）
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

# 1b. 不想用 picocom / 要录日志 → 非交互抓取（会拉高 DTR/RTS 并自动判定通道）
python3 scripts/p550-serial-capture.py --all --seconds 5 --send-enter

# 2. 本机有线网口共享给板子（校园网走 WiFi，板子走 RJ45 → NAT）
bash scripts/p550-net-share.sh setup

# 3. 配好 ssh p550 免密别名
bash scripts/p550-net-share.sh write-ssh-config
ssh-copy-id p550

# 4. 一条命令跑全套真机测试（同步→测试→归档→verdict→趋势表）
bash scripts/run-board-tests.sh

# 5. 看回归趋势
cat results/trend.md

# 6. Phase 3：把结果转成 KernelCI 的 KCIDB 格式（可选官方 schema 校验）
python3 scripts/kcidb-emit.py --latest --validate --print
```

**不接触板子验证流水线逻辑**（改脚本时很有用，CI 也跑这个）：

```bash
DRY_RUN=1 bash scripts/run-board-tests.sh
```

**两个实测踩到的坑**（详见 [docs/p550-bringup.md](docs/p550-bringup.md) 第 0.6/0.7 节）：

```bash
# 坑 1: usermod -aG dialout 后没注销 → 串口报「权限不够」
id -nG                      # 当前会话真实生效的组（可能没有 dialout）
id -nG "$USER"              # 组数据库（有 dialout）→ 两者不一致就是这样来的
sg dialout -c 'python3 scripts/p550-serial-capture.py --all --seconds 5'   # 免注销临时解法

# 坑 2: ModemManager 占用串口 → stty/picocom 报 Device or resource busy
sudo cp udev/99-p550-serial.rules /etc/udev/rules.d/ && sudo udevadm control --reload-rules && sudo udevadm trigger
```

> ⚠️ 若板子**不是你自己的**：不要改密码、不要重启、不要执行 MCU 的 `set*` 写命令（`setmac`/`setip`/`bootsel-s`/…）。
> MCU 只读命令：`cbinfo-g`、`sominfo`、`ifconfig`、`bootsel-g`、`temp`、`date`、`stats`。

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
| **真机 Hypervisor（H/KVM）** | `tests/riscv-hypervisor.sh` + `tests/riscv_kvm_smoke.c` | 无 h / 无 `/dev/kvm` → **SKIP**；客户机起不来 → FAIL；产生预期 MMIO 退出 → PASS |
| **riscv kselftest 子集** | `tests/riscv-kselftest.sh` + `scripts/build-kselftest.sh` | 缺 V/ZPM 的用例按平台能力 **SKIP**；其余按 TAP 结果判 PASS/FAIL |
| **`riscv_hwprobe(2)` 权威探针** | `tests/riscv-hwprobe.sh` + `tests/riscv_hwprobe_dump.c` | 与 `/proc/cpuinfo` 的 `isa` 逐项交叉验证，不一致数记入 `hwprobe.mismatch` |
| **profile 一致性（漂移检测）** | `scripts/check-profile.py` + `profile/riscv-extensions.json` | 实测与 profile 期望逐项比对，不一致数记入 `profile.mismatch`（不判本次失败但显著提示） |

> `SKIP` 语义：平台合理缺失（例如 P550 若不带 V）记为 SKIP 而不是 FAIL，
> 趋势表同时呈现"通过率"和"能力差异"。详见 [results/README.md](results/README.md)。

## CI 接入

- 云端 `lint`：每次 push 跑 `bash -n`、Python 语法检查、ISA 解析自检、假板流水线自检、以及 `DRY_RUN=1` 的流水线自检（完全不碰板子）。
- 自托管 `board-tests`：在你自己电脑上跑真机全套 → 归档 → 趋势表 → `ci-bot` 提交回仓库。
- 门控：`vars.P550_RUNNER == 'ready'` + 仅主仓库（`github.repository`）—— 没注册 runner 之前真机任务不会排队（GitHub 在没有 runner 时会永久排队，每次 push 堆一个 run），也防止 fork 借 runner 跑代码。

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

# 3) 打开真机任务开关（在此之前 push 只跑云端 lint）
gh variable set P550_RUNNER --body ready --repo Acidmoon/kernelci-riscv-p550
```

> workflow 用的是 `runs-on: [self-hosted, p550]`，所以 **`--labels p550` 是必须的**；`P550_RUNNER` 变量不设时真机任务直接跳过（不会排队）。

### 当前状态（2026-09-12 已落地）

| 项 | 值 |
|---|---|
| runner | `acidmoon-deepin-p550`（标签 `self-hosted,Linux,X64,p550`），已注册并 online |
| 仓库变量 | `P550_RUNNER=ready`（真机任务开关）、`KERNEL_TREE=/home/Acidmoon/kernelci-work/linux`（CI 里也能跑 kselftest） |
| workflow 权限 | `default_workflow_permissions=write`（让 `ci-bot` 能把结果提交回仓库） |
| 触发方式 | **push 只跑云端 lint**（几秒、不碰硬件）；**真机测试手动触发**：`gh workflow run "Board CI (HiFive Premier P550)"` |
| 验证 | 手动 dispatch → 真机任务全绿，`ci: record p550 board tests <ts>` 提交自动回填 `results/` |
| 为什么这样 | 真机任务在自托管 runner 上**一定会启动**（与板子是否在线无关）；板子离线时若跟着 push 跑，每次 push 都会得到一次失败。改为手动触发后，板子在不在线都不影响 push 的绿灯 |

> ⚠️ **runner 的持久性**：目前这个 runner 是**前台进程**启动的，会话结束就停。
> 要开机自启（推荐）需要一次性执行（需 sudo 密码，只有你能做）：
> ```bash
> cd ~/actions-runner-p550 && sudo ./svc.sh install && sudo ./svc.sh start
> ```
> 在装好服务之前，如果 runner 停了，真机任务会**排队**；此时先关掉开关避免堆积：
> ```bash
> gh variable set P550_RUNNER --body off --repo Acidmoon/kernelci-riscv-p550
> ```

## 已知边界（如实记录）

- **P550 无 WiFi**（M.2 E-Key SDIO WiFi 明确不支持）→ 只走有线。本环境实测：板子 `end1` 直接挂在校园网上
  （`10.13.22.70/20`，本机可 ping/ssh），所以 **NAT 共享那套没用上**——`scripts/p550-net-share.sh` 保留作为
  "板子无法直接接入网络时"的备用方案。
- **有 H 无 V** → 向量测试按设计记 `SKIP`（不算失败）；**H 让真机 KVM 成立**：
  `modprobe kvm` + `scripts/p550-kvm-setup.sh`（一次性、可撤销）之后，
  `tests/riscv_kvm_smoke.c` 的客户机测试在真机上 **PASS**。
- **内核配置 vs 硬件能力错位**：厂商内核开了 `CONFIG_RISCV_ISA_V/SVPBMT/ZICBOM/ZICBOZ=y`，但硬件 isa 里没有
  → 只能以运行时 `isa`（或 `riscv_hwprobe(2)`）为准，别信内核配置。
- **本机交叉 gcc 12.3 不支持 RVV 内建**（需 GCC 13+）→ 向量测试只能由板子 native gcc 编译。
- **板子属于他人** → 不做密码修改、不重启、不加载模块、不执行 MCU `set*` 写命令；只做只读采集
  （唯一的写入是 `~/KernelCI-pipeline` 测试脚本与 `/tmp` 二进制）。
- `riscv_hwprobe(2)` 权威探针尚未接入（当前以 `/proc/cpuinfo` 的 `isa` 为依据），列为下一步。

## 计划

- [x] 上板 runbook（串口通道判定 + 组权限坑 + 排查表）
- [x] 真机流水线（身份/扩展/启动链/向量，含 DRY_RUN 自检与假板集成测试）
- [x] 跨平台扩展矩阵（P550 / li3a / QEMU）
- [x] CI（云端 lint + 自托管真机任务）
- [x] **上板实测并回填矩阵与 `results/`**（2026-09-12，`OVERALL: PASS`）
- [x] **真机 Hypervisor 测试（客户机在 H 扩展上执行并产生预期 MMIO 退出）**
- [ ] 接入 `riscv_hwprobe(2)` 权威探针（与 `/proc/cpuinfo` 交叉验证）
- [x] **板上跑 riscv kselftest 子集**（P550: 3P/0F/4S，与 QEMU 9P/0S/1X 同口径对照）
- [ ] Phase 3：向上游 KernelCI 提交 RISC-V test profile
- [ ] Phase 4：runbook / 博客 / demo / LF 徽章

详见 [docs/sow-mapping.md](docs/sow-mapping.md)。
