# P550 启动链记录 2026-09-12

平台：SiFive HiFive Premier P550 / ESWIN EIC7700 / 4×SiFive P550 / 9.6 GiB / 4 核
系统：Ubuntu 24.04.3 LTS，内核 `6.6.92-2025-eic7700`（ESWIN 厂商内核）
采集：`bash scripts/run-board-tests.sh` → `results/history/20260912-155345/bootchain.log`（只读）

## 启动链路（U-Boot → GRUB → EFI stub → 内核）

真实固件链的物证：

| 物证 | 位置 | 含义 |
|---|---|---|
| U-Boot 启动脚本 | `/boot/boot.scr` | SoC 的 U-Boot 会读它来继续引导 |
| GRUB | `/boot/grub/` | 二级引导器（Ubuntu 安装器写入） |
| EFI stub | `/boot/efi`、`/sys/firmware/efi` | 内核以 EFI stub 方式被 GRUB 启动 |
| 设备树 | `/boot/dtb`、`/boot/dtb-6.6.92-2025-eic7700`、`/sys/firmware/fdt` | 固件传入的 DTB |
| 内核与 initrd | `/boot/vmlinuz-6.6.92-2025-eic7700`、`initrd.img-…` | |

```
/sys/firmware 内容: devicetree efi fdt
EFI 变量表: yes     fw_platform_size: 64     efivars 条目: 0
```

> 与 Ubuntu/RISC-V 侧已知情况一致：**U-Boot 不允许操作系统写 UEFI 变量**，因此 efivars 条目为 0、
> 内核命令行带 `efi=noruntime`。这是"真机固件行为"，QEMU 的 `-kernel` 直启完全不会产生这些痕迹。

## 内核命令行（固件传给内核的真实参数）

```
BOOT_IMAGE=/boot/vmlinuz-6.6.92-2025-eic7700
root=UUID=9e29d36a-a99b-46d7-9388-c76cf6f49be6 ro
efi=noruntime
earlycon=sbi earlycon=sbi
console=ttyS0,115200n8
clk_ignore_unused
cma_pernuma=0x2000000
disable_bypass=false
firmware_class.path=/lib/firmware/eic7x/
```

要点：
- `earlycon=sbi`（**重复出现两次**）→ 早期控制台经 OpenSBI，真实固件链证据；重复参数本身是个可记录的小瑕疵
- `efi=noruntime` + `efivars=0` → U-Boot 不支持运行时 UEFI 服务
- `console=ttyS0,115200n8` → 串口控制台（本仓库的 `scripts/p550-serial.sh` 走 `/dev/ttyUSB2`）
- `cma_pernuma=0x2000000`（32 MiB）、`disable_bypass=false`、`firmware_class.path=/lib/firmware/eic7x/` → ESWIN 厂商特有参数

## 设备树身份

```
model:      SiFive HiFive Premier P550
compatible: eswin,eic7x
```

## 存储与根文件系统

```
/dev/mmcblk0p3 ext4 rw,relatime          ← 根文件系统在 eMMC
mmcblk0  116.5G disk                     ← eMMC 总容量
```

## CPU 身份（真机签名）

```
isa        : rv64imafdch_zicntr_zicsr_zifencei_zihpm_zba_zbb_sscofpmf
mmu        : sv48
mvendorid  : 0x489
marchid    : 0x8000000000000008
mimpid     : 0x6220425
```

要点：
- **`h` 存在**（`rv64imafdch`）→ 真机 Hypervisor/KVM 测试路径（li3a 无 H，路径不可行）
- **无 `v`** → 向量测试按设计记 `SKIP`
- **`sv48`**（li3a 为 sv39）→ 地址空间能力不同，属"微架构行为差异"证据
- `mvendorid=0x489`（SiFive）与 li3a 的 `0x710`（SpacemiT）—— 模拟器不会出现的真机标识

## 价值说明

这是"真实启动链"（固件 → 引导器 → 设备树 → 内核参数 → CPU 身份 → 存储布局）的完整快照，
用来填 `docs/extension-matrix.md` 的"启动链"一栏，并作为 SOW 里
"以同一套标准在真实硬件上验证"的可复现证据。
