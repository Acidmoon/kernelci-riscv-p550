# Phase 3：向上游 KernelCI 集成（路线图，**尚未提 PR**）

> 本目录是 Phase 3 的工作区：把本仓库的真机测试接进 KernelCI 生态。
> 按约定，**目前只做本地工作、不提 PR**；上游动作（联系社区、申请 token、提 PR）等你确认后再做。

## 0. 先纠正一个过时的假设：不要往 `test-configs.yaml` 加东西

SOW 原文写的是"向 mainline KernelCI 父代码库提交集成 RISC-V test profile 的正式 PR"。
但上游现状已经变了（本次调研结论）：

| 路径 | 现状 | 依据 |
|---|---|---|
| `kernelci-core/config/core/test-configs.yaml` | ❌ **已 LEGACY**，文件头明确写着 *"do not send any new patches for this file"* | [test-configs.yaml](https://raw.githubusercontent.com/kernelci/kernelci-core/main/config/core/test-configs.yaml) |
| **`kernelci-pipeline` 的 Maestro 配置** | ✅ 当前官方路径：`trees.yaml` / `jobs.yaml` / `scheduler.yaml` / `config/runtime/*.jinja2` | [Developer Documentation](https://docs.kernelci.org/components/maestro/pipeline/developer-documentation/) |
| **KCIDB 提交**（自服务） | ✅ 只需 HTTPS POST + JWT，**不需要改上游任何代码** | [Submitter guide](https://docs.kernelci.org/components/kcidb/submitting/) |

**结论：Phase 3 有两条可行路线，我们两条都准备。**

---

## 1. 路线 A：KCIDB 提交（先做这条 —— 自助、无需 PR）

这是"**我们的 lab 把真机结果喂给 KernelCI**"，也是 Collabora/RISE 那类 lab 的常规做法。

### 已经做完的部分

| 产出 | 说明 |
|---|---|
| `scripts/kcidb-emit.py` | 把 `results/history/<ts>/` 翻译成 **KCIDB v5.3** 报告（checkouts/builds/tests） |
| 结构自检 | id 前缀 = origin、status 枚举、checkout↔build↔test 引用完整性等 |
| 双重复核 | ① `kci-dev submit build --from-json ... --dry-run` 接受并通过；② `kcidb-io` 官方 schema 校验（`--validate`） |
| 细粒度 | 除 8 个汇总项外，还把 `kselftest.log` 拆成**逐测试**的 KCIDB test 对象（16 个） |

试跑：

```bash
python3 scripts/kcidb-emit.py --latest --print          # 看报告
python3 scripts/kcidb-emit.py --latest --validate       # 官方 schema 校验（需 pip install kcidb-io）
python3 scripts/kcidb-emit.py --latest \
    --build-id maestro:67d409f9f378f0c5986dc7df         # hybrid：只提交 tests，挂到别人的 build 上
```

### 用官方 schema 校验抓到的 4 个违规（都已修）

这一步的价值远超预期：**我手写的结构自检全部通过、但官方 `kcidb-io` schema 连报了 4 个真实违规**。
如果不做官方校验，这些会在提交时被服务器打回：

| # | 违规 | 规则 | 修法 |
|---|---|---|---|
| 1 | origin 用了 `p550-lab` | id 前缀必须匹配 `^[a-z0-9_]+:[^\0]*$`（**不允许连字符**） | 改成 `p550_lab` |
| 2 | `checkout.git_commit_hash` 填空字符串 | 该字段若出现必须匹配 `^[0-9a-f]{40}$` | **不知道就省略**该字段（schema 里它并非 required） |
| 3 | `environment.compatible` 是字符串 | 必须是**数组**（有序的 DT compatible 列表） | 按空格拆成数组 |
| 4 | `environment.description` | `environment` 只允许 `compatible` / `comment` / `misc` | 人类可读描述放 `environment.comment` |

另外确认了 `status` 枚举是 `FAIL/ERROR/MISS/PASS/DONE/SKIP`（我们的映射没问题）。

**教训**：跨项目的数据格式对接，必须用**对方的 schema 校验器**验，而不是自己写个"看起来对"的检查。

### `kci-dev` 的一个限制（不是格式问题）

`kci-dev submit build --from-json <report>` 要求载荷里**至少有 `checkouts` 或 `builds`**，
所以 tests-only（hybrid / unlinked）会被它拒绝：

```
JSON payload must contain at least 'checkouts' or 'builds'
```

但**官方 schema 与官方文档都允许 tests-only**（文档的 hybrid 示例就是只提交 tests，
`build_id` 指向别人的 Maestro build）。所以：
- 含 checkouts/builds 的载荷 → 可以走 `kci-dev`
- tests-only 载荷 → 用官方文档里的 raw POST（`curl -X POST .../submit`）

### 真实提交前需要在 KernelCI 侧确认的三件事

1. **约定 `origin`**（如 `p550_lab`）—— 所有对象 id 都要以它开头
2. **拿 JWT token 与端点**（先 staging `https://staging.db.kernelci.org/submit`，稳定后切生产 `https://db.kernelci.org/`）
3. **日志托管**：KCIDB 只存链接，`log_url` 必须公网可访问。
   我们已经天然满足 —— 归档随仓库公开：
   `https://raw.githubusercontent.com/Acidmoon/kernelci-riscv-p550/main/results/history/<ts>/<log>`

### ⚠️ 一个必须先解决的口径问题（重要）

我们的板子跑的是**出厂预装内核**（ESWIN 厂商内核 `6.6.92-2025-eic7700`），
**没有上游 git commit**；而 KCIDB 的 checkout 需要 `git_commit_hash`。

所以：
- **不建议**用自包含模式硬凑一个假 commit（那会污染 KernelCI 的数据）
- **正确形态是 hybrid**：让 KernelCI/Maestro 构建 mainline 内核，我们的 lab 只提交**在这些内核上跑出来的测试结果**，`build_id` 指向 Maestro 的 build。
  这也正好符合 SOW 的目标（"在 mainline Linux 上持续测试"）—— 测厂商出厂内核只能算 bring-up，不算 SOW 的交付口径。
- 过渡期如果要用自包含模式，就把 `--kernel-commit` 填上厂商内核的真实 commit（需向 ESWIN 索取），并在 `misc` 里注明来源。

---

## 2. 路线 B：Maestro pipeline 配置（将来要提 PR 时的形态）

如果要把本 lab 变成 KernelCI pipeline 里可调度的 job，需要改的是
[`kernelci/kernelci-pipeline`](https://github.com/kernelci/kernelci-pipeline)（**不是 kernelci-core**）：

| 文件 | 要加什么 | 我们的对应物 |
|---|---|---|
| `config/trees.yaml` | 要测的内核树（我们测 mainline，通常已存在，无需新增） | —— |
| `config/jobs.yaml` | 一个 `kind: job` 的测试 job：`template` / `params` / `rules` / `kcidb_test_suite` | 我们的 `tests/*.sh` 全家桶 |
| `config/runtime/<name>.jinja2` | 生成测试定义的 jinja2 模板 | 需要一个把"串口+SSH+脚本"描述成 LAVA/pull-lab 能执行的形式 |
| `config/scheduler.yaml` | 调度规则：`job` + `event`（如某个 kbuild 节点 available）+ `runtime` + `platforms`（device type） | 目标板：`sifive-hifive-premier-p550` |
| `kernelci/kcidb` 的 `tests.yaml` | `kcidb_test_suite` 里引用的 suite 必须先在该文件里注册 | 我们的 5 个 suite 名 |

草案片段见 [`jobs-p550-snippet.yaml`](jobs-p550-snippet.yaml)（**标了 TODO，未提交**）。

**运行时选择**：Maestro 支持 `shell` / `docker` / `lava` / `kubernetes`，以及 **pull lab**
（lab 主动出站轮询 Maestro，**不需要公网可达**，适合放在校园网/家里的板子）。
我们的环境（校园网 + 串口 + SSH）最适合 pull lab 或 shell runtime + 自建 runner。

---

## 2.5 我们产出的上游可行动发现

见 [`upstream-findings.md`](upstream-findings.md)：**只有在真机上跑才会暴露**的 5 条问题/行为差异，
其中 2 条是源码级确认可修的 kselftest 缺陷（`riscv/sigreturn` 无 V 门控 → 无 V 平台 SIGILL；
两个 nolibc 向量测试用 `exit(-1)` 而非 `KSFT_SKIP=4`）。按约定**只准备材料、未提 PR**。

## 3. 与 RISE RP012 / Collabora 的关系（避免重复劳动）

RISE RP012 已经把 **Banana Pi F3 与 HiFive Premier P550 接进 Collabora 的公开 LAVA lab**，
做法是 **MCU 串口做电源/boot mode 控制 + BootROM fastboot 刷引导链 + Boardswarm**：

- 博客：<https://test.www.collabora.com/news-and-blog/news-and-events/tested-on-real-silicon-automating-risc-v-hardware-in-the-loop.html>
- P550 板级文档：<https://lava.pages.collabora.com/docs/boards/eic7700-hifive-premier-p550/>

**策略**：我们不重复造电源控制/刷机那一层，而是
① 用本仓库证明"同一套测试标准在真机上可复现、可回归"（Phase 1–2 已完成），
② 用 KCIDB 提交让结果进入 KernelCI 生态（路线 A），
③ 若要做成常驻 lab，则对齐 RP012 的 LAVA+Boardswarm 形态（路线 B 的长期形态）。

---

## 4. 本目录待办清单（都不涉及提 PR）

- [x] 调研并确认现代集成路径（本文档第 0 节）
- [x] KCIDB 报告生成器 + 结构自检 + **官方 kcidb-io v5.3 schema 校验**（抓到并修掉 4 个真实违规）
- [x] Maestro job/scheduler 草案片段
- [ ] 与你/mentor 确认 `origin` 命名与是否申请 token
- [ ] 解决"预装内核无 commit"的口径问题（走 hybrid 还是获取厂商 commit）
- [ ] 用真实 token 对 staging 提交一次，确认在 staging dashboard 上能看到 `origin`
- [ ] 之后再决定是否提 PR（以及 PR 提到 `kernelci-pipeline` 还是先只发邮件列表讨论）
