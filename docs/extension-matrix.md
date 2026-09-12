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

## 5. Hypervisor / KVM（P550 独有路径，已实测 PASS）

| 检查 | 结果 |
|---|---|
| ISA `h` 扩展 | ✅ present（`rv64imafdch`） |
| `kvm.ko` | ✅ `/lib/modules/6.6.92-2025-eic7700/kernel/arch/riscv/kvm/kvm.ko` |
| `modprobe kvm` | ✅ 成功；`dmesg` 报 **`hypervisor extension available`**、`using Sv48x4 G-stage page table format`、**`VMID 0 bits available`** |
| `/dev/kvm` | ✅ 存在（按 `udev/60-p550-kvm.rules` 归 `kvm` 组、0660，便于自动化） |
| **客户机实测** | ✅ **PASS** —— 创建 VM/vCPU，客户机执行 3 条 RV64 指令并触发 `KVM_EXIT_MMIO`（`phys_addr=0x10000000`） |

测试实现：`tests/riscv_kvm_smoke.c`（本机交叉编译成静态二进制，因为**板上没有 gcc**）。
它不依赖 qemu、不需要客户机镜像：自己建 VM、注册 4 KiB guest 内存（GPA `0x8000_0000`）、
写入 guest 代码、设 PC、`KVM_RUN`，然后断言退出原因确实是 MMIO。

**硬件实现差异（值得记录）**：`VMID 0 bits available` 表示 hgatp 的 VMID 字段宽度为 0，
即没有 VMID 标记能力；G-stage 页表格式为 `Sv48x4`。

**guest ISA 位图疑点（已收敛到"厂商枚举不同"，非读取错误）**：
`KVM_GET_ONE_REG` 读到的 guest ISA 位图原始值为 `0x112d`。按上游 v6.6 的
`KVM_RISCV_ISA_EXT_*` 枚举会解成 A/D/F/I/Sstc/Zicboz，但本机**两路独立证据**
（`/proc/cpuinfo` 的 `isa` 与 `riscv_hwprobe(2)` 的 `IMA_EXT_0`）都表明硬件**没有 Sstc/Zicboz、有 Zba/Zbb**。

为了排除"读错偏移"这种可能，测试里加了**自检**：读同一个 `struct kvm_riscv_config` 的
mvendorid/marchid/mimpid（偏移 2/3/4），实测得到

```
guest mvendorid : 0x489
guest marchid   : 0x8000000000000008
guest mimpid    : 0x6220425
```

与主机的 `0x489 / 0x8000000000000008 / 0x6220425` **完全一致** → 偏移假设成立 →
偏移 0 确实是 `isa`，`0x112d` 是权威值。

结论：**该厂商内核（6.6.92-eic7700）的 KVM ISA 枚举顺序或位图语义与上游 v6.6 不一致**。
因此测试程序只报原始值、不做名字解码；要彻底定案需读该厂商内核源码里的
`arch/riscv/include/uapi/asm/kvm.h`（板上没有这个头文件，只有 `linux/kvm.h`）。

## 6. 性能

| 测试 | P550 | li3a | QEMU |
|---|---|---|---|
| vector 加法（419 万元素） | **SKIP**（无 V 扩展） | 36.058 ms（VLEN=256） | 380.263 ms（VLEN=128） |
| **hypervisor（KVM 冒烟测试）** | **PASS**（客户机在真机 H 上执行） | 不可行（无 H） | 可运行（模拟） |
| kselftest（riscv 子集） | **3 pass / 0 fail / 4 skip** | 待板子内核升级 | **9 pass / 0 skip / 1 xfail**（全量） |

## 7. 权威探针：`riscv_hwprobe(2)`（真机实测）

`/proc/cpuinfo` 的 `isa` 是**内核汇总出来的字符串**；`riscv_hwprobe(2)` 才是内核提供给用户态的
**权威结构化**能力接口（机器可读、且能给出 isa 字符串给不出的信息）。两者交叉验证结果：

| hwprobe 项 | P550 实测值 |
|---|---|
| `MVENDORID` / `MARCHID` / `MIMPID` | `0x489` / `0x8000000000000008` / `0x6220425`（与 cpuinfo 完全一致 ✓） |
| `BASE_BEHAVIOR` | `0x1` → IMA 基线存在 |
| `IMA_EXT_0` | **`0x1b`** = FD \| C \| Zba \| Zbb |
| `CPUPERF_0` | 非对齐访问 = **slow** |
| key 6..16（Zicboz 块大小 / 最高虚拟地址 / TIME CSR 频率 / 非对齐标量性能 / IMA_EXT_1 …） | 全部返回 **0** |

**交叉验证（同一份流水线自动执行）**：17 个扩展在 hwprobe 与 cpuinfo 之间**全部一致，0 处不一致**。

**三条方法学结论（都来自实测）**：

1. **hwprobe 不覆盖 H**。Hypervisor 是特权扩展，不在 `IMA_EXT_0` 里 →
   **H 的结论只能来自设备树/cpuinfo**。两者是互补关系，不能互相替代。
2. **本板厂商内核与上游约定有一处偏差**：上游规定"未定义的 key 返回 -1"，
   而本板 6.6.92 内核对 key 6..16 一律返回 **0** →
   在这台板子上**不能靠 `-1` 判断某个 key 是否被支持**。这是真实可复现的行为差异。
3. **一个 hwprobe 位可能对应多个 cpuinfo 字母**：`IMA_FD` 位 = `f` + `d` 都有。
   我第一版比较逻辑直接拿 `"fd"` 去 isa 里找 → 误报"配置漂移"；修正为显式映射后 0 不一致。
   （这条也说明：**交叉验证脚本本身要有自检**，否则会制造假警报。）

复现：

```bash
bash scripts/run-board-tests.sh        # [3.9] hwprobe 步骤自动跑探针 + 交叉验证
```

## 8. kselftest 对照（同源码、同口径）

同一套 kselftest 源码（本机内核树 v7.2-rc7）交叉编译后在 P550 真机运行；
QEMU 侧基线来自同事的 v7.2-rc7 全量运行。

| 测试 | P550（真机） | 判定依据 |
|---|---|---|
| `hwprobe/hwprobe` | **PASS**（5/5） | `riscv_hwprobe(2)` 语义测试 —— 真机上通过 |
| `mm/mmap_default` | **PASS**（1/1） | 默认 rlimit 下应为 TOP_DOWN 布局 |
| `mm/mmap_bottomup` | **PASS**（1/1） | 需 `ulimit -s unlimited`（上游 `run_mmap.sh` 如此调用） |
| `abi/pointer_masking` | **SKIP** | 平台无 `zpm` → 上游测试会 `Bail out!` |
| `sigreturn/sigreturn` | **SKIP** | 平台无 `v` → 直接 SIGILL（signal 4） |
| `vector/vstate_exec_nolibc`、`v_exec_initval_nolibc` | **SKIP** | 同上，缺 `v` |
| `vector/vstate_prctl`、`validate_v_ptrace`、`cfi/*` | 未编出 | 需 GCC 13+（RVV intrinsics）/ 支持 CFI 的工具链 |

**这张表本身就是 SOW 要的"硬件差异"证据**：

1. **测试适用性取决于平台扩展**。同一套 kselftest，在 QEMU（有 V+ZPM）上跑出 9P/0S/1X；
   在 P550（无 V、无 ZPM）上 4 个用例**根本不该跑**（跑了必然 SIGILL 或 Bail out）。
   所以流水线按"平台扩展"决定 SKIP，而不是把它记成失败 —— 否则真机回归信号会被无关失败淹没。
2. **`pointer_masking` 在两平台上的结局相反**：QEMU 有 ZPM 但触发上游 bug → **XFAIL**；
   P550 没有 ZPM → **SKIP**。同一个测试、两种平台含义完全不同。
3. **`hwprobe` 在真机通过**，说明 P550 的 `riscv_hwprobe(2)` 行为符合上游约定 ——
   这也为 `docs/extension-matrix.md` 里的扩展结论提供了权威来源（而不只是 `/proc/cpuinfo`）。

复现：

```bash
KERNEL_TREE=/path/to/linux bash scripts/build-kselftest.sh   # 本机交叉编译（板上无 gcc）
KERNEL_TREE=/path/to/linux bash scripts/run-board-tests.sh   # 自动同步 + 板上运行 + 归档
```

## 9. 复现方式

```bash
bash scripts/run-board-tests.sh          # 一条命令：同步→采集→归档→verdict→趋势表
cat results/trend.md                     # 回归趋势（含 h/v/zpm 列）
```
