# 跨平台扩展矩阵（SOW 核心证据）

> 这张表就是 SOW 里"architectural side channels / extensions / hardware behavior variance"的落地产物。
> 三个平台同一套采集命令、同一套判定逻辑，差异即结论。
>
> 状态: **P550 一列待上板实测**（`bash scripts/run-board-tests.sh` 跑完自动产生 `results/history/<ts>/ext.log`，再回填此表）。

## 0. 已确认的硬件身份（2026-09-12，MCU 只读采集）

详见 [results/2026-09-12-mcu-board-info.md](../results/2026-09-12-mcu-board-info.md)。**这些不依赖 Linux 登录**：

| 项 | 实测值 |
|---|---|
| 载板 SN | `SF106CKB2502000039` |
| SoM SN | `SF106SKB2502000039` |
| BOM | `bomRevision 0x42`，`bomVariant 0x0` |
| MAC（3 个） | `8c:1f:64:e8:8c:15`（SOM_Mac0）/ `:16`（SOM_Mac1）/ `:17`（MCU_Mac）— **均已正确烧录** |
| "MAC 未烧录"批次问题 | **不适用**（SN 不在官方公告的受影响区间） |
| bootsel | 由 HW 控制，`bootsel[3:0] = 0b0010` |
| 板子状态 | 已启动到 `ubuntu login:`（系统层数据待登录后采集） |

## 1. 身份与启动链

| 项 | P550 (本仓库) | Lichee Pi 3A (姊妹仓库) | QEMU |
|---|---|---|---|
| SoC / 核心 | ESWIN EIC7700 / 4×SiFive P550 | SpacemiT K1 / 8×X60 | `qemu-system-riscv64 10.2.1 -cpu max`（TCG, 4 核/4G） |
| 设备树 model | **待实测** | `SiPEED LPi3A Board` | 虚拟设备树（无实体 model） |
| 内核 | **待实测**（出厂 Ubuntu 24.04 预装） | 6.1.15 (BSP) | v7.2-rc7 |
| 发行版 | **待实测**（预期 Ubuntu 24.04） | Bianbu 0.6 | openKylin 2.0 SP2 (guest) |
| 启动链 | **待实测**（预期 U-Boot → GRUB/EFI → 内核；eMMC 引导） | U-Boot 固件链 → OpenSBI → 内核（`earlycon=sbi`） | `-kernel` 直启 + OpenSBI |
| 根设备 | **待实测**（预期 eMMC） | `/dev/mmcblk2p6` | virtio-blk（`-snapshot` 零污染） |
| mvendorid | **待实测** | `0x710` (SpacemiT) | — |
| mmu | **待实测** | `sv39` | 由 `-cpu max` 决定 |

## 2. 扩展存在性

| 扩展 | P550 | li3a | QEMU (`-cpu max`) | 备注 |
|---|---|---|---|---|
| `v` (Vector) | **待实测** | present | present | li3a 实测 **VLEN=256**；QEMU 为 128 |
| `h` (Hypervisor) | **待实测** | **absent** | present | li3a 无 H → 真机 KVM 测试不可行 |
| `zpm` (Pointer masking) | **待实测** | **absent** | present | li3a 上 `kselftest pointer_masking` 只能 SKIP；该上游 bug 仅 QEMU 暴露 |
| `zicsr` / `zifencei` | **待实测** | present（随基础） | present | |
| `zicbom` / `zicboz` / `zicbop` | **待实测** | present | present | |
| `sstc` | **待实测** | present | present | |
| `sscofpmf` | **待实测** | present | present | 触发 upstream bug |
| `svpbmt` | **待实测** | present | present | |
| `zihintpause` | **待实测** | present | present | 多字母扩展：li3a 原脚本的解析方式**匹配不到**它（多字母假阴性）；本仓库 `lib-isa.sh` 可正确匹配 |
| `zba`/`zbb`/`zbs`/`zbc` | **待实测** | — | — | 由 `riscv-ext-scan.sh` 一起采 |
| `zacas` / `ztso` / `zicond` | **待实测** | — | — | 同上 |

> 采集命令（三个平台通用，同一份脚本）：
> ```bash
> bash tests/riscv-ext-scan.sh          # 打印表格 + EXT_<name>=present|absent 机器可读行
> bash tests/riscv-cpuinfo.sh i,m,a,f,d,c   # 必需扩展检查；v/h/zpm 不作硬要求
> ```
>
> ⚠️ **不要用 `grep 'h' /proc/cpuinfo` 之类的整串子串判断**：`zihintpause` 含 `h`、`svpbmt` 含 `v`、
> `zicbom` 含 `i`/`c`/`m`，单字母扩展会被大量误命中（假阳性）。
> 反过来，只截取 `rv64` 之后的单字母段（li3a 原脚本的做法）会让所有多字母扩展判不到（假阴性）。
> 本仓库的脚本两种都正确，并有 `tests/selftest-isa-parse.sh` 自检。

## 3. 性能与行为（同源代码对比）

| 测试 | P550 | li3a | QEMU |
|---|---|---|---|
| vector 加法功能 | **待实测**（若 isa 无 v → SKIP） | PASS（VLEN=256） | PASS（VLEN=128） |
| vector bench（419 万元素，`1<<22`） | **待实测** | **36.058 ms** | **380.263 ms**（≈10.5× 慢于 li3a） |
| 全量 kselftest | 待实测 | 待板子内核升级 | 9 pass / 0 skip / 1 xfail |

## 4. 回填流程

1. 板子按 [p550-bringup.md](p550-bringup.md) 打通 `ssh p550`。
2. ```bash
   bash scripts/run-board-tests.sh
   ```
3. 从 `results/history/<ts>/` 取数据回填本表：
   - `board-info.log` → 设备树 model / compatible / 内核 / 发行版 / 根设备
   - `cpuinfo.log` → `isa` 字符串、`mvendorid`/`marchid`/`mimpid`、mmu
   - `ext.log` → 各扩展 present/absent
   - `bench.log` → 向量基准耗时
   - `bootchain.log` → 实际启动链证据
4. 把"待实测"替换为实测值；**有差异的地方单独写一段说明**（差异本身就是 SOW 要的产出）。
5. 顺手补一份 `results/YYYY-MM-DD-bootchain.md`（格式参照 li3a 的 `results/2026-08-24-bootchain.md`）。
