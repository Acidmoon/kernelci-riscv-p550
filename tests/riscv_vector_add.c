/* riscv_vector_add.c — RISC-V 真机向量(RVV)功能测试（板卡无关，P550 / li3a 通用）
 *
 * 做什么: 读 VLEN(向量长度) -> 用向量指令做加法 -> 逐项校验结果
 * 编译:   gcc -O2 -static -march=rv64gcv -mabi=lp64d riscv_vector_add.c -o riscv_vector_add
 *
 * 注意: 需要 GCC 13+ 才支持 RVV intrinsics；GCC 12 会编译失败（见 p550-vector.sh 的 FAIL 分支）。
 *       VLEN 是"真机暴露面"里最有价值的一项（li3a 实测 256-bit）。
 */
#include <stdio.h>
#include <stdint.h>
#include <riscv_vector.h>
#define N 32

int main(void) {
    int32_t a[N], b[N], c[N];
    unsigned long vlenb = 0;

    /* 填数据: a = 0..31, b = 1000+7i */
    for (int i = 0; i < N; i++) { a[i] = i; b[i] = 1000 + i * 7; }

    /* 读 vlenb CSR 得到 VLEN(字节)，这就是真机向量位宽的来源 */
    __asm__ volatile("csrr %0, vlenb" : "=r"(vlenb));
    printf("VLEN = %lu bits\n", vlenb * 8);

    /* 向量加法: 每次取 vl 个元素(硬件能装多少装多少)，分块做完 */
    for (int i = 0; i < N; ) {
        size_t vl = __riscv_vsetvl_e32m1((size_t)(N - i));
        vint32m1_t va = __riscv_vle32_v_i32m1(&a[i], vl);
        vint32m1_t vb = __riscv_vle32_v_i32m1(&b[i], vl);
        vint32m1_t vc = __riscv_vadd_vv_i32m1(va, vb, vl);
        __riscv_vse32_v_i32m1(&c[i], vc, vl);
        i += (int)vl;
    }

    /* 逐项对答案: c 应该等于 a+b */
    int ok = 1;
    for (int i = 0; i < N; i++)
        if (c[i] != a[i] + b[i]) { ok = 0; printf("MISMATCH at %d\n", i); }
    printf("vector_add: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
