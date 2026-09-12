# 上游可行动发现（真机跑出来的）

> 本文汇总**只有在真机上跑才会暴露**的问题与行为差异，供后续与 KernelCI/上游社区沟通使用。
> 按约定：**目前只准备材料，不发 PR、不发邮件**。每条都标了"证据强度"和"我们不确定的地方"。
>
> 采集环境：SiFive HiFive Premier P550（ESWIN EIC7700 / 4×P550），Ubuntu 24.04.3 LTS，
> 厂商内核 `6.6.92-2025-eic7700`；kselftest 源码来自本机内核树 v7.2-rc7。
> 原始输出：`results/history/20260912-163259/`（CI 跑的那次）与 `results/history/20260912-170013/`。

---

## 发现 1（最硬）：`riscv/sigreturn` 没有 V 能力门控 → 无 V 平台上 SIGILL 而非 SKIP

**现象**：在无 V 扩展的真机上运行该测试，直接死于信号 4：

```
not ok 1 global.vector_restore
# vector_restore: Test terminated unexpectedly by signal 4
not ok 2 global.vector_restore_signal_handler_override
```

**证据（源码级，可复核）**：`tools/testing/selftests/riscv/sigreturn/sigreturn.c`

- 第 50 行只注册了 **SIGSEGV** 处理：`sigaction(SIGSEGV, &sig_action, 0);`
- 第 52–60 行用内联汇编执行**真实的向量指令**：
  ```
  .option arch, +v
  vsetivli x0, 1, e32, m1, ta, ma
  vmv.s.x  v0, %1
  lw       a0, 0(x0)      # 故意制造 SIGSEGV
  vmv.x.s  %0, v0
  ```
- 全文**没有任何** `hwprobe` / `isa` 能力判断（`grep -nE 'hwprobe|isa'` 无命中）。

在无 V 的硬件上，**第一条向量指令 `vsetivli` 就触发 SIGILL**（非法指令），而进程只装了 SIGSEGV 处理器
→ 直接死亡 → harness 记为 FAIL。**语义上应该是 SKIP。**

**对照**：同一个目录树里已经有现成的能力检测助手——
`riscv/vector/v_helpers.c:22-26` 用 `riscv_hwprobe(RISCV_HWPROBE_KEY_IMA_EXT_0)` 检查
`RISCV_HWPROBE_EXT_ZVE32X`（即 V 可用性）。也就是说**修法在树内已有先例**，`sigreturn` 没用它。

**影响面**：任何在无 V 的 RISC-V 硬件上跑 `riscv` kselftest 的 CI 都会得到**假 FAIL**
（P550、以及 `qemu-system-riscv64 -cpu rv64,v=false` 这类配置）。这会稀释真机回归信号。

**建议修法（方向）**：在 `TEST(vector_restore)` 之前做一次能力判断（hwprobe 或解析 isa），
无 V 时 `ksft_exit_skip("V extension not available\n")`。**注意**：`kselftest.h` 约定
`KSFT_SKIP = 4`（`kselftest/kselftest.h:89`），`kselftest/runner.sh` 会识别它。

**我不确定的地方**：上游是否有意让它 FAIL（例如认为"内核应当对无 V 场景做别的事"）？
需要与 kselftest/RISC-V 维护者确认语义。

---

## 发现 2：两个 nolibc 向量测试用 `exit(-1)` 表示"平台不支持"，不是 SKIP

**证据（源码级）**：`riscv/vector/vstate_exec_nolibc.c`

```c
19:  ctrl = prctl(PR_RISCV_V_GET_CONTROL, 0, 0, 0, 0);
21:      puts("PR_RISCV_V_GET_CONTROL is not supported\n");
22:      exit(-1);            // → 退出码 255
```

**实测（P550，无 V）**：`PR_RISCV_V_GET_CONTROL is not supported`，**exit=255**。

**约定对照**：kselftest 的 SKIP 约定是退出码 **4**（`KSFT_SKIP`）。255 会被判为 FAIL。

`riscv/vector/v_exec_initval_nolibc.c`（第 29–33 行同样是 `.option arch, +v` + `vsetvli`）**完全没有能力判断**，
在无 V 平台上直接 **core dump**（实测 `timeout: the monitored command dumped core`，exit=132）。

**影响面**：与发现 1 相同——同一类"平台本来就没有这个扩展"被记成 FAIL。

**建议修法（方向）**：两个 nolibc 测试在没有 V 时以 4 退出（nolibc 下可直接 `return 4` / `_exit(4)`），
或干脆从 `TEST_GEN_PROGS_EXTENDED` 的默认运行集里按平台能力过滤。

**我不确定的地方**：nolibc 测试是否有自己的退出码约定（它们不走 harness）。
需要看 `runner.sh` 对 `TEST_GEN_PROGS_EXTENDED` 的处理再定。

---

## 发现 3：厂商内核"编译进的能力" ≠ "硬件有的能力"（方法学 + 真实实例）

**实例（P550 厂商内核 `6.6.92-2025-eic7700`）**：

| 内核配置（`/boot/config-6.6.92-2025-eic7700`） | 内核支持 | 硬件实测 | 结果 |
|---|---|---|---|
| `CONFIG_RISCV_ISA_V=y` + `V_DEFAULT_ENABLE=y` | 是 | **无 v** | 内核白编了向量支持 |
| `CONFIG_RISCV_ISA_SVPBMT=y` | 是 | **无 svpbmt** | 同上 |
| `CONFIG_RISCV_ISA_ZICBOM=y` / `ZICBOZ=y` | 是 | **无** | 同上 |
| `CONFIG_RISCV_ISA_ZBB=y` | 是 | **有 zbb** | 一致 |
| `CONFIG_RISCV_ISA_SVNAPOT=y` | 是 | isa 未列出 | 待查 |

**方法学结论**：**只读内核配置会得出错误的能力结论**，必须以运行时
`riscv_hwprobe(2)` 或 `/proc/cpuinfo` 的 `isa` 为准。这正是 SOW Phase 2 说的"自动捕捉配置漂移"，
我们也已经把这条做成了流水线里的断言（`tests/riscv-hwprobe.sh`、`scripts/check-profile.py`）。

**证据强度**：配置与运行时 isa 均为实测（`results/history/20260912-170013/{board-info,cpuinfo,hwprobe}.log`）。

---

## 发现 4：厂商内核的 KVM ISA 位图语义/枚举与上游不一致

**现象**：在 P550 上 `KVM_GET_ONE_REG` 读 `struct kvm_riscv_config.isa` 得到 **`0x112d`**。
按上游 v6.6 的 `KVM_RISCV_ISA_EXT_*` 枚举解，是 A/D/F/I/**Sstc**/**Zicboz** ——
但两路独立证据（`isa` 与 `hwprobe IMA_EXT_0=0x1b`）都表明该硬件**没有 Sstc、没有 Zicboz，但有 Zba/Zbb**。

**排除"读错偏移"的自检**：同一个配置结构里读 mvendorid/marchid/mimpid（偏移 2/3/4），得到

```
guest mvendorid : 0x489
guest marchid   : 0x8000000000000008
guest mimpid    : 0x6220425
```

与主机**完全一致** → 偏移假设成立 → 偏移 0 确实是 `isa`，`0x112d` 是权威值。
因此**是枚举顺序或位图语义不同**，不是读取错误。

**我们怎么处理**：测试程序**只报原始值、不做名字解码**（避免给出误导性结论）；
板上没有 `arch/riscv/include/uapi/asm/kvm.h`，无法本地核对枚举。

**给上游的价值**：如果有别的厂商内核也这样做，KVM 用户态工具（QEMU/libvirt）按上游枚举解读会出错。
**我不确定的地方**：这可能是 ESWIN 的私有扩展位拓展了枚举；需要该厂商内核源码才能定案。

---

## 发现 5：厂商内核对未定义的 hwprobe key 返回 0（上游约定是 -1）

**上游约定**：`riscv_hwprobe(2)` 对不认识的 key 返回 **-1**（全 1）。

**实测（P550 厂商内核）**：key 6..16（Zicboz 块大小、最高虚拟地址、TIME CSR 频率、非对齐标量/向量性能、IMA_EXT_1 …）
**一律返回 0**，而不是 -1。

**后果**：在这台机器上**不能靠 `-1` 判断某个 key 是否被该内核支持**；
用户态若据此判断"支持且值为 0"会得到错误结论（例如把 `HIGHEST_VIRT_ADDRESS=0` 当成真实值）。

**证据强度**：实测（`results/history/20260912-170013/hwprobe.log` 的原始键值表）。
**不确定**：可能是厂商内核版本较早、相关 key 尚未实现但未按约定填 -1。

---

## 附：构建注意（不是 bug，但会绊住人）

`riscv/vector/v_helpers.c` 第 4 行 `#include <asm/vendor/thead.h>` ——
交叉编译前需要先在内核树里 `make headers_install`（生成 `usr/include`），否则报
`fatal error: asm/vendor/thead.h: 没有那个文件或目录`，导致 harness 类的向量测试编不出来。
我们在 `scripts/build-kselftest.sh` 里记录了"vector 组编不出来"的现状与原因。

---

## 这份材料怎么用（等指示）

| 用途 | 说明 |
|---|---|
| 邮件列表讨论 | `kernelci@lists.linux.dev` / kselftest 与 RISC-V 维护者；发现 1、2 是纯技术修复，最容易达成共识 |
| 提 issue/PR | 发现 1、2 可以直接给 kselftest（加能力门控 + 用 4 表示 SKIP）；**目前按指示不提** |
| 喂给 KernelCI 的 test profile | 发现 3 已经是我们的 profile 断言（`riscv-hwprobe` 交叉验证） |
| 记录在案 | 发现 4、5 属于厂商内核行为差异，先记录、需要时向 ESWIN/社区求证 |

**诚实声明**：发现 4、5 只在一台厂商内核上观测到，样本为 1；发现 1、2 是源码级确认 + 真机复现，
可用 `qemu-system-riscv64 -cpu rv64,v=false` 在虚拟化目标上复跑验证（我们已验证 QEMU 接受该属性）。
