# results/ 目录说明

## 结构

```
results/
  trend.md                     ← 自动生成（scripts/report-history.py）
  YYYY-MM-DD-*.md              ← 人工撰写的成绩单/证据文档（bootchain、对照表等）
  history/<时间戳>/             ← 每次 run-board-tests.sh 自动归档
      board-info.log
      cpuinfo.log
      ext.log
      vector.log
      bench.log
      bootchain.log
      results.json             ← 机器可读汇总（趋势表的输入）
```

## results.json schema

```json
{
  "date": "20260824-191548",
  "target": "sifive-hifive-premier-p550",
  "board": {
    "model": "SiFive HiFive Premier P550",
    "isa": "rv64imafdc_...",
    "rootdev": "/dev/mmcblk0p2",
    "ext": { "h": false, "v": false, "zpm": false }
  },
  "tests": {
    "board_info": "PASS",
    "cpuinfo": "PASS",
    "ext_scan": "PASS",
    "vector": "SKIP",
    "vector_bench": { "status": "SKIP", "ms": null },
    "bootchain": "PASS"
  },
  "overall": "PASS"
}
```

## 状态语义

| 状态 | 含义 |
|---|---|
| `PASS` | 通过 |
| `FAIL` | 失败（会导致 `overall=FAIL`） |
| `SKIP` | 按平台能力合理跳过，**不算失败**（例如：板子无 V 扩展 → vector 项 SKIP） |

`SKIP` 是这套流水线刻意保留的语义：SOW 要的是"跨微架构行为差异"，缺失扩展是**结论**而不是**故障**。
