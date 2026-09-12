/* riscv_kvm_smoke.c — RISC-V 真机 Hypervisor(KVM) 功能冒烟测试
 *
 * 为什么需要它
 *   SOW 点名的两个扩展轴是 Vector 与 Hypervisor。Vector 有 Lichee Pi 3A（VLEN=256）；
 *   而 H 扩展只有这块 P550 有 —— 这是唯一能做真机 Hypervisor 测试的平台。
 *   板子上没有 gcc，所以本程序在**本机交叉编译成静态二进制**再拷到板上运行。
 *
 * 做什么（不依赖 qemu、不依赖客户机镜像）
 *   1. 打开 /dev/kvm，校验 KVM_GET_API_VERSION
 *   2. KVM_CREATE_VM → KVM_CREATE_VCPU
 *   3. 注册一段 4 KiB guest 内存（GPA 0x8000_0000），写入 3 条 RV64 指令：
 *        lui  t0, 0x10000     ; t0 = 0x1000_0000（未映射的 GPA）
 *        lw   t1, 0(t0)       ; 访存未映射地址 → 期望 KVM_EXIT_MMIO
 *        jal  x0, 0           ; 兜底死循环
 *   4. KVM_SET_ONE_REG 设置 guest PC = 0x8000_0000（顺带尝试 mode = S）
 *   5. KVM_RUN，检查退出原因确实是 KVM_EXIT_MMIO 且 phys_addr == 0x1000_0000
 *   6. 顺带用 KVM_GET_ONE_REG 读 guest 可见的 ISA 位图（KVM_RISCV_ISA_EXT_*）
 *      注意：本板厂商内核（6.6.92-2025-eic7700）读出的位图与上游枚举对不上
 *      （实测 0x112d，按上游 v6.6 枚举解为 A/D/F/I/Sstc/Zicboz，但硬件有 zba/zbb、
 *        没有 zicboz）→ 因此**只打印原始值**，不做结论性解码。
 *
 * 退出码
 *   0 = PASS（客户机真的在 H 扩展上执行了，并产生了预期的 MMIO 退出）
 *   1 = FAIL（KVM 报错或退出原因不符）
 *   2 = SKIP（没有 /dev/kvm：kvm 模块未加载）
 *   3 = SKIP（打开 /dev/kvm 权限不足 —— 该设备默认 crw------- root root）
 *
 * 编译: riscv64-linux-gnu-gcc -static -O2 riscv_kvm_smoke.c -o riscv_kvm_smoke
 * 运行: sudo ./riscv_kvm_smoke      （/dev/kvm 默认仅 root 可访问）
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

/* ---- RISC-V KVM one-reg 编码（照抄 arch/riscv/include/uapi/asm/kvm.h, Linux v6.6） ----
 * 用 P550_ 前缀避免与交叉工具链自带的 asm/kvm.h 冲突（那些头文件在部分版本里
 * 已经定义了 KVM_REG_RISCV_CORE / KVM_REG_RISCV_CONFIG / KVM_RISCV_MODE_S）。 */
#ifndef KVM_REG_RISCV_TYPE_SHIFT
#define KVM_REG_RISCV_TYPE_SHIFT 24
#endif
#ifndef KVM_REG_RISCV_CONFIG
#define KVM_REG_RISCV_CONFIG (0x01UL << KVM_REG_RISCV_TYPE_SHIFT)
#endif
#ifndef KVM_REG_RISCV_CORE
#define KVM_REG_RISCV_CORE (0x02UL << KVM_REG_RISCV_TYPE_SHIFT)
#endif
#ifndef KVM_RISCV_MODE_S
#define KVM_RISCV_MODE_S 1UL
#endif

/* struct kvm_riscv_core { struct user_regs_struct regs; unsigned long mode; } */
struct p550_user_regs {
    uint64_t pc, ra, sp, gp, tp;
    uint64_t t0, t1, t2, t3, t4, t5, t6;
    uint64_t s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11;
    uint64_t a0, a1, a2, a3, a4, a5, a6, a7;
};
struct p550_kvm_core {
    struct p550_user_regs regs;
    uint64_t mode;
};

#define P550_CORE_REGID(field)                                                   \
    (KVM_REG_RISCV | KVM_REG_SIZE_U64 | KVM_REG_RISCV_CORE |                     \
     (offsetof(struct p550_kvm_core, field) / sizeof(unsigned long)))
#define P550_CONFIG_REGID(off)                                                   \
    (KVM_REG_RISCV | KVM_REG_SIZE_U64 | KVM_REG_RISCV_CONFIG | ((off) / sizeof(unsigned long)))

/* guest 代码：GPA 0x8000_0000；访存 0x1000_0000（未映射）应触发 KVM_EXIT_MMIO */
#define GUEST_GPA 0x80000000UL
#define GUEST_MMIO_ADDR 0x10000000UL
#define GUEST_CODE_SIZE 12
static const uint32_t guest_code[] = {
    0x100002b7, /* lui  t0, 0x10000  */
    0x0002a303, /* lw   t1, 0(t0)    */
    0x0000006f, /* jal  x0, 0        */
};

static int fail(const char *what) {
    fprintf(stderr, "  FAIL: %s: %s\n", what, strerror(errno));
    return 1;
}

int main(void) {
    int kvmfd, vmfd, vcpufd, rc = 1, ret;
    void *mem, *run;
    struct kvm_run *runp;
    struct kvm_userspace_memory_region region;
    struct kvm_one_reg oreg;
    uint64_t val;
    int mmap_size;

    printf("== RISC-V KVM 冒烟测试 ==\n");

    kvmfd = open("/dev/kvm", O_RDWR | O_CLOEXEC);
    if (kvmfd < 0) {
        if (errno == ENOENT) {
            printf("  SKIP: /dev/kvm 不存在（kvm 模块未加载；需要 sudo modprobe kvm）\n");
            return 2;
        }
        if (errno == EACCES || errno == EPERM) {
            printf("  SKIP: /dev/kvm 权限不足（默认 crw------- root root，请用 sudo 运行）\n");
            return 3;
        }
        return fail("open /dev/kvm");
    }

    ret = ioctl(kvmfd, KVM_GET_API_VERSION, 0);
    printf("  KVM API version: %d（期望 %d）\n", ret, KVM_API_VERSION);
    if (ret != KVM_API_VERSION) return fail("KVM_GET_API_VERSION");

    vmfd = ioctl(kvmfd, KVM_CREATE_VM, 0);
    if (vmfd < 0) return fail("KVM_CREATE_VM");
    printf("  KVM_CREATE_VM: ok (fd=%d)\n", vmfd);

    vcpufd = ioctl(vmfd, KVM_CREATE_VCPU, 0);
    if (vcpufd < 0) return fail("KVM_CREATE_VCPU");
    printf("  KVM_CREATE_VCPU: ok (fd=%d)\n", vcpufd);

    /* guest 内存（G-stage 会把 GPA 0x8000_0000 映射到这块匿名内存） */
    mem = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem == MAP_FAILED) return fail("mmap guest mem");
    memcpy(mem, guest_code, GUEST_CODE_SIZE);

    memset(&region, 0, sizeof(region));
    region.slot = 0;
    region.guest_phys_addr = GUEST_GPA;
    region.memory_size = 0x1000;
    region.userspace_addr = (uint64_t)(uintptr_t)mem;
    if (ioctl(vmfd, KVM_SET_USER_MEMORY_REGION, &region) < 0)
        return fail("KVM_SET_USER_MEMORY_REGION");
    printf("  guest 内存: GPA %#lx -> host %p (4 KiB)\n", (unsigned long)GUEST_GPA, mem);

    mmap_size = ioctl(kvmfd, KVM_GET_VCPU_MMAP_SIZE, 0);
    if (mmap_size <= 0) return fail("KVM_GET_VCPU_MMAP_SIZE");
    run = mmap(NULL, (size_t)mmap_size, PROT_READ | PROT_WRITE, MAP_SHARED, vcpufd, 0);
    if (run == MAP_FAILED) return fail("mmap kvm_run");
    runp = (struct kvm_run *)run;

    /* guest PC = 0x8000_0000；mode 尝试设为 S（默认值可能已经是 S，失败不算致命） */
    val = GUEST_GPA;
    oreg.id = P550_CORE_REGID(regs.pc);
    oreg.addr = (uint64_t)(uintptr_t)&val;
    if (ioctl(vcpufd, KVM_SET_ONE_REG, &oreg) < 0) return fail("KVM_SET_ONE_REG pc");

    val = KVM_RISCV_MODE_S;
    oreg.id = P550_CORE_REGID(mode);
    oreg.addr = (uint64_t)(uintptr_t)&val;
    if (ioctl(vcpufd, KVM_SET_ONE_REG, &oreg) < 0)
        printf("  note: 设置 mode=S 失败（可能默认已是 S，继续）: %s\n", strerror(errno));
    else
        printf("  guest mode = S, PC = %#lx\n", (unsigned long)GUEST_GPA);

    /* guest 可见的 ISA 位图（只报原始值）
     * 不做名字解码：本板厂商内核实测 0x112d，按上游 v6.6 枚举会解成 A/D/F/I/Sstc/Zicboz，
     * 但硬件有 zba/zbb、没有 zicboz —— 说明该内核的枚举或位图语义与上游不一致，
     * 解码会给出误导性结论。留作待查项，详见 docs/extension-matrix.md。 */
    memset(&val, 0, sizeof(val));
    oreg.id = P550_CONFIG_REGID(0 /* struct kvm_riscv_config.isa 是第一个字段 */);
    oreg.addr = (uint64_t)(uintptr_t)&val;
    if (ioctl(vcpufd, KVM_GET_ONE_REG, &oreg) == 0)
        printf("  guest ISA 位图(原始值): %#llx（厂商内核语义待确认，不做名字解码）\n",
               (unsigned long long)val);

    /* 用 config 里的身份字段自检偏移假设: 若与 /proc/cpuinfo 的 mvendorid 等一致，
     * 说明我们的 struct/offset 假设正确 → 上面读到的 0 号字段确实是 `isa`。
     * 这是"不做名字解码"但也不乱猜的关键验证。 */
    {
        static const struct { int reg; const char *name; } idregs[] = {
            {2, "mvendorid"}, {3, "marchid"}, {4, "mimpid"},
        };
        for (size_t k = 0; k < sizeof(idregs) / sizeof(idregs[0]); k++) {
            uint64_t idv = 0;
            oreg.id = P550_CONFIG_REGID(idregs[k].reg * sizeof(unsigned long));
            oreg.addr = (uint64_t)(uintptr_t)&idv;
            if (ioctl(vcpufd, KVM_GET_ONE_REG, &oreg) == 0)
                printf("  guest %-9s : %#llx\n", idregs[k].name, (unsigned long long)idv);
        }
        printf("  （与板上 /proc/cpuinfo 的 mvendorid/marchid/mimpid 对照可验证偏移假设）\n");
    }

    printf("  KVM_RUN ...\n");
    if (ioctl(vcpufd, KVM_RUN, 0) < 0) return fail("KVM_RUN");

    printf("  exit_reason = %u", runp->exit_reason);
    if (runp->exit_reason == KVM_EXIT_MMIO) {
        printf(" (KVM_EXIT_MMIO)  phys_addr=%#llx len=%u is_write=%u\n",
               (unsigned long long)runp->mmio.phys_addr, runp->mmio.len, runp->mmio.is_write);
        if (runp->mmio.phys_addr == GUEST_MMIO_ADDR) {
            printf("\nhypervisor: PASS（客户机在真机 H 扩展上执行并产生预期 MMIO 退出）\n");
            rc = 0;
        } else {
            printf("  期望 phys_addr=%#lx\n", (unsigned long)GUEST_MMIO_ADDR);
            printf("\nhypervisor: FAIL（MMIO 地址不符）\n");
        }
    } else if (runp->exit_reason == KVM_EXIT_SHUTDOWN || runp->exit_reason == KVM_EXIT_SYSTEM_EVENT) {
        printf(" —— 客户机被关机/系统事件（guest 未跑到 MMIO）\n");
        printf("\nhypervisor: FAIL（guest 异常退出）\n");
    } else {
        printf(" —— 非预期退出原因\n");
        printf("\nhypervisor: FAIL（退出原因非 MMIO）\n");
    }

    munmap(run, (size_t)mmap_size);
    munmap(mem, 0x1000);
    close(vcpufd);
    close(vmfd);
    close(kvmfd);
    return rc;
}
