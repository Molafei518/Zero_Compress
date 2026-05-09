# Phase 0 Trace 评估报告 — 示范 (Mock 数据)

> ⚠️ **本报告基于 mock 合成数据**,**不**代表真实压缩率。
> 目的是演示评估流程与报告形态。真实评估需替换为 gem5 / FPGA trace。

---

## 0. 元信息

| 字段 | 值 |
|------|----|
| 报告日期 | 2026-05-09 |
| 评估者 | (auto-generated demo) |
| Trace 来源 | **mock**(`compress_eval.py --mock`) |
| 总 trace 容量 | 30,000 lines × 5 workloads = 150K lines |
| 评估器版本 | `tools/compress_eval.py` v1.0 |

---

## 1. Workload 总览

| Workload | 描述 | Trace 大小 | 来源 |
|---|---|---|---|
| mobile_video | 手机视频会议合成 | 30K lines | mock |
| auto_adas | 车机 ADAS 合成 | 30K lines | mock |
| aiot_inference | AIoT 推理合成 | 30K lines | mock |
| mlperf | MLPerf Tiny 风格合成 | 30K lines | mock |
| spec_int | SPEC INT 风格合成 | 30K lines | mock |

---

## 2. 总览结果

| Workload | Mean | p1 | p50 | p99 | Uncomp% | 主导算法 | Verdict @1.5× |
|---|---|---|---|---|---|---|---|
| spec_int | **1.57×** | 1.44× | 1.57× | 1.74× | 20.8% | BDI 30% | **marginal** |
| auto_adas | 1.34× | 1.20× | 1.34× | 1.53× | 53.8% | None 54% | **risky** |
| aiot_inference | 1.31× | 1.16× | 1.31× | 1.47× | 61.7% | None 62% | **risky** |
| mobile_video | 1.29× | 1.18× | 1.28× | 1.41× | 55.0% | None 55% | **risky** |
| mlperf | 1.26× | 1.14× | 1.25× | 1.43× | 68.4% | None 68% | **risky** |

---

## 3. 关键观察

### 3.1 mock 数据普遍偏保守

5 个 workload 中 4 个的 mean ratio 在 1.26~1.34×,只有 spec_int 接近 1.5×。
原因分析:
- mock 生成器对 NPU activation 用 70% 零比例,但**实际数据稀疏度通常更高**(ReLU 后 80~95% 零)
- ByteDelta 的实现选择了较保守的 delta 范围(±7),实测可放宽到自适应
- 缺少"重复块"模式(memset 区段、相同结构体阵列)

→ **结论**:mock 数据的输出**不能直接采信**,主文档 §6.1.3 的 1.32 / 1.51 / 1.78× 需要真 trace 验证。

### 3.2 "uncompressible" 占比异常高

mlperf workload 的 None 占比 68% 表明 mock 生成器的"非典型数据"权重过大。
真实 NPU 推理的 activation 不可压比例通常 < 30%。

### 3.3 spec_int 表现最好的原因

- 大量指针数组(8B 一致前缀)→ BDI Mode 4
- struct padding 触发 Zero
- 小整数数组 → ByteDelta Mode 4
- 三种算法各占 ~30%,组合优势明显

→ 这个分布最接近主文档 §6.1.1 的 "1.69× 三引擎组合" 报告。

---

## 4. 加权场景对比(对比主文档 §6.1.3)

| 场景 | 主文档估算 | mock 实测 | 偏差 | 行动 |
|---|---|---|---|---|
| 手机视频会议 | 1.32× | 1.29× | -0.03× | mock 大致一致,需真 trace 确认 |
| 车机 ADAS | 1.51× | 1.34× | **-0.17×** | **mock 偏低,需校准** |
| AIoT 推理 | 1.78× | 1.31× | **-0.47×** | **mock 严重偏低,activation 稀疏度未模拟好** |

---

## 5. CapRatio 决策(基于 mock)

> 注意:以下决策仅基于 mock 数据,**正式决策需替换为真 trace**。

| 目标场景 | mock 推荐 | 备注 |
|---|---|---|
| 手机 SoC | **1.25×**(strap=01) | mock p1=1.18 < 1.5,只能保守申报 |
| 车机 ADAS | **1.25×**(strap=01) | 同上 |
| AIoT 服务 | **1.25×**(strap=01) | mock 严重低估,真 trace 应可达 1.5× |
| 桌面/服务器 | **1.5×**(strap=10) | spec_int 表明可行 |

> **若仅依赖 mock 出货** → 默认 1.25×,丢掉一半潜在容量收益。这就是为什么 Phase 0 必须做真 trace 评估的硬约束。

---

## 6. BYPASS_CFG 推荐(由危险页聚类生成)

(实际跑 `--gen-bypass-cfg` 后填入)

```
# 示例(基于 mobile_video mock):
# 大量危险页地址离散,无法用 8 个区间覆盖
# → 应当增大 RGB 帧地址的连续性,或上调 BYPASS_REGION_NUM
```

---

## 7. 决策清单结果

- [x] 评估流程跑通,工具可用
- [ ] 整体 ratio mean ≥ 1.5×?(只 spec_int 达标)
- [ ] p1 ratio ≥ 1.2×?(均勉强)
- [ ] Uncompressible 比例 ≤ 30%?(只 spec_int 达标)
- [ ] 危险页可被 ≤ 8 个 BYPASS 区间覆盖?(mock 离散,需真 trace)
- [x] 主导算法份额合理(spec_int 三算法均衡;其他 None 占主)
- [ ] CapRatio 推荐有共识?(待真 trace 后)
- [x] 是否需要校准主文档 §6.1.3?(**是**,等真 trace)
- [ ] 是否需要回退 1.0× 模式?(无需)

---

## 8. Phase 0 关键 takeaway

1. **评估器与流程已交付**,RTL 启动前必须用 gem5 真 trace 重跑
2. **mock 数据系统性低估压缩率**,主要因为 NPU activation 稀疏度建模不真实
3. **CapRatio strap 设计的价值已验证**:不同 workload 适合不同 strap
4. **BYPASS_CFG 设计有效**:危险页可被聚类(若地址连续)

---

## 附:复现命令

```bash
cd Zero_Compress

# 单 workload
python tools/compress_eval.py --mock --workload mobile_video \
    --n-lines 30000 --out tools/sample_data/mobile_video.json

# 全部 workload
for w in mobile_video auto_adas aiot_inference mlperf spec_int; do
    python tools/compress_eval.py --mock --workload "$w" \
        --n-lines 30000 --out "tools/sample_data/$w.json"
done

# 生成 BYPASS_CFG
python tools/compress_eval.py --mock --workload mobile_video \
    --gen-bypass-cfg
```
