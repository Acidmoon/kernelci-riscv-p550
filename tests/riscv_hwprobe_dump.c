/* riscv_hwprobe_dump.c — riscv_hwprobe(2) 权威探针（真机）
 *
 * 为什么需要它
 *   扩展矩阵此前以 /proc/cpuinfo 的 `isa` 字段为依据，但那只是**内核汇总的字符串**。
 *   `riscv_hwprobe(2)` 才是内核提供给用户态的**权威、结构化**能力接口：
 *   - 它是机器可读的键值对，不受 ISA 字符串拼写差异影响
 *   - 它能给出 ISA 字符串给不出的信息（Zicboz 块大小、最高虚拟地址、非对齐访问性能档位）
 *   - KernelCI/glibc/编译器都靠它做运行时能力判断
 *
 * ⚠️ 重要边界（实测确认）
 *   hwprobe **不覆盖** H（Hypervisor）等特权扩展，也不覆盖 Zicsr/Zifencei 这类"隐含"扩展。
 *   所以 H 的结论仍然只能来自设备树/cpuinfo。二者是互补关系，不是替代关系。
 *
 * 做法
 *   一次性查询 kernel 定义的全部 key（0..16），打印原始值并按 uapi 定义解码。
 *   未知/不支持的 key 内核会返回 -1（这也是"该内核对这个 key 无定义"的信号）。
 *
 * 编译: riscv64-linux-gnu-gcc -static -O2 riscv_hwprobe_dump.c -o riscv_hwprobe_dump
 * 机器可读: HWPROBE_<NAME>=present|absent|<value> / HWPROBE_STATUS=PASS|SKIP
 */
#define _GNU_SOURCE
#include <errno.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

/* ---- 键值定义照抄 arch/riscv/include/uapi/asm/hwprobe.h（Linux v7.2-rc7 内核树） ---- */
#define RISCV_HWPROBE_KEY_MVENDORID 0
#define RISCV_HWPROBE_KEY_MARCHID 1
#define RISCV_HWPROBE_KEY_MIMPID 2
#define RISCV_HWPROBE_KEY_BASE_BEHAVIOR 3
#define RISCV_HWPROBE_BASE_BEHAVIOR_IMA (1ULL << 0)
#define RISCV_HWPROBE_KEY_IMA_EXT_0 4
#define RISCV_HWPROBE_KEY_CPUPERF_0 5
#define RISCV_HWPROBE_KEY_ZICBOZ_BLOCK_SIZE 6
#define RISCV_HWPROBE_KEY_HIGHEST_VIRT_ADDRESS 7
#define RISCV_HWPROBE_KEY_TIME_CSR_FREQ 8
#define RISCV_HWPROBE_KEY_MISALIGNED_SCALAR_PERF 9
#define RISCV_HWPROBE_KEY_MISALIGNED_VECTOR_PERF 10
#define RISCV_HWPROBE_KEY_ZICBOM_BLOCK_SIZE 12
#define RISCV_HWPROBE_KEY_IMA_EXT_1 16

struct riscv_hwprobe {
    int64_t key;
    uint64_t value;
};

#ifndef SYS_riscv_hwprobe
#define SYS_riscv_hwprobe 258
#endif

/* IMA_EXT_0 里我们要重点对照的位（与 /proc/cpuinfo 的 isa 交叉验证） */
static const struct {
    uint64_t bit;
    const char *name;   /* 与 riscv-ext-scan.sh 的扩展名对齐，便于比对 */
    const char *label;
} ima_ext_0[] = {
    {1ULL << 0, "fd", "FD（单/双精度浮点）"},
    {1ULL << 1, "c", "C（压缩指令）"},
    {1ULL << 2, "v", "V（向量）"},
    {1ULL << 3, "zba", "Zba"},
    {1ULL << 4, "zbb", "Zbb"},
    {1ULL << 5, "zbs", "Zbs"},
    {1ULL << 6, "zicboz", "Zicboz"},
    {1ULL << 7, "zbc", "Zbc"},
    {1ULL << 8, "zbkb", "Zbkb"},
    {1ULL << 9, "zbkc", "Zbkc"},
    {1ULL << 10, "zbkx", "Zbkx"},
    {1ULL << 27, "zfh", "Zfh"},
    {1ULL << 29, "zihintntl", "Zihintntl"},
    {1ULL << 33, "ztso", "Ztso"},
    {1ULL << 34, "zacas", "Zacas"},
    {1ULL << 35, "zicond", "Zicond"},
    {1ULL << 36, "zihintpause", "Zihintpause"},
    {1ULL << 55, "zicbom", "Zicbom"},
    {1ULL << 60, "zicbop", "Zicbop"},
};

static const char *misaligned_name(uint64_t v) {
    switch (v & 0x7) {
    case 0: return "unknown";
    case 1: return "emulated";
    case 2: return "slow";
    case 3: return "fast";
    case 4: return "unsupported";
    default: return "?";
    }
}

int main(void) {
    enum { NKEYS = 17 };
    struct riscv_hwprobe pairs[NKEYS];
    uint64_t v[NKEYS];
    cpu_set_t set;
    int i;

    /* 让内核在所有 CPU 上取一致值：只指定 CPU0（板上 4 核同构，见 docs/extension-matrix.md） */
    CPU_ZERO(&set);
    CPU_SET(0, &set);

    for (i = 0; i < NKEYS; i++) {
        pairs[i].key = i;
        pairs[i].value = 0;
    }

    long rc = syscall(SYS_riscv_hwprobe, pairs, (size_t)NKEYS, sizeof(set), &set, 0);
    if (rc != 0) {
        if (errno == ENOSYS) {
            printf("riscv_hwprobe(2) 不存在（内核太老）\n");
            printf("HWPROBE_STATUS=SKIP\n");
            return 0;
        }
        fprintf(stderr, "riscv_hwprobe 失败: %s\n", strerror(errno));
        printf("HWPROBE_STATUS=FAIL\n");
        return 1;
    }

    for (i = 0; i < NKEYS; i++)
        v[i] = pairs[i].value;

    printf("== riscv_hwprobe(2) 权威能力探针 ==\n");
    printf("  MVENDORID : %#llx\n", (unsigned long long)v[RISCV_HWPROBE_KEY_MVENDORID]);
    printf("  MARCHID   : %#llx\n", (unsigned long long)v[RISCV_HWPROBE_KEY_MARCHID]);
    printf("  MIMPID    : %#llx\n", (unsigned long long)v[RISCV_HWPROBE_KEY_MIMPID]);
    printf("  BASE_BEHAVIOR: %#llx%s\n", (unsigned long long)v[RISCV_HWPROBE_KEY_BASE_BEHAVIOR],
           (v[RISCV_HWPROBE_KEY_BASE_BEHAVIOR] & RISCV_HWPROBE_BASE_BEHAVIOR_IMA) ? "（IMA 基线 ✓）" : "");
    printf("  IMA_EXT_0 : %#llx\n", (unsigned long long)v[RISCV_HWPROBE_KEY_IMA_EXT_0]);
    printf("  CPUPERF_0 : 非对齐访问=%s\n", misaligned_name(v[RISCV_HWPROBE_KEY_CPUPERF_0]));

    printf("\n  --- 原始键值表（key: value）---\n"
           "  注意: 上游约定「未定义的 key 返回 -1」，但本板 6.6.92 厂商内核对未定义 key 返回 0，\n"
           "        因此不能靠 -1 判断某个 key 是否被该内核支持（这也是与上游的一处行为差异）。\n");
    for (i = 0; i < NKEYS; i++) {
        if (v[i] == UINT64_MAX)
            printf("  key %-2d : -1（未定义）\n", i);
        else
            printf("  key %-2d : %#llx\n", i, (unsigned long long)v[i]);
    }

    printf("\n  --- 补充信息 ---\n");
    printf("  Zicboz 块大小   : %llu\n", (unsigned long long)v[RISCV_HWPROBE_KEY_ZICBOZ_BLOCK_SIZE]);
    printf("  Zicbom 块大小   : %llu\n", (unsigned long long)v[RISCV_HWPROBE_KEY_ZICBOM_BLOCK_SIZE]);
    printf("  最高虚拟地址    : %#llx\n", (unsigned long long)v[RISCV_HWPROBE_KEY_HIGHEST_VIRT_ADDRESS]);
    printf("  TIME CSR 频率   : %llu\n", (unsigned long long)v[RISCV_HWPROBE_KEY_TIME_CSR_FREQ]);
    printf("  非对齐标量性能  : %s\n", misaligned_name(v[RISCV_HWPROBE_KEY_MISALIGNED_SCALAR_PERF] & 0x7));
    printf("  非对齐向量性能  : %s\n", misaligned_name(v[RISCV_HWPROBE_KEY_MISALIGNED_VECTOR_PERF] & 0x7));
    printf("  IMA_EXT_1       : %#llx\n", (unsigned long long)v[RISCV_HWPROBE_KEY_IMA_EXT_1]);

    printf("\n  --- IMA_EXT_0 解码（用户态可见扩展）---\n");
    uint64_t ext0 = v[RISCV_HWPROBE_KEY_IMA_EXT_0];
    for (size_t k = 0; k < sizeof(ima_ext_0) / sizeof(ima_ext_0[0]); k++) {
        int present = (ext0 & ima_ext_0[k].bit) != 0;
        printf("  %-12s %s  %s\n", ima_ext_0[k].name, present ? "present" : "absent", ima_ext_0[k].label);
        printf("HWPROBE_EXT_%s=%s\n", ima_ext_0[k].name, present ? "present" : "absent");
    }

    printf("\nHWPROBE_STATUS=PASS\n");
    return 0;
}
