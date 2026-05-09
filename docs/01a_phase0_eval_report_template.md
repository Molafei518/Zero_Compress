# Phase 0 Trace 评估报告模板

> **填写流程**:对每个目标 workload 跑 `compress_eval.py`,把 JSON/MD 输出粘贴/链接到对应小节。
> **评审要点**:见文末 "决策清单"。

---

## 0. 元信息

| 字段 | 值 |
|------|----|
| 报告日期 | YYYY-MM-DD |
| 评估者 | _ |
| Trace 来源 | gem5 / FPGA prototype / hardware DDRC PMU / mock |
| 总 trace 容量 | _ GB / _ M lines |
| 评估器版本 | tools/compress_eval.py @ commit `<sha>` |

---

## 1. Workload 总览

| Workload | 描述 | Trace 大小 | 来源 |
|---|---|---|---|
| spec_int | SPEC CPU 2017 整数子集 | _ GB | gem5 |
| spec_fp | SPEC CPU 2017 浮点子集 | _ GB | gem5 |
| mlperf_kws | MLPerf Tiny keyword spotting | _ GB | gem5 |
| mlperf_visual | MLPerf Tiny visual wake | _ GB | gem5 |
| ... | ... | ... | ... |

---

## 2. 总览结果

| Workload | Mean | p1 | p50 | p99 | Uncomp% | 主导算法 | Verdict |
|---|---|---|---|---|---|---|---|
| spec_int | _x | _x | _x | _x | _% | BDI/Zero/BD | safe / marginal / unsafe |
| ... | | | | | | | |

> Verdict 规则:
> - **safe**:p1 ≥ 申报 CapRatio
> - **marginal**:p1 在 [1.1, CapRatio) 之间
> - **unsafe**:p1 < 1.0 或 uncomp > 50%

---

## 3. 各 Workload 详细报告

### 3.1 `<workload>` 详细

(粘贴 `compress_eval.py --out` 生成的 markdown 输出)

#### Top 危险页

| LA Page | Ratio | 触发原因 |
|---|---|---|
| 0xXXXX | _ | RGB 帧 / 加密 / 代码 |

#### 算法分布解读

(填写)若 None > 30%,审视危险页地址聚类,生成 BYPASS_CFG。

---

## 4. 加权场景估算(对比主文档 §6.1.3)

| 场景 | 估算 ratio | 实测 ratio(本评估) | 偏差 |
|---|---|---|---|
| 手机视频会议 | 1.32x | _ | _ |
| 车机 ADAS | 1.51x | _ | _ |
| AIoT 推理 | 1.78x | _ | _ |

> 若实测低于估算超过 0.1x,需要重新校准主文档的权重表。

---

## 5. CapRatio 决策

基于 §2 的 verdict,推荐:

| 目标场景 | 推荐 CapRatio | strap 配置 | 备注 |
|---|---|---|---|
| 手机 SoC | _ | strap=01 | _ |
| 车机 ADAS | _ | strap=10 | _ |
| AIoT 服务 | _ | strap=11 | _ |

---

## 6. BYPASS_CFG 推荐配置

由 `compress_eval.py --gen-bypass-cfg` 自动生成,人工审核地址语义后写入 BootROM:

```
[0] start=0x_______ end=0x_______ attr=NoCompress  # 帧缓冲
[1] start=0x_______ end=0x_______ attr=NoCompress  # 加密池
...
```

---

## 7. 决策清单(评审会用)

- [ ] 整体 ratio mean ≥ 1.5×?
- [ ] p1 ratio ≥ 1.2×?
- [ ] Uncompressible 比例 ≤ 30%?
- [ ] 危险页可被 ≤ 8 个 BYPASS 区间覆盖?
- [ ] 主导算法份额合理(不会单一算法 > 80%)?
- [ ] CapRatio 推荐有共识?
- [ ] 是否需要重新校准主文档 §6.1.3 的权重表?
- [ ] 是否需要回退 1.0× 模式(纯带宽 cache)?

签字:架构 _ / 算法 _ / 验证 _ / 项目 _
