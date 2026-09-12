# `profile/` — RISC-V 扩展测试 profile（SOW Phase 3 说的 "test profile suite"）

这个目录是 **Phase 3 交付物的实体**：把"我们在测什么、在什么平台上期望什么结果"从文档变成
**机器可读、可执行断言**的定义。

> 关键判断：SOW 的 Phase 3 要的是 *"integrate the RISC-V **test profile suite**"*，
> 不是"我们的 lab 以什么形态接入 KernelCI"。所以真正需要交付的是**profile 本身**——
> 它既可以本地跑（QEMU/真机），也可以作为将来提 PR 的内容。
> 理由与上游现状见 [`integration/kernelci/README.md`](../integration/kernelci/README.md)。

## 内容

| 文件 | 作用 |
|---|---|
| `riscv-extensions.json` | profile 定义：suite 清单 + 每个目标的期望值（扩展存在性、各测试项状态、kselftest 计数下限） |
| `../scripts/check-profile.py` | 执行器：profile 自检 + 把期望值与真实结果逐项比对 |

**为什么用 JSON 而不是 YAML**：零依赖，CI（ubuntu-latest 的默认 python）里直接能跑，
不需要 `pip install pyyaml`。要转 YAML 很容易，将来按上游偏好再转。

## profile 里声明了什么

### suites（8 个）

| suite | `results_key` | kind | 前置扩展 | 作用 |
|---|---|---|---|---|
| board-info | `board_info` | info | — | 板卡/系统身份快照 |
| riscv-cpuinfo | `cpuinfo` | capability | — | **必需扩展检查**（缺 → FAIL）：配置漂移检测 |
| riscv-ext-scan | `ext_scan` | capability | — | 扩展矩阵扫描（差异即结论，不判失败） |
| riscv-hwprobe | `hwprobe` | capability | — | **hwprobe × isa 交叉验证**（不一致即漂移） |
| riscv-vector | `vector` | extension | **v** | 向量功能/性能；无 v → SKIP |
| bootchain | `bootchain` | info | — | 启动链/固件证据（模拟器产生不了） |
| riscv-hypervisor | `hypervisor` | extension | **h** | 真机 KVM 冒烟；无 h 或无 `/dev/kvm` → SKIP |
| riscv-kselftest | `kselftest` | regression | — | 同源码多平台对照；逐用例的 `case_requires` 决定 SKIP |

`case_requires` 是这份 profile 的一个关键设计：**测试适用性取决于平台扩展**
（`pointer_masking` 需 `zpm`，`sigreturn`/`vector/*` 需 `v`），缺扩展的用例记 SKIP 而不是 FAIL——
否则真机回归信号会被"平台本来就没这个扩展"的失败淹没。

### targets（4 个）

| target | 类型 | 期望扩展 | 备注 |
|---|---|---|---|
| `p550` | hardware | h=✔ v=✘ zpm=✘ | 唯一有 H 的真机（实测 2026-09-12） |
| `li3a` | hardware | h=✘ v=✔ zpm=✘ | 唯一有 V 的真机（VLEN=256） |
| `qemu` | emulator | h=✔ v=✔ zpm=✔ | SOW Phase 2 点名的目标；kselftest 9P/0S/1X |
| `spike` | emulator | 待定 | SOW 点名的另一半 —— **尚未接入**（需 sudo 装 autoconf/dtc） |

## 用法

```bash
# profile 自身一致性（CI 每次 push 都跑）
python3 scripts/check-profile.py --selfcheck

# 把某次真机/模拟器运行与期望值比对（不一致 = 配置漂移）
python3 scripts/check-profile.py --latest
python3 scripts/check-profile.py --archive results/history/20260912-170013 --target p550
python3 scripts/check-profile.py --latest --quiet    # 只打印漂移项
```

输出机器可读行：`PROFILE_STATUS=PASS|FAIL`、`PROFILE_MISMATCH=<n>`。

## 在流水线里的位置

`scripts/run-board-tests.sh` 的 **步骤 [5]**：真机跑完 → 与 profile 比对 → 结果回写进
`results.json` 的 `tests.profile` → 趋势表新增 `profile` 列（长期跟踪漂移）。

实测效果（最新一次真机运行）：

```
profile 一致性: PASS（17 项一致 / 0 项不一致, target=p550）
```

而假板自检里有**反向用例**：合成数据故意让 `h=absent` 与 p550 的期望不符 → 趋势表出现
`FAIL(!3)`，证明漂移**真的会被抓住**，而不是永远打印 PASS。

## 漂移检测能抓什么（真实场景）

| 场景 | 会被哪一项抓到 |
|---|---|
| 板子换了内核，H 扩展消失 | `ext.h` / `isa_regex` |
| 内核配置声称支持某扩展但硬件没有 | `riscv-hwprobe` 的交叉验证不一致数 |
| 厂商内核不同版本改了 KVM ISA 语义 | `hwprobe.mismatch` + `hypervisor` 状态 |
| kselftest 因平台缺扩展而"失败" | `case_requires` → 记 SKIP（避免假警报） |
| 真机 kselftest 通过数下降 | `kselftest_min.pass` 下限 |

## 待办

- [ ] 接入 **Spike**（需先 `sudo apt install autoconf device-tree-compiler flex bison`）
- [ ] 把 li3a / QEMU 侧结果也纳入同一 profile 比对（目前只有 p550 有完整的 `results.json` 归档）
- [ ] 若上游偏好 YAML/注册到 `kernelci/kcidb` 的 `tests.yaml`，再做格式转换
