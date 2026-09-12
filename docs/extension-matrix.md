# 跨平台扩展矩阵（SOW 核心证据）

> 这张表是 SOW 里 "architectural side channels / extensions / hardware behavior variance" 的落地产物。
> 三个平台同一套采集命令、同一套判定逻辑，差异即结论。
>
> **状态：P550 一列已完成实测（2026-09-12，真机）**，原始日志见
> `results/history/20260912-155345/`（`board-info.log` / `cpuinfo.log` / `ext.log` / `bootchain.log`）。
> 采集方式：`bash scripts/run-board-tests.sh`（over SSH，`OVERALL: PASS`）。

## 0. 一句话结论

| 平台 | 独有价值 |
|---|---|
| **P550** | **有 H 扩展 → 唯一能做真机 Hypervisor/KVM 测试的平台**；sv48；无 V |
| **Lichee Pi 3A** | **有 V（VLEN=256）→ 唯一能做真机向量测试的平台**；无 H、无 ZPM；sv39 |
| **QEMU** | 扩展最全（H/V/ZPM 都可模拟），用于补齐真机缺失的组合 |

三者互补：单看任何一块板子都无法覆盖 RISC-V 应用处理器的扩展组合。

## 1. 硬件身份（2026-09-12 实测；P550 另见 MCU 只读采集）

| 项 | P550（实测） | Lichee Pi 3A | QEMU |
|---|---|---|---|
| SoC / 核心 | ESWIN EIC7700 / **4×SiFive P550** | SpacemiT K1 / 8×X60 | `qemu-system-riscv64 10.2.1 -cpu max`（TCG, 4 核/4G） |
| 设备树 model | `SiFive HiFive Premier P550` | `SiPEED LPi3A Board` | 虚拟设备树 |
| compatible | `eswin,eic7x` | — | — |
| 内核 | `6.6.92-2025-eic7700`（ESWIN 厂商内核） | 6.1.15（BSP） | v7.2-rc7 |
| 发行版 | **Ubuntu 24.04.3 LTS** | Bianbu 0.6 | openKylin 2.0 SP2 (guest) |
| 内存 | 9.6 GiB 可用（MemTotal 10115600 kB） | 8 GB | 4 GB |
| 核数 | 4 | 8 | 4 |
| mvendorid | `0x489` | `0x710`（SpacemiT） | — |
| marchid / mimpid | `0x8000000000000008` / `0x6220425` | `0x8000000058000001` / `0x1000000049772200` | — |
| **mmu** | **sv48** | sv39 | 由 `-cpu max` 决定 |
| 载板 / SoM SN | `SF106CKB2502000039` / `SF106SKB2502000039` | — | — |

## 2. 启动链（QEMU 生成不了的证据）

| 项 | P550（实测） | Lichee Pi 3A | QEMU |
|---|---|---|---|
| 启动链路 | **U-Boot（`/boot/boot.scr`）→ GRUB（`/boot/grub`）→ EFI stub → 内核** | U-Boot 固件链 → OpenSBI → 内核 | `-kernel` 直启 + OpenSBI |
| EFI | **有**（`/sys/firmware/efi`，`fw_platform_size=64`，efivars 条目 0） | 无 | 无 |
| 根设备 | `/dev/mmcblk0p3`（ext4，eMMC 116.5 GB） | `/dev/mmcblk2p6` | virtio-blk（`-snapshot`） |
| 内核命令行 | `BOOT_IMAGE=… root=UUID=9e29d36a-… ro efi=noruntime earlycon=sbi earlycon=sbi console=ttyS0,115200n8 clk_ignore_unused cma_pernuma=0x2000000 disable_bypass=false firmware_class.path=/lib/firmware/eic7x/` | `earlycon=sbi … root=/dev/mmcblk2p6` | `-kernel` 参数 |

> 细节：`earlycon=sbi` 出现两次（重复参数）、`efi=noruntime`、`efivars` 条目为 0 ——
> 与 Ubuntu/RISC-V 侧"U-Boot 不允许 OS 写 UEFI 变量"的现象一致。
> 详见 [results/2026-09-12-bootchain.md](../results/2026-09-12-bootchain.md)。

## 3. 扩展存在性（P550 为实测值）

| 扩展 | P550 | li3a | QEMU (`-cpu max`) | 说明 |
|---|---|---|---|---|
| `h`（Hypervisor） | **present** ✅ | absent | present | **P550 的独有能力**；li3a 无法做真机 KVM |
| `v`（Vector） | absent | **present**（VLEN=256） | present | P550 的 vector 测试按设计记为 SKIP |
| `zpm`（Pointer masking） | absent | absent | present | 真机均无；该上游 bug 仅在 QEMU 暴露 |
| `zicsr` / `zifencei` | present | present | present | |
| `zicntr` / `zihpm` | **present** | — | — | P550 计数器支持 |
| `sscofpmf` | present | present | present | |
| `zba` / `zbb` | **present** | absent | — | P550 有位操作扩展 |
| `zbs` / `zbc` / `zbkb` | absent | — | — | |
| `zicbom` / `zicboz` / `zicbop` | **absent** | present | present | 双方互补 |
| `svpbmt` | **absent** | present | present | |
| `sstc` | **absent** | present | present | |
| `zihintpause` | **absent** | present | present | 该扩展含字母 `h`，是子串匹配假阳性的经典陷阱 |
| `zicond` / `zacas` / `ztso` / `zfh` | absent | — | — | |

P550 实测完整 isa 字符串：

```
rv64imafdch_zicntr_zicsr_zifencei_zihpm_zba_zbb_sscofpmf
```

## 4. 内核能力 vs 硬件能力（配置漂移）

P550 的厂商内核**编译时开启了一些硬件并不具备的扩展支持**，这类"内核配置 vs 硬件能力"的错位正是 SOW 要自动捕捉的配置漂移：

| 配置项（`/boot/config-6.6.92-2025-eic7700`） | 内核 | 硬件 isa | 结论 |
|---|---|---|---|
| `CONFIG_RISCV_ISA_V=y` + `V_DEFAULT_ENABLE=y` | 支持 V | **无 v** | 内核支持向量，硬件没有 → 无法使用，需以 `isa` 为准判定 |
| `CONFIG_RISCV_ISA_SVPBMT=y` | 支持 Svpbmt | **无 svpbmt** | 同上 |
| `CONFIG_RISCV_ISA_ZICBOM=y` / `ZICBOZ=y` | 支持 | **无** | 同上 |
| `CONFIG_RISCV_ISA_ZBB=y` | 支持 | **有 zbb** | 一致 |
| `CONFIG_RISCV_ISA_SVNAPOT=y` | 支持 Svnapot | isa 未列出 | 待进一步确认（可能由 DT 决定） |

> **方法学结论**：只读内核配置会得到"支持 V"的错误印象；必须以运行时 `isa`
> （或 `riscv_hwprobe(2)`）为准。本仓库的 `riscv-ext-scan.sh` 就是干这个的。

## 5. Hypervisor / KVM 现状（P550 独有路径）

| 检查 | 结果 |
|---|---|
| ISA `h` 扩展 | ✅ present |
| `kvm.ko` | ✅ 存在：`/lib/modules/6.6.92-2025-eic7700/kernel/arch/riscv/kvm/kvm.ko` |
| 模块是否加载 | ❌ 未加载（`lsmod` 无 kvm） |
| `/dev/kvm` | ❌ 不存在 |

→ **真机 Hypervisor 测试的硬件与内核模块都已具备，只差加载模块**。
这需要板子主人同意后执行 `sudo modprobe kvm`（本次采集**未**加载模块、**未**做任何系统改动）。
这是 P550 相对 li3a 的关键增量：li3a 因无 H 扩展，真机 KVM 路径不可行。

## 6. 性能

| 测试 | P550 | li3a | QEMU |
|---|---|---|---|
| vector 加法（419 万元素） | **SKIP**（无 V 扩展） | 36.058 ms（VLEN=256） | 380.263 ms（VLEN=128） |
| kselftest | 待跑 | 待板子内核升级 | 9 pass / 0 skip / 1 xfail |

## 7. 复现方式

```bash
bash scripts/run-board-tests.sh          # 一条命令：同步→采集→归档→verdict→趋势表
cat results/trend.md                     # 回归趋势（含 h/v/zpm 列）
```
