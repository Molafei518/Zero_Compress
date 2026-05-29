# Phase 0 — 真实 Trace 压缩率评估方案

> **目的**:在 RTL 启动前,用真实 workload 验证 1.5× 容量申报的安全性
> **依赖文档**:[../cache_compress_ip_architecture.md](../cache_compress_ip_architecture.md) §6.1.3
> **可交付物**:评估报告 + 配置 strap 推荐值 + 风险页清单

---

## 1. 为什么需要 Phase 0

主架构文档 §6.1.3 给出了三种 SoC workload 的**估算**加权压缩率:
- 手机视频会议:1.32×(危险,1.5× 申报会触发频繁压力)
- 车机 ADAS:1.51×(刚好)
- AIoT 推理:1.78×(安全)

但这些都是基于**人工估算的数据类型权重** + compress_eval.py 合成 pattern。
进入 RTL 投资之前,**必须**用真实 trace 验证三件事:

| 验证目标 | 要求 |
|---------|------|
| 加权压缩率均值 ≥ 1.5× | p50 |
| 压缩率分布的下尾 | p1 ≥ 1.2×(即 99% 时间不触发 SOFT_HIGH) |
| Reloc 频率 | < 1% / Evict |
| 不可压数据占比 | < 30%(否则 bypass 区间机制低效) |

---

## 2. 评估流程

```
┌─────────────────────────────────────────────────────────────┐
│  Step 1: 选择 Benchmark Suite                                │
│   ├─ SPEC CPU 2017(整数+浮点,通用计算)                       │
│   ├─ MLPerf Tiny(NPU 推理:keyword spotting/visual wake)     │
│   ├─ Geekbench 6(手机典型 workload)                         │
│   └─ 自定义 ISP / 视频编解码 trace(如有)                     │
├─────────────────────────────────────────────────────────────┤
│  Step 2: 生成 DDR Trace(2 种途径)                            │
│   A. gem5 全系统仿真 → MemTraceProbe → 标准化 trace          │
│   B. 真硬件 + DDRC PMU + 内存抓取(若有 FPGA prototype)       │
├─────────────────────────────────────────────────────────────┤
│  Step 3: 提取 Cache Line 数据(64B 粒度)                      │
│   - 从 trace 中提取每个 64B 写事务的 64 byte 数据 payload    │
│   - 按 LA 页(4KB)聚合                                        │
├─────────────────────────────────────────────────────────────┤
│  Step 4: 喂入压缩仿真器 compress_eval.py                     │
│   - 三引擎并行,选最小                                          │
│   - 统计每页:64 条 Line 的压缩 size 总和                      │
│   - 全局统计:p1 / p50 / p99 压缩率分布                        │
├─────────────────────────────────────────────────────────────┤
│  Step 5: 生成评估报告                                          │
│   - 整体 ratio + 分场景 ratio                                 │
│   - 危险页清单(压缩率 < 1.0,需 bypass)                       │
│   - CapRatio strap 推荐(1.25 / 1.5 / 1.75)                  │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. Trace 格式规范

为了让评估器与 trace 生成解耦,定义统一的中间格式:

### 3.1 二进制格式(`.zctrace`)

```
File Header (32 byte):
┌──────────┬───────┬──────────────────────────────────┐
│ Field    │ Size  │ Value                            │
├──────────┼───────┼──────────────────────────────────┤
│ magic    │ 8 B   │ "ZCTRACE\0"                      │
│ version  │ 4 B   │ 0x00010000(v1.0)                 │
│ workload │ 16 B  │ ASCII workload name (e.g. "spec_gcc") │
│ n_lines  │ 4 B   │ Cache Line 总条数                  │
└──────────┴───────┴──────────────────────────────────┘

Records (each 80 byte):
┌──────────┬───────┬──────────────────────────────────┐
│ la_addr  │ 8 B   │ 逻辑地址(64B 对齐)               │
│ rw       │ 1 B   │ 0=Read, 1=Write                 │
│ data     │ 64 B  │ Cache Line payload               │
│ tag      │ 4 B   │ workload-specific tag(如 PID/TID)│
│ pad      │ 3 B   │ 对齐                             │
└──────────┴───────┴──────────────────────────────────┘
```

### 3.2 文本格式(`.zctrace.txt`,调试用)

```
# magic=ZCTRACE version=1.0 workload=mlperf_kws n_lines=10000
0x80001000 W 00112233445566778899AABBCCDDEEFF... pid=1
0x80001040 R 00112233445566778899AABBCCDDEEFF... pid=1
...
```

---

## 4. gem5 集成方案

### 4.1 配置

```python
# gem5 配置脚本片段(configs/example/zc_eval.py)
from m5.objects import *

system = System()
system.mem_mode = 'timing'
system.mem_ranges = [AddrRange('4GB')]

# 关键:在 LLC 与 DDR 之间插入 MemTraceProbe
system.mem_ctrl = DDR4_2400_8x8()
system.mem_ctrl.range = system.mem_ranges[0]

# 自定义 Probe(需要在 gem5 mem 子系统添加 hook)
system.zc_probe = ZCMemTraceProbe(
    trace_file='out.zctrace',
    capture_data=True,         # 必须捕获 64B 数据 payload
    min_capture_addr='0x80000000',
    max_capture_addr='0xFFFFFFFF',
    sample_interval=1,         # 不抽样,全量
)
system.mem_ctrl.probe = system.zc_probe
```

### 4.2 修改清单

gem5 默认的 `MemTraceProbe` 不捕获数据 payload,需要小改造:

```cpp
// src/mem/probes/zc_mem_trace.cc(新增)
class ZCMemTraceProbe : public BaseMemProbe {
  void handleRequest(const ProbePoints::PacketInfo &pkt_info) override {
    if (pkt_info.cmd.isWrite()) {
      // 截取 64B Cache Line 数据
      ZCRecord rec;
      rec.la_addr = pkt_info.addr;
      rec.rw = 1;
      memcpy(rec.data, pkt_info.dataPtr, 64);
      writeRecord(rec);
    }
  }
};
```

> **替代方案**:不愿改 gem5 → 用 DRAMSim3 或 Ramulator 的内存 dump 模式 + 用户态后处理。

### 4.3 Workload 启动脚本

```bash
# 在 gem5 内启动 Linux,加载 SPEC/MLPerf
./build/X86/gem5.opt configs/example/zc_eval.py \
  --workload=spec_gcc \
  --kernel=linux-vmlinux \
  --disk=ubuntu-server.img \
  --cpu-type=O3CPU \
  --mem-type=DDR4_2400_8x8 \
  --runtime=60s    # 1min 真实时间足够生成 ~5GB trace
```

---

## 5. 评估器:`tools/compress_eval.py`

详见独立文件 [`../tools/compress_eval.py`](../tools/compress_eval.py)。功能:

| 输入 | 输出 |
|------|------|
| `.zctrace` 二进制文件 / 多文件 | JSON 报告 + Markdown 摘要 |
| `--mock` 模式(无 trace 时) | 用合成 pattern 跑 demo |
| `--rewrite-prob P`(mock) | 以概率 P 覆盖写已有地址,演示 Reloc 频率路径 |

报告含 `reloc` 段(§6 定义的 Reloc 频率):按 trace 时序演化每页 Buddy 槽位,
统计覆盖写导致"Header + 各 line 当前 size 之和"超出当前槽容量的次数 = 整页重定位。
输出 `reloc_per_write` / `reloc_per_overwrite`,直接对应主文档 §7.3 目标与 §7.5 写带宽模型的 `f`。

```bash
# 真 trace:reloc 频率随写覆盖模式自然产生
python compress_eval.py spec_gcc.zctrace --out report.json
# mock 演示 reloc 路径
python compress_eval.py --mock --workload aiot_inference --rewrite-prob 0.5 --out demo.json
```

输出结构:

```json
{
  "workload": "spec_gcc",
  "n_lines": 1234567,
  "n_pages": 19290,
  "overall": {
    "compression_ratio_mean": 1.42,
    "compression_ratio_p1":   1.05,
    "compression_ratio_p50":  1.39,
    "compression_ratio_p99":  4.21,
    "uncompressible_ratio":   0.18
  },
  "algo_distribution": {
    "BDI":       0.31,
    "Zero":      0.42,
    "ByteDelta": 0.18,
    "None":      0.09
  },
  "page_size_histogram": {
    "0-512":    0.05,
    "512-1024": 0.12,
    ...
  },
  "danger_pages": [
    {"la_page": "0x12345000", "ratio": 0.98, "uncompressible_lines": 64},
    ...
  ],
  "cap_ratio_safety": {
    "1.25x": "safe (p1 = 1.32x)",
    "1.50x": "marginal (p1 = 1.05x, will trigger pressure 1.5%/hour)",
    "1.75x": "unsafe (p1 = 1.05x < 1.0)"
  }
}
```

---

## 6. 评估指标定义

| 指标 | 定义 | 目标值 |
|------|------|--------|
| 整体压缩率 | sum(orig_bytes) / sum(comp_bytes) | ≥ 1.5× |
| 页级 p1 | 第 1 百分位的页压缩率 | ≥ 1.2× |
| 页级 p50 | 中位数 | ≥ 1.5× |
| 不可压比例 | 算法选 None 的 Line 占比 | < 30% |
| Reloc 频率(模拟) | 同一 LA 页两次写之间压缩 size 变化超过当前剩余空间的次数 / 总写次数 | < 1% |
| 危险页比例 | 页压缩率 < 1.0 的页占比 | < 5%(否则建议 bypass) |
| 算法分布偏斜 | 单一算法占比 > 80% | 警告(可考虑裁剪) |

---

## 7. CapRatio 决策规则

基于 p1 指标的安全决策:

```
if p1 >= 1.5:    推荐 1.5×, 标 "safe"
elif p1 >= 1.3:  推荐 1.5×, 标 "marginal,需 SOFT_HIGH=90%"
elif p1 >= 1.1:  推荐 1.25×, 标 "conservative"
elif p1 >= 0.95: 推荐 1.0×(纯带宽 cache 模式)
else:            告警,workload 不适合压缩,建议 bypass
```

---

## 8. 危险页处理

评估器会输出 `danger_pages` 列表(压缩率 < 1.0 的页)。处理流程:

1. **聚类分析**:危险页地址是否聚集(典型如帧缓冲、加密缓冲)
2. **生成 BYPASS_CFG**:连续地址段直接配置为 IP bypass 区间
3. **驱动注入**:启动时由 BootROM 写入 APB 寄存器

```python
# 评估器内置工具
$ python compress_eval.py --gen-bypass-cfg trace.zctrace > bypass.cfg
$ cat bypass.cfg
# Auto-generated bypass regions (8 max)
[0] start=0x80000000 end=0x80800000 attr=NoCompress  # framebuffer
[1] start=0xC0000000 end=0xC0100000 attr=NoCompress  # encrypted
```

---

## 9. 输出报告模板

详见 [`./01a_phase0_eval_report_template.md`](./01a_phase0_eval_report_template.md)。

执行示范报告(用 mock 数据)详见 [`./01b_phase0_eval_report_demo.md`](./01b_phase0_eval_report_demo.md)。

---

## 10. 实施清单

| 阶段 | 任务 | 负责 | 工时 |
|------|------|------|------|
| 1 | gem5 ZCMemTraceProbe 开发 | 仿真组 | 5d |
| 2 | SPEC + MLPerf workload 集成 | 仿真组 | 3d |
| 3 | compress_eval.py 完成 | 算法组 | 2d(已交付,见 tools/) |
| 4 | 跑 trace + 评估 | 仿真组 | 5d(并行 4 workload) |
| 5 | 报告 + CapRatio 决策评审 | 架构组 | 2d |
| **合计** | | | **~3 周** |

> **关键路径**:gem5 改造。如时间紧,可先用 mock + 公开内存 trace dataset(如 [PARSEC trace](https://parsec.cs.princeton.edu/))起跑。
