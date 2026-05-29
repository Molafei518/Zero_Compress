# DDR Cache + Compression IP

> **透明 DDR 容量扩展器(Capacity Expander)** —— Master 看到的逻辑内存大于实际 DDR 物理容量,差额通过实时硬件压缩获得。

[![docs](https://img.shields.io/badge/docs-architecture%20v2.2-blue)](cache_compress_ip_architecture.md)
[![status](https://img.shields.io/badge/status-架构定稿%20·%20RTL%20待启动-orange)](#实现计划)

本仓库是一份完成度较高的 IP 架构方案:把"DDR-side 透明压缩 + Cache 加速 + OS 协同压力反馈"做到可评审、可启动 RTL 的粒度,并附带可执行的评估工具与 byte-precise 的数据格式 golden model。

---

## 它解决什么

多 Master SoC 里 DDR 是双瓶颈(带宽 + 容量)。本 IP 插在 **DDRC 内部(Arbiter 输出与 Scheduler 输入之间)**,对 Master 与 OS 数据通路透明:

- **容量扩展(P0)**:4GB DDR 对外申报 ≥6GB(默认 CapRatio 1.5×),差额由实时压缩兑现。
- **带宽节省**:读带宽 ≥15%(命中率主导);写带宽节省为条件目标(见 [§7.5](cache_compress_ip_architecture.md) 写带宽模型)。
- **Hit 延迟 ≤4 cycle**,Miss 开销目标 ≤30%(依赖 Meta Cache 命中率,见 §8.3.1)。
- **OS 透明 + 可降级**:不改内核数据通路,只需驱动 + IRQ;任何故障可一键 bypass。

三层地址空间是整方案的根:

```
 Master 视角           IP 内部              DDR 颗粒
   LA 6GB    ──L2P──▶  PPA 4GB   ──线性──▶  DPA 4GB
 (申报为系统内存)    (压缩后分配空间)      (实际 DRAM)
```

---

## 文档结构

| 文件 | 内容 |
|------|------|
| **[cache_compress_ip_architecture.md](cache_compress_ip_architecture.md)** | 主文档:定位 / 寻址与容量模型 / Cache / 压缩引擎 / 空间管理 / 时序 / 接口 / 可靠性 / 实现计划 / 风险 |
| [docs/01_phase0_trace_eval.md](docs/01_phase0_trace_eval.md) | Phase 0 真实 trace 压缩率评估方案(gem5 集成) |
| [docs/01a_…](docs/01a_phase0_eval_report_template.md) / [01b_…](docs/01b_phase0_eval_report_demo.md) | 评估报告模板与 mock 示范 |
| [docs/02_page_header_spec.md](docs/02_page_header_spec.md) | Page Header byte-precise 编码(V2 176B,CRC 链路) |
| [docs/03_page_reloc_fsm.md](docs/03_page_reloc_fsm.md) | 整页重定位 9 状态 FSM + MSHR 抢占协议 |
| [docs/04_os_driver_abi.md](docs/04_os_driver_abi.md) | OS 驱动 ABI(MMIO / 4 中断 / Mailbox / sysfs) |

> 冲突时**以子文档为准**,主文档随后同步。

---

## 工具

| 工具 | 用途 |
|------|------|
| [tools/compress_eval.py](tools/compress_eval.py) | 压缩评估器:三引擎压缩率 + 页级分布(p1/p50/p99) + **Reloc 频率模拟** + CapRatio 安全性 + BYPASS_CFG 生成 |
| [tools/page_header_codec.py](tools/page_header_codec.py) | Page Header 参考编解码器,作为 RTL golden model(含自检) |

### 快速上手

```bash
# Page Header golden model 自检
python tools/page_header_codec.py

# 用合成 workload 跑压缩评估(mlperf / auto_adas / aiot_inference / mobile_video / spec_int)
python tools/compress_eval.py --mock --workload aiot_inference --out report.json

# 演示整页重定位(Reloc)频率路径
python tools/compress_eval.py --mock --workload aiot_inference --rewrite-prob 0.5

# 真 trace(.zctrace,格式见 docs/01 §3)
python tools/compress_eval.py spec_gcc.zctrace --out report.json
python tools/compress_eval.py spec_gcc.zctrace --gen-bypass-cfg > bypass.cfg
```

无第三方依赖,纯标准库 Python 3。

---

## 实现计划

| 阶段 | 内容 | 周期 |
|------|------|------|
| Phase 0 | 架构 + 评估工具链(真 trace 验证 CapRatio 安全性) | 2 周 |
| Phase 1 | Cache + L2P 骨架(不引入压缩,接口预留) | 5-6 周 |
| Phase 2 | 三引擎压缩 + 整页重定位 | 5-6 周 |
| Phase 3 | GC + Pressure + OS 协同 | 3-4 周 |
| Phase 4 | 综合优化与签核(DFT / STA / FPGA 原型) | 2-3 周 |

---

## 待定关键决策

- **写带宽 25% 目标**:取决于 Phase 0 实测 Header 合并因子 `k` 与 Reloc 频率 `f`(详见主文档 §7.5)。
- **容量契约**:固定过报 + SLVERR,还是 memory hotplug 在线增容(推荐,详见 §3.3.4)——属产品定位级决策,需与 OS 团队联评。

详见主文档 [§16 风险与权衡](cache_compress_ip_architecture.md)。
