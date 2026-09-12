/* riscv_vector_bench.c — 向量性能基准（真机 vs QEMU 对照，板卡无关）
 *
 * 编译: gcc -O2 -static -march=rv64gcv -mabi=lp64d riscv_vector_bench.c -o riscv_vector_bench
 *
 * 用途: 同一份源码在 P550 / li3a / QEMU 上跑出耗时，构成"跨平台性能差异"证据。
 *       li3a 参考值: 419 万元素加法 36.058 ms（VLEN=256）；QEMU -cpu max: 380.263 ms（VLEN=128）。
 *       需要 GCC 13+（RVV intrinsics）。
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include <riscv_vector.h>
#define N (1U << 22)          /* 419 万元素 */

int main(void) {
    int32_t *a = malloc(N * 4), *b = malloc(N * 4), *c = malloc(N * 4);
    if (!a || !b || !c) { printf("内存分配失败\n"); return 1; }
    for (uint32_t i = 0; i < N; i++) {
        a[i] = (int32_t)i;
        b[i] = 1000 + 7 * (int32_t)i;
    }

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (uint32_t i = 0; i < N; ) {
        size_t vl = __riscv_vsetvl_e32m1((size_t)(N - i));
        vint32m1_t va = __riscv_vle32_v_i32m1(&a[i], vl);
        vint32m1_t vb = __riscv_vle32_v_i32m1(&b[i], vl);
        vint32m1_t vc = __riscv_vadd_vv_i32m1(va, vb, vl);
        __riscv_vse32_v_i32m1(&c[i], vc, vl);     /* 写回结果 */
        i += (uint32_t)vl;
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double ms = (t1.tv_sec - t0.tv_sec) * 1000.0 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
    printf("vector bench: %u 元素加法耗时 %.3f ms\n", N, ms);

    int ok = 1;
    for (uint32_t i = 0; i < N; i++)
        if (c[i] != a[i] + b[i]) { ok = 0; break; }
    printf("结果校验: %s\n", ok ? "PASS" : "FAIL");
    free(a); free(b); free(c);
    return ok ? 0 : 1;
}
