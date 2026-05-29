# DDR Cache + Compression IP 架构方案

> **版本**:v2.2(一致性修正 + 写带宽/Miss 延迟/容量契约风险量化)
> **状态**:架构定稿,RTL 待启动
> **核心定位**:**透明 DDR 容量扩展器** —— Master 看到的逻辑内存大于实际 DDR 物理容量,差额通过实时压缩获得

## 文档矩阵

本主文档定义整体架构,以下子文档细化关键模块。**冲突时以子文档为准**,主文档随后同步:

| 子文档 | 主题 | 与主文档关系 |
|--------|------|-------------|
| [docs/01_phase0_trace_eval.md](docs/01_phase0_trace_eval.md) | Phase 0 Trace 评估方案 | 细化 §6.1.3 / §13 Phase 0 |
| [docs/01a_phase0_eval_report_template.md](docs/01a_phase0_eval_report_template.md) | 评估报告模板 | — |
| [docs/01b_phase0_eval_report_demo.md](docs/01b_phase0_eval_report_demo.md) | 评估报告示范(mock) | — |
| [docs/02_page_header_spec.md](docs/02_page_header_spec.md) | Page Header byte-precise 编码 | **覆盖** §3.2.3 / 附录 B.2(176B 取代 128B) |
| [docs/03_page_reloc_fsm.md](docs/03_page_reloc_fsm.md) | 整页重定位 FSM 与 MSHR 抢占 | 细化 §5.7 / §7.3 / §8.4 |
| [docs/04_os_driver_abi.md](docs/04_os_driver_abi.md) | OS 驱动 ABI(MMIO/IRQ/Mailbox) | 细化 §9 / §11.2 / §14 |
| [tools/compress_eval.py](tools/compress_eval.py) | 压缩评估器(可执行) | — |
| [tools/page_header_codec.py](tools/page_header_codec.py) | Page Header 参考编解码器 | — |

---

## 0. 文档导读

本方案围绕一条核心设计主线展开,阅读时建议按以下顺序:

| 顺序 | 章节 | 解决的问题 |
|------|------|-----------|
| 1 | §1 项目定位 | 这是什么 IP?为谁设计?目标是什么? |
| 2 | §2 系统集成 | IP 在 SoC 中的位置,与 OS / Master / DDRC 的边界 |
| 3 | **§3 寻址与容量模型** | 6.76GB 逻辑空间如何映射到 4GB 物理 DDR — **整方案的根** |
| 4 | §4 模块架构 | 顶层框图与 RTL 划分 |
| 5 | §5 Cache 设计 | Tag/Data/MSHR/Pipeline |
| 6 | §6 压缩引擎 | 三引擎并行选型与原理 |
| 7 | **§7 空间管理** | 写更新引发的重定位、碎片整理、压力反馈 |
| 8 | §8 数据通路时序 | Hit/Miss/Evict/重定位的 cycle 级行为 |
| 9 | §9 接口定义 | AXI 上下游 + APB 配置 + 中断 |
| 10 | §10 可靠性与安全 | ECC / CRC / 加密内存交互 |
| 11 | §11 启动与运行时 | 冷启动、低功耗、Flush、Hot Plug |
| 12 | §12 可配置参数 | 综合时刻配置项 |
| 13 | §13 实现计划 | 4 阶段交付 |
| 14 | §14 性能监测与 Debug | 计数器 / Trace / Bus Error 注入 |
| 15 | §15 验证与签核 | 单元 / 集成 / 形式 / 系统级 |
| 16 | §16 风险与权衡 | 风险量化与缓解 |
| 17 | §17 开源参考 | 可借鉴的工业/学术资源 |
| 附录 | A 术语 / B 数据格式 / C 命令时序 | 参考 |

---

## 1. 项目定位

### 1.1 背景

在多 Master SoC 中,DDR 是公认的双瓶颈:
- **带宽瓶颈**:CPU/GPU/NPU/ISP 等多 Master 共享 DDR 通道,峰值需求总和远超物理带宽
- **容量瓶颈**:NPU 模型权重、ISP 中间帧、Cache for AI 等典型 workload 把 DDR 容量推到上限,而封装/成本/功耗约束又限制了 DDR 颗粒数量

软件层面已有的应对(ARMv9 MTE、CXL.mem、zswap)各有局限:zswap 走 CPU 路径功耗高、CXL 延迟劣;**硬件透明压缩**(IBM AME 2010、CXL.mem with HW compression)是在不动 OS / 不动 Master 的前提下,同时获得**带宽与容量收益**的工业级答案。

### 1.2 设计目标

| 目标 | 量化指标 | 优先级 |
|------|---------|-------|
| **容量扩展** | DDR 4GB → 对外申报 ≥6GB(实测 1.69× 综合压缩率,留 12% 安全余量) | **P0** |
| **带宽节省** | 读带宽 ≥15%(命中率 70% 主导);写带宽 ≥25% **(条件目标:需 §7.5 的 Header 合并 k≥12 且 Reloc 频率 f≤0.1%,Phase 0 实测决定能否兑现)** | 读 P0 / 写 P1 |
| **Hit 延迟** | ≤4 cycle | P0 |
| **Miss 延迟开销** | 相对裸 DDR 增加 ≤30%(含 Meta 查询 + 解压) | P1 |
| **OS 透明** | 不需修改 OS 内核数据通路;只需驱动 + irq handler | P0 |
| **可降级** | 任何故障下可一键 bypass 退化到非压缩模式,不影响业务正确性 | P0 |

### 1.3 产品定位:容量扩展器(Capacity Expander)

本 IP 是 **DDR-side 透明容量扩展器**,而非纯带宽 cache。三个关键含义:

1. **Master 看到的物理地址空间 > DDR 实际容量**
   - 4GB DDR 颗粒 + 本 IP → 对外申报 **6GB**(配置可调,默认 1.5×)
   - OS 启动时由本 IP 驱动通过 e820 / DT memory node 上报扩展后容量
2. **压缩失败/压力 → 中断 OS,而非直接报错**
   - 全局压缩率劣化、空间不足时,触发 `MEM_PRESSURE` 中断
   - OS 驱动响应:可选 swap-out / drop page cache / OOM killer
3. **加速器(Cache)是手段,不是定位**
   - Cache 命中是为了:省 DDR 访问 + 省解压延迟 + 写合并降低重定位频率
   - 没有 Cache 的纯压缩方案延迟过高,业务无法接受

### 1.4 设计约束

| 约束项 | 说明 |
|--------|------|
| 插入位置 | DDRC 内部,Arbiter 输出与 Scheduler 输入之间(非 DFI) |
| 上下游接口 | AXI-like(addr/data/id/len/size/burst/qos),DDRC 自研,内部仲裁 |
| OS 接口 | APB 配置 + 中断 + 共享内存 mailbox(L2P 表 ABI) |
| Hit 延迟预算 | ≤ 4 cycle |
| Miss 延迟预算 | 裸 DDR 延迟 × 1.3 |
| 工艺与频率 | 默认 800MHz @ 7nm,综合后需通过 STA |
| 可降级 | 全局 bypass 开关 + 按地址区间 bypass + 单事务 NCA(Non-Cacheable Attribute)透传 |

---

## 2. 系统集成

### 2.1 IP 在 DDRC 中的位置

```
  CPU ────→ AXI Slave Port 0 ──→ Req Queue 0 ──┐
  GPU ────→ AXI Slave Port 1 ──→ Req Queue 1 ──┤
  DMA ────→ AXI Slave Port 2 ──→ Req Queue 2 ──┤── Arbiter ──┐
  ISP ────→ AXI Slave Port 3 ──→ Req Queue 3 ──┘             │
                                                              ▼
                                                ┌──────────────────────────┐
                                                │ Cache + Compress IP      │
                                                │  ┌──────┐  ┌──────────┐  │
                                                │  │Cache │  │ Compress │  │
                                                │  └──────┘  └──────────┘  │
                                                │  ┌────────────────────┐  │
                                                │  │ L2P Map + GC       │  │
                                                │  └────────────────────┘  │
                                                └──────────┬───────────────┘
                                                           │
                                             Cmd Queue ──→ Scheduler ──→ DFI ──→ PHY ──→ DDR
                                                           │
                                                           └─→ APB / IRQ → SoC Bus → CPU/OS
```

### 2.2 架构选型

在多 Master 直接对接 DDRC 的架构下,评估三种放置方案:

| 方案 | 描述 | 优势 | 劣势 | 结论 |
|------|------|------|------|------|
| A. DDRC 内部仲裁后(单实例) | Arbiter 输出 → IP → Scheduler | 单实例无一致性问题;保留多 Port 并行;接口统一;L2P/GC 单点管理 | 需改造 DDRC 流水线 | **采用** |
| B. DDRC 前加互联 | Masters → Interconnect → IP → DDRC 单 Port | 架构干净 | 废弃多 Port 并行;单 Port 成瓶颈 | 不采用 |
| C. 每 Port 前各放一个 | 多实例 | 不改 DDRC | 多实例 L2P 不可分;Master 切换跨实例时数据不可见 | 不可行 |

### 2.3 不可插入位置:DDRC ↔ PHY 之间(DFI)

- DFI 传输的是底层 DRAM 命令(ACT/RD/WR/PRE/REF),非读写事务
- Refresh 时序由 Controller 管理,中间拦截会导致数据丢失
- Bank/Row 调度被破坏
- PHY Training 序列依赖 Controller 直接交互

### 2.4 一致性域与系统集成约束

本 IP 是**整个 DDR 子系统的唯一访问入口**。系统级约束:

| 约束 | 说明 |
|------|------|
| **强制路径约束** | 所有访问 DDR 物理地址的事务**必须**经过本 IP。绕开本 IP 直访 DDR(例如某些 DMA 直通模式)将看到压缩后的乱码数据 |
| **Master 端 Cache 关系** | 本 IP 不替代 Master 私有 Cache(L1/L2)。CPU 私有 Cache 与本 IP 互不感知,通过常规 Cache Maintenance Op(CMO) 推送脏数据到本 IP 即可 |
| **CMO 透传** | AXI Cache Maintenance(`AxCACHE`/`AxDOMAIN`)与 ACE Snoop 透传到本 IP;本 IP 把命中行作为常规读写处理,无需参与 snoop |
| **NCA / Device 内存** | 标记为 Device / Strong-Order / NCA 的事务跳过 Cache 直接转发,但**仍经压缩通路**(压缩对 Master 透明,不影响语义) |
| **Bypass 区间** | 通过 APB 配置最多 8 个地址区间为 "no-compress + no-cache",用于 RGB 帧缓冲、代码段、加密内存等已知不可压缩区域 |
| **OS 协同接口** | 4 个中断 + 1 块 mailbox SRAM(共享 L2P 表元信息);驱动模式见 §11.4 |

---

## 3. 寻址与容量模型 ⭐

> 本章是整方案的**根**。所有后续设计(Cache/压缩/元数据/GC)都建立在本章定义的地址空间和分配粒度之上。

### 3.1 三层地址空间

```
   Master 视角                IP 内部视角                DDR 颗粒视角
┌──────────────────┐     ┌──────────────────┐      ┌──────────────────┐
│   LA (Logical)   │     │ PPA (Pseudo Phys)│      │  DPA (DDR Phys)  │
│   6 GB           │ ──→ │  4 GB            │ ───→ │  4 GB            │
│   申报为系统物理  │     │  IP 内部分配空间  │      │  实际 DRAM 颗粒    │
│   内存            │     │                  │      │                  │
└──────────────────┘     └──────────────────┘      └──────────────────┘
       L2P Map                Slab/Buddy               线性映射
   (LA Page → PPA region)    (PPA 内空间分配)         (PPA == DPA)
```

- **LA(Logical Address)**:Master 看到的"物理"地址,启动时上报为 6GB。LA 空间是**稀疏可寻址但不连续 commit**:OS 看到 6GB,但实际只有写过的页才占 PPA。
- **PPA(Pseudo Physical Address)**:IP 内部为压缩后数据分配的连续地址空间,大小 = DDR 实际容量(4GB),与 DPA 一一对应。
- **DPA(DDR Physical Address)**:实际 DDR 颗粒地址。本 IP 维护的元数据区(L2P 表、Page Header、GC bitmap)从 DPA 高位向低位预留(默认 ~256MB,见 §3.5)。

> **为什么是 1.5× 而非 1.69×**:虽然 compress_eval.py 实测综合压缩率 1.69×,但真实负载混合后会下降(见 §6.5 加权分析)。1.5× 留 12% 安全余量,允许压缩率劣化时仍不立即触发压力中断。该比例可在启动时由 BootROM 通过 strap pin 配置为 1.25× / 1.5× / 1.75× / 2.0×。

### 3.2 LA → PPA 映射机制

#### 3.2.1 映射粒度:**4KB 页**

选择理由:
- 与 OS Page 对齐,驱动协同简单
- 4KB 内 64 条 Cache Line,压缩元数据可摊销
- 粒度过细(64B/Line)→ L2P 表爆炸;粒度过粗(64KB)→ 写放大严重

#### 3.2.2 L2P 表结构

```
L2P Entry (per LA Page, 8 Byte):
┌──────────┬────────┬──────────┬─────────┬────────┬────────┐
│ Valid    │ State  │ PPA Ptr  │ Size    │ AlgoMix│ Rsvd   │
│ 1 bit    │ 3 bit  │ 32 bit   │ 13 bit  │ 8 bit  │ 7 bit  │
└──────────┴────────┴──────────┴─────────┴────────┴────────┘
                                  │
   State 编码:                     │  Size: 该 LA 页压缩后占用的 PPA 字节数(0~4272,需 13 bit)
     000 = Unmapped (零填充语义)    │  AlgoMix: 8 bit = 4 种算法 × 2 bit 占比档位
     001 = Mapped, Compressed       │            (本页 64 行中各算法的粗粒度占比,仅供 GC/统计;
                                    │             解压必需的 per-line algo 在 Page Header,不在此)
     010 = Mapped, Uncompressed     │  PPA Ptr: 指向 PPA 中该页的起始字节(对齐到 64B)
     011 = Mapped, Bypass (NCA)     │
     100 = Pending (正在重定位)      │
     101 = Error (压缩/解压故障)     │
     110~111 = Reserved             │

L2P 表总大小:
  6 GB / 4 KB × 8 B = 12 MB
  存储在 DDR 元数据区,片上 L2P Cache 缓存热门项
```

#### 3.2.3 Page Header(随每个 PPA 页同址存储)

由于 L2P Entry 中只记录"页位置"和"页大小",**页内 64 条 Line 的细粒度信息**(每 Line 用什么算法、压缩到多大、在页内 offset)必须存放在被压缩的页本身的开头。

> **详细 byte-precise 布局见 [docs/02_page_header_spec.md](docs/02_page_header_spec.md)**。这里仅给概要。

```
每个 PPA Page 起始处的 Page Header (固定 176 Byte,Line 0 之前):
┌──────┬─────┬─────────┬─────┬───────┬─────────────┬────────────┬─────────┐
│Magic │rsvd │Generation│tot_sz│ rsvd │ Page CRC32  │ Line Info  │Line CRC8│
│ 2 B  │ 2 B │  4 B    │ 2 B │ 2 B  │   4 B       │  88 B      │ 64 B    │+ 8B rsvd
└──────┴─────┴─────────┴─────┴───────┴─────────────┴────────────┴─────────┘
                                                       │              │
       Line Info: 11 bit/Line × 64 ───────────────────┘              │
         {algo[1:0], mode[2:0], size_minus_1[5:0]}                   │
       Line CRC8: 8 bit/Line × 64 ────────────────────────────────────┘
         CRC8/SAE-J1850, 覆盖该 Line 的压缩 byte 序列

PPA 页总占用 = 176B Header + sum(line_size) ≤ 176 + 64×64 = 4272 B

注:总和 > 4KB 的页退化为 "Uncompressed" 模式,
    L2P State = 010,PPA 占 4KB+176B = 4272 B
```

为何不存 Line offset:offset 由 size 累加得到(prefix-sum),Header 读完后并行计算。
为何 CRC8 单独成数组:Phase 1 可降级到 V1(128B,无 Line CRC),数组分离方便配置切换。

#### 3.2.4 完整地址翻译流程

```
Master 发出 LA = 0x1_2345_6780(读 64B)
   │
   ▼
  分解: LA_PageNum = 0x12345 (高 20 bit), LineIdx = 0x1E (中 6 bit), Offset = 0x00 (低 6 bit)
   │
   ▼
  ┌─────────────────┐   miss  ┌──────────────────────┐
  │ L2P Cache 查询   │ ──────→ │ 从 DDR L2P 表读 Entry │
  │ (LA_PageNum)    │         │ (一次 DDR 读)         │
  └────────┬────────┘         └──────────┬───────────┘
           │ hit                          │
           ▼                              ▼
    L2P Entry: State=Mapped/Compressed
              PPA Ptr = 0x8AB_C000
              Size    = 0x800 (2048 B)
   │
   ▼
  ┌─────────────────────────────────────────┐
  │ 读 Page Header (PPA Ptr,176 B)         │
  │   → Line[30] info: {algo=01, mode=2,   │
  │       size=11(=12B), crc8=0x3F,         │
  │       offset_in_page=0x180}             │
  └────────────────────────┬────────────────┘
                           ▼
                  PPA 实际读地址 = PPA Ptr + 176 + offset_in_page = 0x8AB_C230
                  读 12 B 压缩数据 → 解压 → 返回 64 B 给 Master
```

> **优化**:Page Header 与 L2P Cache 命中数据合并存储,避免每次 Miss 多读一次 Header。详见 §5.5 Meta Cache 组织。

### 3.3 容量超额申报与压力反馈

容量扩展器的最大风险是 **压缩率劣化导致已申报容量装不下**。本方案采用"保守申报 + 实时监控 + 双层压力反馈"。

#### 3.3.1 三种容量水位

```
  PPA 占用率  │
   100% ┌──── HARD_FULL (100%) ──── 拒绝新分配,触发 IRQ_HARD_FULL,OS 必须立即释放
        │
    95% ├──── SOFT_HIGH (95%)  ──── 触发 IRQ_PRESSURE,OS 应主动 swap/drop
        │
    80% ├──── SOFT_LOW  (80%)  ──── 启动后台 GC,寻找空闲页合并
        │
        │
        │
     0% └────
```

#### 3.3.2 OS 协同(参见 §11.4 驱动)

- `IRQ_PRESSURE`(SOFT_HIGH 触发):驱动响应,扫描 LRU,选低价值页 munmap/swap,释放 LA → L2P 表对应 Entry State=Unmapped → IP 回收 PPA 空间
- `IRQ_HARD_FULL`(HARD_FULL 触发):驱动必须在阈值时间内(默认 10ms)释放至少 64MB,否则**新写请求返回 SLVERR**,Master 可见错误,由上层 OOM 处理

#### 3.3.3 配置策略

- 出厂默认 **CapRatio = 1.5×**,且 SOFT_HIGH = 95%
- 极端场景(如已知 workload 压缩率稳定 >2×)可调到 1.75×
- 保守场景(如安全/加密内存比例高)可调到 1.25× 甚至 1.0×(纯带宽 cache 模式)

#### 3.3.4 SLVERR-on-store 的危险语义与替代契约 ⭐

> 这是本 IP 产品定位层面**最关键的未决风险**,需与 OS 团队联评(见 [docs/04](docs/04_os_driver_abi.md) §11)。

**问题**:HARD_FULL 超时后对**写**返回 SLVERR(§3.3.2)。但对"普通 RAM 的 store"返回 bus error,绝大多数 OS 无法优雅恢复:

- store 故障在多数架构上是**不精确异步异常**,内核难以定位到具体指令/进程 → 往往直接 panic,而非干净的 SIGBUS。
- 即使能转成 SIGBUS,普通应用对"写本地内存触发 SIGBUS"毫无预期,等同崩溃。
- 10ms 内让 OS vmscan/swap 释放 64MB 极其紧张(swap 后端是块设备,延迟不可控)。

**等价于**:压缩率不达标 → 系统崩溃。这把一个"性能/容量问题"升级成了"可用性问题"。

**替代契约(强烈建议评估,优先级高于现有 SLVERR 方案)**:

| 方案 | 机制 | 优点 | 代价 |
|------|------|------|------|
| **A. Memory Hotplug 增容**(推荐) | 基线只上报 **4GB(物理真值)**;压缩腾出余量后,IP 通过中断请求驱动**在线 hot-add** 内存块;压力时 hot-remove(offline) | 永不对 store 返回错误;与 Linux memory hotplug / `movable_node` 成熟机制对接;OOM 由标准内核路径处理 | 需要可 offline 的 movable zone;hot-remove 可能因页 pin 失败(需迁移) |
| **B. virtio-balloon 风格** | 上报 6GB,但用 balloon 驱动在压力时"吃掉"页(标记 IP 不再服务),等效缩小可用量 | 复用虚拟化成熟范式;无 store 错误 | 需要 balloon 驱动常驻;非虚拟化裸机支持弱 |
| **C. 现方案(过报 + SLVERR)** | 上报 6GB,HARD_FULL 超时对写 SLVERR | IP 侧最简单 | **store 错误 → panic 风险**;OS 协同窗口极紧 |

> **建议**:Phase 0 与 OS 团队就 A/B/C 定调。若产品面向 Linux,**方案 A(hotplug 增容)** 在工程上最稳妥——把"逻辑容量"做成动态可增可减,而非固定过报后用错误兜底。
> 现有 SLVERR 路径可保留为**最后防线**(方案 A/B 都失败时的硬止损),但不应是常态路径。

### 3.4 写更新与重定位

容量扩展器的核心难点 —— 写覆盖后压缩大小变化时如何处理。

```
Case A:  原 Line 压缩 20B → 新 Line 压缩 18B
   → 直接写在原 PPA offset,余下 2B 不释放(由 GC 回收)。L2P 不变。

Case B:  原 Line 压缩 20B → 新 Line 压缩 50B
   → 原 PPA 槽位不够 → 触发**整页重定位**:
       1. 把所有 64 条 Line 解压到 Cache(若已在 Cache,跳过)
       2. 重压缩,选最优 algo 组合
       3. 在 PPA Free List 申请新页空间
       4. 写入新位置 + 更新 L2P Entry (State=Pending → Mapped)
       5. 旧位置加入 GC 回收队列

Case C:  整页变得不可压缩(压缩后 > 4KB)
   → State 转为 Uncompressed,固定占 4KB+176B;后续若可压回再切换。
```

> **关键设计决策**:本方案不做"页内插入式重排"。任何 Line 大小变化导致页内布局失败时,**整页重定位**(代价高但可控)。这避免了"页内 RMW 风暴"问题。

写更新延迟与频率分析见 §7.4 / §8.5。

### 3.5 元数据区物理布局

```
DDR 物理空间(4GB,按高位向下保留):
┌─────────────────────────────────────────────────────┐ 0x0000_0000 (PPA 起始)
│                                                     │
│              PPA 数据区 (~3.75 GB)                   │
│              用于存放压缩后的页                        │
│                                                     │
│                                                     │
├─────────────────────────────────────────────────────┤ 0xF000_0000
│  GC Bitmap (4 MB)                                   │
│    每页 1 bit,共 1M 项                              │
├─────────────────────────────────────────────────────┤ 0xF040_0000
│  PPA Free List Tree (16 MB)                         │
│    Buddy allocator 多级 bitmap                      │
├─────────────────────────────────────────────────────┤ 0xF140_0000
│  L2P Table 主+备 (24 MB)                            │
│    1.5M LA 页,每项 8B,双副本(§10.7,Bank 分离)   │
├─────────────────────────────────────────────────────┤ 0xF2C0_0000
│  Reserved / 性能日志环 (224 MB)                      │
│                                                     │
└─────────────────────────────────────────────────────┘ 0xFFFF_FFFF (DDR 顶)

总元数据开销:
  - DDR 高位区(L2P 主+备 24 + Bitmap 4 + FreeList 16)≈ 44 MB
  - PPA 页内 Header ≈ 176 MB(1M 页 × 176B)
  - 合计 ≈ 220 MB / 4GB ≈ **5.4%**(Header 含在 PPA 内)
注:Header 在 PPA 内存储,不算独立保留区,但占用 PPA 空间预算;
   Bitmap/FreeList 可由 L2P+Header 重建,故单副本;唯 L2P 双副本
     高位预留按 256MB 留够余量供未来扩展
```

---

## 4. 模块架构

### 4.1 顶层框图

```
                    From Arbiter (AXI-like)
                           │
                   ┌───────┴────────┐
                   │  Request Buffer │  ← 解耦 Arbiter 时序,支持多 outstanding
                   └───────┬────────┘
                           │
                  ┌────────┴─────────┐
                  │ Address Decoder  │  ← 判定 Bypass / NCA / 正常路径
                  └────────┬─────────┘
                           │
                  ┌────────┴────────────────┐
                  │  Cache Pipeline Ctrl    │  ← 4 级流水(REQ/TAG/DATA/RESP)
                  │  + MSHR + Stall Logic   │
                  └─┬───┬───┬────┬──────────┘
                    │   │   │    │
              ┌─────┘   │   │    └────────┐
              ▼         ▼   ▼             ▼
        ┌──────────┐┌──────────┐┌────────────────────┐
        │ Tag RAM  ││ Data RAM ││  L2P/Meta Cache    │
        │          ││ (4 Bank) ││  (16KB,2-way)      │
        └──────────┘└──────────┘└──────────┬─────────┘
                                            │
                          ┌─────────────────┴────────────────┐
                          │                                  │
                  ┌───────┴────────┐                ┌────────┴────────┐
                  │ Compress Top   │                │ Decompress Top   │
                  │ (3 Engine ‖)   │                │ (algo_id 分发)   │
                  │ + Size Mux     │                │ + CRC Check      │
                  └───────┬────────┘                └────────┬────────┘
                          │                                  │
                          └─────────────┬────────────────────┘
                                        ▼
                              ┌──────────────────────┐
                              │  Space Allocator     │  ← Buddy + Free List
                              │  + GC Engine (Bg)    │
                              └─────────┬────────────┘
                                        │
                              ┌─────────┴────────┐
                              │ Response Merge   │
                              │ + Reorder Buffer │
                              └─────────┬────────┘
                                        │
                              To Scheduler (AXI-like) ← / → DDR
                                        │
                              APB / IRQ / Mailbox  ──→ SoC Bus

```

### 4.2 RTL 模块划分

```
cache_compress_top.sv                  // 顶层
├── req_buffer.sv                      // 请求缓冲,outstanding 跟踪
├── addr_decode.sv                     // Bypass / NCA 判定 + 地址区间寄存器
├── cache_pipe_ctrl.sv                 // 4 级流水主控
├── tag_ram.sv                         // Tag (Valid, Dirty, Tag, pLRU)
├── data_ram.sv                        // 4 Way × 32KB
├── mshr.sv                            // 8 项 MSHR + 同地址合并
├── l2p_meta_cache.sv                  // 16KB 2-way,Entry+PageHeader 共池
├── l2p_dma.sv                         // L2P miss 时从 DDR 取 entry
├── compress/
│   ├── compress_top.sv                // 三引擎并行 + Size Mux
│   ├── bdi_compress.sv
│   ├── zero_compress.sv
│   ├── bytedelta_compress.sv
│   └── line_crc8.sv                   // 压缩数据 CRC 生成
├── decompress/
│   ├── decompress_top.sv              // algo_id 分发 + CRC 校验
│   ├── bdi_decompress.sv
│   ├── zero_decompress.sv
│   ├── bytedelta_decompress.sv
│   └── crc_check.sv
├── alloc/
│   ├── space_alloc.sv                 // 页级 Buddy 分配
│   ├── free_list.sv                   // 多级 Free List + 碎片统计
│   └── gc_engine.sv                   // 后台 GC 状态机
├── reloc/
│   └── page_reloc.sv                  // 整页重定位流水
├── pressure_mon.sv                    // 容量水位监控 + IRQ 触发
├── resp_merge.sv                      // 响应合并 + ID 重排
├── perf_counter.sv                    // 性能计数器集合(~32 项)
├── apb_cfg.sv                         // APB 配置寄存器
└── ecc/
    ├── tag_ecc.sv                     // Tag/Data RAM 的 SECDED
    ├── data_ecc.sv
    └── meta_ecc.sv                    // Meta Cache 的 SECDED
```

---

## 5. Cache 设计

### 5.1 基本参数

| 参数 | 推荐值 | 说明 |
|------|--------|------|
| Cache 容量 | 64KB / 128KB / 256KB | 综合时配置,默认 128KB |
| Cache Line | 64 Byte | 对齐 AXI burst 与 LA 页内 Line 划分 |
| 组织 | 4-way 组相联 | 命中率/面积平衡点 |
| 替换策略 | Pseudo-LRU(3 bit/set) | 真 LRU 面积代价过高 |
| 写策略 | Write-Back + Write-Allocate | 配合压缩引擎,evict 时压缩 |
| Inclusive 关系 | None / DDR-side bandwidth cache | 不参与 Master 私有 Cache 一致性 |

### 5.2 Tag RAM 结构(以 128KB / 4-way / 64B Line / 40bit LA 为例)

```
总 Line 数 = 128 KB / 64 B = 2048
每 Way Line 数 = 2048 / 4 = 512
Index 位宽 = log2(512) = 9 bit
Offset 位宽 = log2(64) = 6 bit
Tag 位宽 = 40 - 9 - 6 = 25 bit

Tag Entry:
┌───────┬───────┬───────────┬──────────┬──────────┐
│ Valid │ Dirty │ Tag[24:0] │ pLRU[2:0]│ ECC[6:0] │
│ 1     │ 1     │ 25        │ 3        │ 7        │
└───────┴───────┴───────────┴──────────┴──────────┘
  = 37 bit/entry × 2048 entries ≈ 9.5 KB Tag RAM

注:pLRU 实际是 set 级而非 line 级,3 bit / set × 512 = 192 byte 单独存放,
    上式合并到 Tag Entry 仅作概算
```

### 5.3 Data RAM 组织

```
4 Way × 32 KB,每 Way 一块 SRAM,4 Way **同 cycle 并行读出**,
Tag 比较结果用作 way mux 选择 → Hit 路径 1 cycle 完成 Tag+Data 读取

为何不分 bank:
  - bank 化用于 Evict 写 / Fill 写并行,但本 IP Evict 走 compress 流水,
    与 Hit 路径自然解耦,无需牺牲 Hit 路径的并行 Way 读
  - SRAM 4 块独立比 1 块带 BW 接口面积小 ~3%,但 routing 简单

Data RAM 容量 = 128 KB,组织 = 4 SRAM × (512 Line × 64 B)
ECC 粒度 = 32 bit 数据 + 7 bit ECC(SECDED)
```

### 5.4 MSHR(Miss Status Holding Registers)

```
深度: 8 项(可配 4/8/16)

每项结构:
┌──────┬────────────┬────────┬──────────┬─────────┬─────────┐
│Valid │ Addr (Tag) │ State  │ ReqList  │ WayAlloc│ ReqType │
│ 1    │ 25         │ 4      │ 8 entry  │ 2       │ 2       │
└──────┴────────────┴────────┴──────────┴─────────┴─────────┘

State: IDLE → L2P_LOOKUP → EVICT_PEND → COMP_PEND
              → ALLOC_PEND → DDR_WRITE → FILL_REQ → FILL_DECOMP → DONE

ReqList: bitmap,挂载等待同地址 Miss 的最多 8 个请求(同地址合并)

功能:
  - 同地址 Miss 合并:多 Master 命中同 Line 只发一次 DDR 读
  - Outstanding Miss 跟踪
  - 防止重复 Evict(同 Set 多 Miss 串行)
  - **重定位序列化**:本地址有 reloc 在飞 → 后续请求阻塞至完成
```

### 5.5 L2P / Meta Cache(关键优化点)

为避免 Cache Miss 时串行两次 DDR 访问(先 L2P 后数据),做三层优化:

#### 5.5.1 容量与组织

```
容量: 16 KB(可配 8K/16K/32K)
组织: 2-way 组相联,Entry 64 byte
  - 8 个 L2P Entry(各 8B = 64B)合并存为 "L2P Block"
  - 缓存 16KB / 64B = 256 个 L2P Block = 2048 个 LA Page 的映射
  - 覆盖 8 MB 工作集(2048 × 4KB)
```

#### 5.5.2 Page Header 共池缓存

L2P Block 命中后,如果接下来需要读对应 PPA 页的 Page Header(176B),
将 Page Header 数据缓存在同一片 SRAM 的另一区段:

```
Meta Cache SRAM 16KB:
  ┌──────────────────────────┐ 0
  │  L2P Block Region (8KB)  │  256 个 L2P Block
  ├──────────────────────────┤ 8KB
  │  Page Header Region (8KB)│  Header 槽位对齐到 192B → 42 个 Page Header
  └──────────────────────────┘ 16KB

注:176B Header 槽位上对齐到 192B(便于 SRAM 寻址),8KB/192 = 42 个驻留 Header。
    若需更高 Header 命中率,可把 META_CACHE_SIZE 配到 32KB(Header 区 16KB → 85 个)。

预取策略:
  L2P Block hit + Cache Miss 触发时,Page Header DMA 与 Compressed Data DMA
  并行发起(地址相邻,DDR 端 Bank 命中率高)
```

#### 5.5.3 预取与替换

- L2P Block 替换:LRU
- Page Header 替换:跟随 L2P Block(同 LA Page 的 Header 优先驻留)
- 顺序访问检测:连续访问 LA_PageN, N+1, N+2 时预取 N+3 的 L2P Block

### 5.6 Cache Controller 流水线

```
Stage 1 (REQ):  请求接收,地址解码,Bypass 判定
Stage 2 (TAG):  Tag RAM 读取 + Hit 判定 + pLRU 更新
Stage 3 (DATA): Data RAM 读出(Hit) / MSHR 分配(Miss)
Stage 4 (RESP): 数据返回 / Miss 路径分流到 L2P → DDR

  ┌──────┐
  │ REQ  │ Cycle 1
  └──┬───┘
     ▼
  ┌──────┐
  │ TAG  │ Cycle 2 ── Hit ──→ 进入 DATA
  └──┬───┘                    Miss ──→ 阻塞等待 MSHR 处理
     ▼
  ┌──────┐
  │ DATA │ Cycle 3
  └──┬───┘
     ▼
  ┌──────┐
  │ RESP │ Cycle 4
  └──────┘

Hit 路径:4 cycle(包括 RESP 返回时序)
所有 Miss / Evict / 重定位走 MSHR 旁路,不阻塞主流水
```

### 5.7 主状态机(Miss/Evict/Reloc 路径)

```
                            ┌──────┐
                ┌──────────→│ IDLE │←─────────────────────────────┐
                │           └──┬───┘                              │
                │              │ 收到 Miss 请求                     │
                │           ┌──┴────────┐                         │
                │           │L2P_LOOKUP │ Meta Cache 查/读         │
                │           └──┬────────┘                         │
                │              │                                  │
                │       Miss   │   Hit                            │
                │              ▼                                  │
                │      ┌──────────────┐                           │
                │      │  L2P_DMA     │ DDR 读 L2P Block(可选)    │
                │      └──────┬───────┘                           │
                │             ▼                                   │
                │      需 Evict?                                   │
                │       ┌─────┴───────┐                           │
                │     Yes              No                         │
                │       ▼               ▼                         │
                │ ┌──────────────┐ ┌───────────────┐              │
                │ │ EVICT_RD     │ │ READ_HEADER   │ 取 Page Header│
                │ │ 读脏 Line    │ └───────┬───────┘              │
                │ └──────┬───────┘         ▼                      │
                │        ▼          ┌───────────────┐              │
                │ ┌──────────────┐  │ READ_LINE     │ 读压缩 Line  │
                │ │ EVICT_COMP   │  └───────┬───────┘              │
                │ │ 三引擎并行压缩│         ▼                      │
                │ └──────┬───────┘  ┌───────────────┐              │
                │        ▼          │ DECOMP        │ 解压 + CRC校验│
                │  Page 容量是否够? └───────┬───────┘              │
                │   ┌────┴────┐            ▼                      │
                │  Yes        No    ┌───────────────┐              │
                │   │         ▼     │ FILL_DATA_RAM │              │
                │   │   ┌──────────┐│ 同时返回首字  │              │
                │   │   │ ALLOC_NEW│└───────┬───────┘              │
                │   │   │ 申请新页 │        ▼                      │
                │   │   └────┬─────┘  ┌──────────┐                 │
                │   │        ▼        │ RESPONSE │                 │
                │   │   ┌──────────┐  └────┬─────┘                 │
                │   │   │ RELOC_WR │       │                       │
                │   │   │ 写新页     │       │                      │
                │   │   └────┬─────┘       │                       │
                │   ▼        │             │                       │
                │ ┌────────┐ │             │                       │
                │ │UPDATE_ │←┘             │                       │
                │ │L2P     │               │                       │
                │ └────┬───┘               │                       │
                │      └────────────────►──┘                       │
                └──────────────────────────────────────────────────┘
```

---

## 6. 压缩引擎设计

### 6.1 算法选型评估(基于 compress_eval.py + 加权分析)

#### 6.1.1 候选算法横向对比

| 算法 | 整体压缩率 | 空间节省 | 硬件延迟 | 面积开销 | 擅长场景 |
|------|-----------|---------|---------|---------|---------|
| BDI(Base-Delta-Immediate) | 1.25× | 20.3% | 2-3 cycle | 小 | 指针、递增、小整数 |
| Zero-Value | 1.35× | 25.9% | 1 cycle | 极小 | 稀疏、ReLU、padding |
| FPC | 1.42× | 29.7% | 3-5 cycle | 中 | 通用模式 |
| ByteDelta | 1.27× | 21.4% | 1-2 cycle | 小 | 图像、INT8 权重 |
| LZ4 HW | 2.0-3.0× | - | 10-50 cycle | 大 | 大块连续(延迟过高) |
| **BDI+Zero+ByteDelta(三引擎)** | **1.69×** | **41.0%** | **2-3 cycle** | **中** | **全场景** |

#### 6.1.2 各算法在数据类型上的对比

| 数据类型 | BDI | Zero | ByteDelta | 组合 Best | 胜出 |
|---------|-----|------|-----------|---------|------|
| 全零 | 64× | 64× | 64× | 64× | 均可 |
| 稀疏(15%) | 1.11× | 5.13× | 1.08× | 5.13× | Zero |
| 指针数组 | 1.73× | 1.00× | 1.83× | 1.83× | ByteDelta |
| 小整数数组 | 1.83× | 1.00× | 1.83× | 1.92× | BDI/ByteDelta |
| 结构体 | 1.00× | 4.27× | 1.01× | 4.27× | Zero |
| YUV 帧 | 1.00× | 1.00× | 1.16× | 1.16× | ByteDelta |
| INT8 NPU 权重 | 1.00× | 1.00× | 1.28× | 1.28× | ByteDelta |
| NPU 激活 | 1.01× | 2.24× | 1.00× | 2.24× | Zero |
| DMA 顺序 | 3.05× | 1.00× | 1.83× | 3.05× | BDI |
| RGB 帧缓冲 | 1.00× | 1.00× | 1.00× | 1.00× | 不可压 |
| 代码段 | 1.00× | 1.00× | 1.00× | 1.00× | 不可压 |
| 栈 | 1.00× | 1.34× | 1.00× | 1.34× | Zero |
| 加密/随机 | 1.00× | 1.00× | 1.00× | 1.00× | 不可压 |

#### 6.1.3 加权场景压缩率(关键补充)

未加权的 1.69× 假设各类数据等比例,**真实负载中并非如此**。本节给出三种典型 SoC workload 的加权估算:

**手机视频会议场景**:
| 数据类型 | 权重 | 单类压缩率 |
|---------|------|-----------|
| YUV 编解码缓冲 | 30% | 1.16× |
| RGB 显示缓冲 | 20% | 1.00× |
| 代码 + 栈 | 15% | 1.10× |
| 应用堆数据 | 25% | 2.00×(混合) |
| 加密通道 | 10% | 1.00× |
| **加权综合** | | **≈ 1.32×** |

**车机 ADAS 场景**:
| 数据类型 | 权重 | 单类压缩率 |
|---------|------|-----------|
| ISP 帧 RAW/YUV | 25% | 1.20× |
| NPU 权重 INT8 | 30% | 1.28× |
| NPU 激活 | 20% | 2.24× |
| 中间结果 + 栈 | 15% | 1.50× |
| 代码 + RGB | 10% | 1.00× |
| **加权综合** | | **≈ 1.51×** |

**AIoT 推理服务器**:
| 数据类型 | 权重 | 单类压缩率 |
|---------|------|-----------|
| 模型权重 INT8/FP16 | 50% | 1.40× |
| 激活/中间张量 | 30% | 2.50× |
| KV-Cache | 10% | 1.80× |
| 系统/控制 | 10% | 1.20× |
| **加权综合** | | **≈ 1.78×** |

> **结论**:1.5× 容量申报对车机/AIoT 安全,对手机偏激进(需开启 SOFT_HIGH 提前压力反馈)。出厂时按目标场景 strap 配置 CapRatio。

#### 6.1.4 真实 trace 验证计划(Phase 0)

仅靠 compress_eval.py 的合成 pattern 不足以覆盖真实场景。Phase 0(RTL 启动前)的工具链与方案见
[docs/01_phase0_trace_eval.md](docs/01_phase0_trace_eval.md),要点:

- gem5 全系统仿真生成实际 workload 的 DDR trace(SPEC CPU 2017、MLPerf Tiny、Geekbench)
- 把 trace 喂入 [tools/compress_eval.py](tools/compress_eval.py),得到压缩率分布(均值 + p1 + p50 + p99)
- 验证 1.5× 申报的 99% 安全性
- 输出 BYPASS_CFG 推荐 + CapRatio strap 决策

**Mock 数据示范报告**:[docs/01b_phase0_eval_report_demo.md](docs/01b_phase0_eval_report_demo.md)。
该示范揭示:合成数据普遍低估实际压缩率,**真 trace 评估是 RTL 启动的硬约束**。

**Fixed-Slot 方案评估结论:不推荐**(保留原结论)

| Slot | 压缩率 | 空间节省 |
|------|--------|---------|
| 32B | 1.09× | 8.4% |
| 40B | 1.13× | 11.8% |
| 48B | 1.09× | 8.0% |

Fixed-Slot 收益过低(最高 11.8%),且**容量扩展器场景下意义更小**(变长才有真扩容价值)。

### 6.2 BDI 算法原理

```
原始 64B Cache Line (16 × 32 bit words):
  W0=1000, W1=1002, W2=1001, W3=1003, ...

BDI 压缩:
  1. Base = W0 = 1000
  2. Delta[i] = W[i] - Base → all ≤ 4 → 1 byte 表示
  3. 压缩结果: Base(4B) + 16 × Delta(1B) = 20 B(3.2× 压缩比)

编码格式:
  ┌──────┬──────┬──────────────────────────┐
  │Mode  │Base  │Delta[0..15]              │
  │3 bit │4 / 8B│1B/2B/4B 各模式不同        │
  └──────┴──────┴──────────────────────────┘

8 种模式:
  Mode 0: 全零        → 0 B
  Mode 1: 单值重复    → 4 B
  Mode 2: B(4)+D×16(1B) → 20 B
  Mode 3: B(4)+D×16(2B) → 36 B
  Mode 4: B(8)+D×8(1B)  → 16 B
  Mode 5: B(8)+D×8(2B)  → 24 B
  Mode 6: B(8)+D×8(4B)  → 40 B
  Mode 7: 不可压        → 64 B
```

### 6.3 ByteDelta 算法原理

针对 byte 粒度数据(图像像素、INT8 权重)的补充压缩。BDI 按 32bit word 做 delta,对 byte 级规律无效;ByteDelta 填补这一盲区。

```
6 种模式:
  Mode 0: 全零             → 1 B
  Mode 1: 单 byte 重复     → 2 B
  Mode 2: B(1)+4bit×63     → 34 B(相邻 byte 差 ≤ ±7)
  Mode 3: B(2)+8bit×31     → 34 B(16bit word 级)
  Mode 4: B(4)+16bit×15    → 35 B(32bit word 级)
  Mode 5: 不可压            → 64 B

典型场景:
  YUV 帧:相邻像素 Y 差 ≤ ±3 → 4bit delta → 34 B (1.88×)
  INT8 权重:集中 center±10 → 相邻 delta 小 → 34 B (1.88×)
```

### 6.4 三引擎并行压缩架构

```
                    Cache Line (64 B)
                          │
            ┌─────────────┼─────────────┐
            ▼             ▼             ▼
     ┌────────────┐┌─────────────┐┌─────────────┐
     │ BDI Engine ││ Zero Engine ││ ByteDelta   │
     │ 2-3 cyc    ││ 1 cyc       ││ Engine      │
     │            ││             ││ 1-2 cyc     │
     └─────┬──────┘└──────┬──────┘└──────┬──────┘
           │              │              │
           ▼              ▼              ▼
     ┌────────────────────────────────────────────────┐
     │ Size Comparator + Tie Breaker                  │
     │   选最小压缩结果,大小相同时按 algo 优先级:       │
     │     Zero > ByteDelta > BDI(解压延迟优先)       │
     │   输出: {algo_id[1:0], comp_data, size,        │
     │           mode, crc8}                          │
     └─────────────────────┬──────────────────────────┘
                           ▼
                ┌─────────────────────┐
                │ Line CRC Generator  │ 8 bit CRC,用于解压侧检错
                └─────────┬───────────┘
                          ▼
                    压缩数据 + 元数据输出

总延迟: 3-4 cycle(三引擎并行 max + Comparator + CRC)

algo_id 编码:
  00 = BDI / 01 = Zero / 10 = ByteDelta / 11 = Uncompressed(原始 64B 直通)
```

### 6.5 解压引擎

```
                压缩数据 + algo_id + crc8
                         │
                ┌────────┴────────┐
                │  CRC Check       │ ← 校验失败触发 IRQ_DECOMP_ERROR
                └────────┬────────┘
                         │
                  algo_id[1:0]
                         │
                ┌────────┼────────┐
                ▼        ▼        ▼
         ┌──────────┐┌──────┐┌──────────┐
         │ BDI Dec  ││ Zero ││ByteDelta │
         │ 1-2 cyc  ││ 1 cyc││ 1-2 cyc  │
         └────┬─────┘└──┬───┘└────┬─────┘
              │         │         │
              ▼         ▼         ▼
         ┌──────────────────────────────┐
         │  MUX(by algo_id)             │
         └──────────────┬───────────────┘
                        ▼
                  原始 64 B 数据

总延迟: 2-3 cycle(包括 CRC 校验 1 cycle)
未选中引擎 clock gate
```

### 6.6 Critical-Word First 优化

由于压缩破坏了字粒度对齐,默认无法做 CWF。但本设计采用一个折衷:

- **解压完成立即整 Line forward**:解压只需 1-2 cycle,几乎不增加首字延迟
- **Hit 路径仍可 CWF**:Cache Hit 时数据未压缩,Master 请求字 mask 直接驱动 Data RAM 读出

### 6.7 算法组合选型:为何 ByteDelta 而非 FPC(待 Phase 0 实测确认)

§6.1.1 显示 FPC 单算法压缩率 1.42×(高于 ByteDelta 的 1.27×),却未入三引擎组合。理由与待验证项:

| 维度 | ByteDelta | FPC |
|------|-----------|-----|
| 硬件延迟 | 1-2 cycle | 3-5 cycle(模式匹配多) |
| 与 BDI/Zero 的覆盖**互补性** | 高:补 byte 粒度(YUV/INT8),BDI/Zero 不擅长 | 中:FPC 的常见模式与 BDI(小整数)/Zero(零)**重叠**,边际增益低 |
| 面积 | 小 | 中 |
| **组合边际增益** | 在 BDI+Zero 之上补 YUV/INT8 这一大类 | 在 BDI+Zero 之上多覆盖的模式有限(被前两者吃掉) |

> **选型逻辑**:三引擎看的不是单算法最高分,而是**组合覆盖的正交性**。ByteDelta 吃下了 BDI/Zero 的盲区(byte 级规律,占车机/手机 workload 比重大),FPC 的强项与 BDI/Zero 重叠。
> **待办(Phase 0)**:用真 trace 实测 `BDI+Zero+ByteDelta` vs `BDI+Zero+FPC` vs 四引擎全开的加权压缩率/面积/延迟,数据落地后回填本节。当前结论为基于模式覆盖的工程判断,非实测定论。

### 6.8 高价值场景的可选增强:页内去重 / 小窗口 LZ(探索)

AIoT(加权 1.78×,激活张量可达 2.5×)与 KV-Cache 的潜在收益,当前 64B 行内算法吃不满——它们都是**跨行**冗余(整页重复块、权重分块相似)。LZ4 因 10-50 cycle 延迟被排除在**读关键路径**外,但:

- **容量扩展是 P0,延迟可被 Cache 隐藏**:命中即不解压;只有 Miss 才付解压延迟。对"冷数据/权重常驻"这类高命中后低频访问的页,用一个**页内(4KB)小窗口 LZ 或块去重层**做"第二级压缩",值得评估。
- 形态:三引擎做第一级(低延迟,保证最坏情况),对压缩后仍 >某阈值且访问频率低的页,后台 GC 时叠加第二级 LZ;读 Miss 命中第二级页时走慢速解压路径(可接受,因低频)。
- 风险:增加一类解压路径与 reloc 复杂度;需 Phase 0 量化 AIoT 场景第二级的额外收益是否 >15%(否则不值)。

> 定位为 **Phase 5 可选增强**,不进基线;在此登记为明确的优化方向。

### 6.9 与原文档的差异

- 修正了"解压 1-2 cycle"的乐观估计 → 实际 2-3 cycle(含 CRC 校验)
- 新增 Tie Breaker 优先级(Zero > ByteDelta > BDI),解压延迟最低的算法优先
- 新增 Line CRC8,用于检测压缩数据 bit flip(详见 §10.2)

---

## 7. 空间管理(Space Allocator + GC)⭐

> 容量扩展器的难点不在压缩本身,而在**空间分配 + 写更新 + 碎片**。本章详细设计这三件事。

### 7.1 PPA 空间分配器:Buddy + Slab 二级

#### 7.1.1 分配粒度选择

```
观察:压缩后页大小分布(实测):
  0~128B   : 5%(全零页)
  128~512B : 12%
  512~1KB  : 25%
  1~2KB    : 30%
  2~3KB    : 18%
  3~4KB    : 8%
  >4KB     : 2%(退化为 Uncompressed)

分配粒度方案:
  - 64B 对齐(Cache Line 粒度)
  - Buddy 树:从 64B 到 4KB 共 7 级(64/128/256/512/1K/2K/4K)
  - 对最常见的 1~3KB 区段提供 Slab 优化(预切片缓存)
```

#### 7.1.2 Buddy 树结构

```
Free List Tree(存于 DDR 元数据区,16 MB):
┌──────────────────────────────────────────────┐
│ Level 0 (4KB block):  1M bits = 128 KB       │  每 bit 标记一个 4KB 槽是否空闲
│ Level 1 (2KB block):  2M bits = 256 KB       │
│ Level 2 (1KB block):  4M bits = 512 KB       │
│ Level 3 (512B block): 8M bits = 1 MB         │
│ Level 4 (256B block): 16M bits = 2 MB        │
│ Level 5 (128B block): 32M bits = 4 MB        │
│ Level 6 (64B block):  64M bits = 8 MB        │
└──────────────────────────────────────────────┘

片上 Allocator Cache:
  - 每 Level 缓存 256 个 free block 索引
  - 分配命中 Cache → 1 cycle 完成
  - Cache miss → 后台 DMA 从 DDR 读取 bitmap 段
```

#### 7.1.3 Slab 优化

针对 1~3KB 段(占总分配的 73%),维护 4 个 Slab Pool:
- 1KB Slab:32 项预切空闲块
- 1.5KB Slab:32 项
- 2KB Slab:32 项
- 3KB Slab:32 项

每个 Slab Pool 由 GC 线程在低水位时预填充。

### 7.2 写流程详细图

```
Master 写 LA 地址 → Cache 查
   │
   ▼
 Cache Hit?  ──Yes──→ 写 Data RAM,标记 Dirty,1 cycle 完成
   │
   No
   ▼
 Write-Allocate(Read for Ownership):
   1. 取 LA 页(走 Miss 路径,见 §8.2)
   2. Fill 到 Cache,标记 Dirty
   3. 写入新数据
   注:这里不立即压缩。压缩发生在 Evict 时

Evict 触发:
   1. 从 Cache 读出脏 Line(64B)
   2. 三引擎并行压缩 → comp_data, comp_size, algo_id
   3. 查 L2P:获取该 LA 页的旧 PPA Ptr 和原 Line size
   4. 决策:
      a) 旧 size ≥ 新 size → 原位写入,记录 free_size 差额到 GC 队列
      b) 旧 size < 新 size 但页内仍有空闲 → 在页尾追加,更新 Page Header offset
      c) 页内空间不足 → 触发整页重定位(§7.3)
   5. 更新 Page Header(Line Info Array 中本 Line 的 size/offset/algo)
   6. 写 DDR

注:Page Header 更新可能很频繁(每次 Line evict),需要 Header Write Cache 合并多次更新
```

### 7.3 整页重定位流水

> **详细 9 状态 FSM、MSHR 抢占协议、5 种异常路径、4 种时序图见
> [docs/03_page_reloc_fsm.md](docs/03_page_reloc_fsm.md)**。本节给概要。

```
触发条件:Evict 后页内空间不足 / WriteFail / GC 触发 / Header CRC 修复

9 状态 FSM:
  S_IDLE → S_LOCK → S_COLLECT_PLAN → S_COLLECT_FETCH ⇄ S_RECOMP →
  S_ALLOC → S_WRITE_NEW → S_COMMIT → S_DONE

抢占规则:
  - GC 触发的 Reloc 可被业务请求抢占(每状态有抢占检查点)
  - Evict / WriteFail / HeaderRepair 触发的 Reloc 不可抢占

总延迟:典型 250 cycle(p50),≤ 500 cycle(p99)
同 LA 页阻塞时间:≤ 1 μs(800 cycle 上限)
频率:< 1% / Evict(在典型 workload 下,需 Phase 0 评估实测)

异常路径:
  - S_ALLOC 失败 → IRQ_HARD_FULL → 等 OS;OOM_TIMEOUT 后 SLVERR
  - S_COLLECT 时 CRC 错 → 重读;仍错 → 单 Line 标记 Error + IRQ_DECOMP_ERR(读该 Line 返回 SLVERR,禁止静默零填充)
  - S_WRITE_NEW DDR 错 → 重试;仍错回滚 L2P 不动
  - S_COMMIT L2P 错 → 重试;仍错进入 SAFE_MODE
  - 超时 watchdog → 强制回滚 + 标记坏页
```

### 7.4 GC(Garbage Collection)

#### 7.4.1 GC 类型

1. **Hole GC**:回收原位写入产生的 free 空隙(大小不变的小片)
2. **Compaction GC**:页内空闲过多(>20%)时整页重写紧凑
3. **Defrag GC**:Buddy 树高级别块不足时合并低级别空闲块

#### 7.4.2 GC 调度

```
后台 GC 线程(独立硬件 FSM):
  - 触发:
    * SOFT_LOW 水位(≥80%)
    * Allocator 高级别空闲不足
    * 显式驱动命令
  - 限速:
    * GC DDR 带宽 ≤ 总带宽 5%(可配)
    * 优先级低于业务请求
  - 抢占:
    * 任何阶段可被 EVICT/RELOC 抢占,GC 状态机保存进度
```

#### 7.4.3 GC Bitmap

```
4 MB Bitmap,每 4KB PPA 对应 1 bit:
  0 = 完全空闲(可分配)
  1 = 已分配

子图(每页 4 bit):
  hole_ratio[3:0]: 该页空闲字节占比的 16 级量化
                   GC 优先选择 hole_ratio ≥ 4(>25% 空闲)的页做 Compaction
```

### 7.5 写带宽模型(写放大 WAF)⭐

> **本节是 §1.2 "写带宽节省 ≥25%" 这条 P0 指标能否兑现的根。**
> 旧版(v2.0)曾把 Page Header 写按"每条 Line evict 一次"计入,得 WAF≈3.22 —— 这与"省带宽"自相矛盾。
> 根因是 Header 写其实在多次同页 evict 间被 **Header Write Buffer** 合并;必须按"每页摊销"建模。

#### 7.5.1 关键参数

| 符号 | 含义 | 取值 |
|------|------|------|
| `L`  | 压缩 Line 平均字节(原 64B) | 32B(=综合压缩率 ~1.7× 反推每行 ~38B,保守取 32~40) |
| `H`  | Page Header 字节 | 176B(§3.2.3) |
| `k`  | **Header 合并因子**:一次 Header 写覆盖的同页 dirty line evict 数 | 取决于空间局部性与 Header Write Buffer(§02 §6.2),典型 6~16 |
| `f`  | **Reloc 频率 / Evict**(§7.3) | 目标 <1%,理想 ~0.1% |
| `P`  | Reloc 全页写字节(含新 Header) | ~2.4KB + 176B ≈ 2576B |

#### 7.5.2 写流量分解(归一化到"原始一次 64B 写")

```
每次 Evict 产生的 DDR 写字节:
  原位写(概率 1-f): L          压缩 Line
                   + H/k       摊销的 Header 写(k 次 evict 共享 1 次 Header 写)
  重定位(概率 f):   P          全页重压缩重写(含 Header)

WAF_write = [ (1-f)·(L + H/k) + f·P ] / 64

注:Write-Allocate 的"读原 Line + 读 Header"属于读放大,不计入写 WAF(见 §7.5.4)。
```

#### 7.5.3 敏感性(L=32B, H=176B, P=2576B)

| f (Reloc/Evict) | k=1(无合并) | k=8 | k=16 | 结论 |
|------|------|------|------|------|
| 1.0% | 3.62 | 1.24 | 1.07 | **达不到省带宽**:即使 k=16 仍 ≥1.0 |
| 0.5% | 3.40 | 1.04 | 0.88 | k=16 才勉强省 12% |
| 0.1% | 3.22 | 0.87 | 0.71 | **k≥12 且 f≤0.1% 才能省 ≥25%** |

> **诚实结论(取代旧版 "≈30%")**:
> - **Header 合并(k)与 Reloc 频率(f)是写带宽收益的两个生死参数。**
>   只压缩 Line(32B)省下的 32B,会被 Header 写(176/k)与 Reloc 全页写(f·2576)吃掉。
> - 收支平衡需 `H/k < 32` → **k > 5.5**;达到 25% 节省需 **k ≥ 12 且 f ≤ 0.1%**(见表)。
> - **行动**:k 和 f 都不是设计自由量,而是 workload 相关的实测量。
>   - k:由 Header Write Buffer 命中率决定 → Phase 0 评估器需输出"同页 dirty line 在合并窗口内的平均聚集数"。
>   - f:由写覆盖后压缩 size 变化分布决定 → Phase 0 评估器需输出 Reloc 频率(见 [docs/01](docs/01_phase0_trace_eval.md) §6 + [tools/compress_eval.py](tools/compress_eval.py) 的有状态重放)。
> - **若 Phase 0 实测 k<12 或 f>0.1%**:§1.2 的"写带宽节省 ≥25%"需下调为 P1 软目标,容量扩展(P0)仍成立——本 IP 的 P0 价值是**容量**,带宽节省是叠加收益。

#### 7.5.4 读放大(单独记账)

```
Read Miss + Write-Allocate 的读 DDR 流量:
  读 L2P(8B,通常命中 Meta Cache → 0)
  读 Page Header(176B,可能命中 Meta Cache)
  读原 Line 压缩数据(avg 32B)
→ 读节省靠"压缩后 Line 更小"+ "Cache 命中免 DDR 读";
  §1.2 的读带宽节省 15% 主要由命中率(70%)贡献,压缩贡献为辅。
```

---

## 8. 数据通路时序

> 所有时序假设 800MHz 时钟,DDR4 单次访问 80 ns ≈ 64 cycle

### 8.1 Read Hit(最优路径)

```
Cycle 1: Master 请求到达 Request Buffer
Cycle 2: Tag RAM 读取 + 4-Way Tag 比较
Cycle 3: Way Mux 选择 + Data RAM 输出(并行 Way 读)
Cycle 4: 数据返回 Master

总延迟: 4 cycle,零 DDR 访问
```

### 8.2 Read Miss(最常见路径,L2P Cache 命中)

```
Cycle 1-4:   Tag Miss 流水(同 Hit 流水但末端分流到 MSHR)
Cycle 5:     MSHR 分配
Cycle 6-7:   L2P Cache 查询(命中,2 cycle 含 SRAM 读)
Cycle 8:     发 DDR 命令(读 Page Header + Line 压缩数据,合并发起)
Cycle 8+64:  Page Header 返回(假设无 L2P 表读)
Cycle 8+64:  压缩 Line 返回(同 burst,Bank 命中)
Cycle 73-75: CRC 校验 + 解压
Cycle 76:    Fill Data RAM + Forward 给 Master(整 Line forward,无 CWF)

总延迟: ~76 cycle
裸 DDR 延迟: ~64 cycle
开销: ~12 cycle (+19%)
```

### 8.3 Read Miss(L2P Cache 未命中)

```
新增阶段(在 Cycle 6-7 后):
Cycle 8:     L2P 表 DDR 读发起
Cycle 72:    L2P Block 返回(64B,8 个 Entry)
Cycle 73:    Page Header DDR 读发起
Cycle 137:   Page Header 返回
Cycle 138:   Compressed Line DDR 读发起
Cycle 202:   Line 返回
Cycle 203-205: 解压
Cycle 206:   Fill + Forward

总延迟: ~206 cycle
裸 DDR: ~64 cycle
开销: ~140 cycle (+220%)
```

> **优化**:Page Header 与 Compressed Line 在地址相邻 → DDR Bank 命中 → 实际 ~140 cycle。

#### 8.3.1 三跳串行的根本问题与基线缓解 ⭐

L2P → Header → Line 是**指针追逐式串行 DDR 访问**,三跳全 miss 时 +220%,远超 §1.2 的 "Miss 开销 ≤30%(P1)"。
该指标只在 Meta Cache 命中时成立,因此**有效 Miss 延迟由 Meta Cache 命中率 `h` 决定**:

```
有效 Miss 延迟 ≈ h·(76 cycle, L2P+Header 命中)
              + (1-h)·(140~206 cycle, 需 DDR 取 L2P/Header)

相对裸 DDR(64 cycle)的开销:
  h=95%:  0.95×76 + 0.05×170 ≈ 81 cycle → +27%   ✓ 达标
  h=85%:  0.85×76 + 0.15×170 ≈ 90 cycle → +41%   ✗ 超标
  h=70%:  0.70×76 + 0.30×170 ≈ 104 cycle → +63%  ✗ 严重超标
```

> **结论**:30% 的 Miss 开销目标**强依赖 Meta Cache 命中率 ≥95%**,而 §16 此前假设的是 85%。
> 这两者矛盾,必须三选一:(a) 把 Meta Cache 命中率目标抬到 95%(加大 META_CACHE_SIZE / 改善预取);
> (b) 把 §1.2 的 Miss 开销目标放宽到 +40%;(c) 用下述并行预取把"3 跳串行"压成"近 1 跳"。

#### 8.3.2 基线设计:L2P+Header+Line 并行/链式预取(从 Phase 2 提前)

原方案把该优化放在 Phase 2;鉴于 8.3.1 的延迟账,**改为 Phase 1/2 基线**:

```
- L2P Block 返回后,其 PPA Ptr 立即可算出 Header 地址与 Line 区段起始;
  Header 与 Line(乃至整页前若干 Line)可在同一 DDR 突发/相邻 Bank 内一次性预取,
  把"Header 返回后才发 Line"的第 3 跳折叠掉。
- 顺序访问检测(§5.5.3)命中时,预取下一页 L2P Block,把第 1 跳也隐藏。
- 目标:L2P miss 路径从 ~206 → ~140 cycle(省掉 Header→Line 的串行 64 cycle)。
```

> Phase 0 评估器需补 Meta Cache 命中率模型(见 §14 与 [docs/01](docs/01_phase0_trace_eval.md))以标定 `h`,这是 Miss 延迟达标与否的输入参数。

### 8.4 Read Miss + Evict 脏行

```
在 §8.2 流水基础上,Cycle 5(MSHR 分配)同时启动 Evict:
Cycle 5-6:   选 Victim(脏行) + 读出
Cycle 7-9:   三引擎压缩 + Tie Break
Cycle 10:    查 L2P 旧 PPA / Size,决策原位/重定位
Cycle 11:    写 DDR(原位:1 cycle 命令;重定位:见 §7.3)
            (Evict 写不阻塞 Fill 读,二者可 pipeline)

Read Miss 流水正常进行,Evict 写在后台完成

总延迟: ~76 cycle(Read Miss 主导)
注:若 Evict 触发整页重定位,新写阻塞 100-300 cycle,但被 reloc 抢占的读不阻塞
```

### 8.5 Write Hit

```
Cycle 1:     请求接收
Cycle 2:     Tag Hit 判定
Cycle 3:     写 Data RAM + Mark Dirty

总延迟: 3 cycle,零 DDR 访问
```

### 8.6 Write Miss(Write-Allocate)

```
等同 Read Miss + 写 Cache,延迟 ~76 cycle
```

### 8.7 大事务穿透处理

AXI 单笔可达 256 byte / 512 byte burst,跨多个 Cache Line。

```
策略:
  1. Request Buffer 接收时按 64B Line 边界拆分
  2. 拆分后的子请求各自经过 Cache 流水线(Hit/Miss 独立判定)
  3. ID 透传 + Reorder Buffer 保证响应顺序
  4. 所有子请求返回后合并响应

性能影响:
  - 全 Hit:总延迟 = 4 cycle + (N-1) × 1 cycle(流水线背靠背)
  - 全 Miss:并行发 N 个 DDR 读,DDR 端 Row 命中可减少延迟
```

### 8.8 时序总结

| 路径 | 典型延迟 | 备注 |
|------|---------|------|
| Read Hit | 4 cycle | 零 DDR |
| Write Hit | 3 cycle | 零 DDR |
| Read Miss(L2P 命中) | ~76 cycle | 裸 DDR + 19% |
| Read Miss(L2P 未命中) | ~140-200 cycle | 加一次 DDR 读 |
| Read Miss + Evict 原位 | ~76 cycle | Evict 后台 |
| Read Miss + Evict 重定位 | ~300 cycle | 大延迟事件,频率 <1% |
| 整页 Reloc(独立触发) | 100-300 cycle | 阻塞同 LA 页访问 |

---

## 9. 接口定义

> **完整 ABI 规范见 [docs/04_os_driver_abi.md](docs/04_os_driver_abi.md)**:
> MMIO 寄存器映射、4 中断协议、Mailbox 4KB 双向 ring、消息 payload 格式、错误码、性能计数器、sysfs/debugfs 接口、时序约束、兼容性策略、与 OS 团队的评审清单。
> 主文档本章只列接口骨架。

### 9.1 上游接口(From Arbiter,标准 AXI4)

完整 5 通道(AR / R / AW / W / B):

```verilog
// AR Channel (Read Address)
input  wire                 ar_valid,
output wire                 ar_ready,
input  wire [ID_W-1:0]      ar_id,
input  wire [ADDR_W-1:0]    ar_addr,
input  wire [7:0]           ar_len,
input  wire [2:0]           ar_size,
input  wire [1:0]           ar_burst,
input  wire [3:0]           ar_cache,    // AXI cache attr
input  wire [2:0]           ar_prot,
input  wire [3:0]           ar_qos,
input  wire [3:0]           ar_region,
input  wire                 ar_lock,

// R Channel (Read Data)
output wire                 r_valid,
input  wire                 r_ready,
output wire [ID_W-1:0]      r_id,
output wire [DATA_W-1:0]    r_data,
output wire [1:0]           r_resp,      // OKAY / SLVERR(压力 / CRC 错)
output wire                 r_last,

// AW Channel (Write Address)
input  wire                 aw_valid,
output wire                 aw_ready,
input  wire [ID_W-1:0]      aw_id,
input  wire [ADDR_W-1:0]    aw_addr,
input  wire [7:0]           aw_len,
input  wire [2:0]           aw_size,
input  wire [1:0]           aw_burst,
input  wire [3:0]           aw_cache,
input  wire [2:0]           aw_prot,
input  wire [3:0]           aw_qos,

// W Channel
input  wire                 w_valid,
output wire                 w_ready,
input  wire [DATA_W-1:0]    w_data,
input  wire [DATA_W/8-1:0]  w_strb,
input  wire                 w_last,

// B Channel
output wire                 b_valid,
input  wire                 b_ready,
output wire [ID_W-1:0]      b_id,
output wire [1:0]           b_resp,      // OKAY / SLVERR
```

### 9.2 下游接口(To Scheduler)

与上游对称,但 `ID` 空间扩展(本 IP 内部生成的 Evict / Reloc / GC 请求需独立 ID,不与 Master ID 冲突):

```verilog
// 下游 ID 划分:
//   bits[N-1:N-3] = 000  → 直通 Master ID
//   bits[N-1:N-3] = 100  → Evict 请求
//   bits[N-1:N-3] = 101  → Reloc 请求
//   bits[N-1:N-3] = 110  → GC 请求
//   bits[N-1:N-3] = 111  → L2P / Meta DMA
```

### 9.3 APB 配置接口

| Offset | 寄存器 | RW | 说明 |
|--------|--------|----|------|
| 0x00 | CTRL | RW | bit0: Cache_en; bit1: Compress_en; bit2: GC_en; bit3: Pressure_irq_en |
| 0x04 | CAP_RATIO | RW | bits[7:0] = 申报容量比例 × 100(125 / 150 / 175 / 200) |
| 0x08 | FLUSH | W | bit0: Trigger flush; bit1: Trigger invalidate |
| 0x0C | STATUS | R | bit0: Flush_done; bit1: Pressure_active; bit3:2: Power state |
| 0x10 | BYPASS_CFG[0..7] | RW | 8 个 bypass 区间(每个 16 字节寄存器:start / end / attr) |
| 0x90 | PRESSURE_THRESH | RW | SOFT_HIGH / SOFT_LOW / HARD_FULL 阈值 |
| 0xA0 | PERF_CTRL | RW | 性能计数器 enable / reset |
| 0xB0~ | PERF_CNT[0..31] | R | 性能计数器值 |
| 0xC0 | DBG_TRACE_CTRL | RW | trace 触发条件配置 |
| 0xD0 | INT_STATUS | RW1C | bit0:Pressure / bit1:HardFull / bit2:DecompErr / bit3:GC_done |
| 0xD4 | INT_MASK | RW | 中断屏蔽 |
| 0xE0 | L2P_BASE | RW | L2P 表在 DDR 中的基址(由 BootROM 设置) |
| 0xE4 | META_BASE | RW | 元数据区基址 |

### 9.4 中断

| 中断 | 触发条件 | 优先级 | 期望响应 |
|------|---------|-------|---------|
| `IRQ_PRESSURE` | PPA 占用 ≥ SOFT_HIGH | 中 | OS 主动 swap/drop,目标 1ms 内 |
| `IRQ_HARD_FULL` | PPA 占用 ≥ HARD_FULL | 高 | OS 必须 10ms 内释放,否则新写返回 SLVERR |
| `IRQ_DECOMP_ERR` | 解压 CRC 失败 | 高 | OS 隔离地址 + 标记错误页 |
| `IRQ_GC_DONE` | GC 完成一轮 | 低 | 性能日志 |
| `IRQ_PERF_OVERFLOW` | 性能计数器溢出 | 低 | 驱动累加到软件计数器 |

### 9.5 OS Mailbox(共享 SRAM 4KB)

用于驱动与 IP 间的批量数据交换:
- 压力反馈时,IP 写入"建议释放的 LA 页列表"(基于 LRU + 压缩率劣化)
- 驱动写入"已释放的 LA 页列表",IP 据此回收 PPA 空间
- 性能日志环形缓冲:每 1ms 一条记录(命中率、压缩率、各算法分布)

---

## 10. 可靠性与安全

### 10.1 ECC 保护

| 存储 | ECC 方案 | 覆盖范围 |
|------|---------|---------|
| Tag RAM | SECDED(Hamming 39,32) | Valid / Dirty / Tag |
| Data RAM | SECDED(每 32bit + 7 bit) | 全部数据 |
| Meta Cache(L2P + PageHeader) | SECDED | L2P Entry / Header |
| MSHR / 内部缓冲 | Parity(单 bit 检错) | 关键状态字段 |
| DDR 元数据(L2P 表 / Bitmap) | DDR 内置 ECC + 软件 CRC32(关键字段) | 双层防护 |
| 压缩数据 Line | 8 bit CRC(Page Header 内每 Line) | bit flip 检测 |

### 10.2 压缩数据 CRC 链路

```
压缩侧:
  Line 压缩 → CRC8(comp_data) → 写入 Page Header 的 Line Info(8 bit)

解压侧:
  读 Page Header → 取出 stored_crc8
  读 comp_data → 计算 calc_crc8
  比较:
    一致 → 正常解压
    不一致 → 触发 IRQ_DECOMP_ERR + r_resp = SLVERR
            可选:重读一次(防 DDR 偶发软错误)
            仍错 → 上报地址给 OS,标记 LA 页损坏
```

### 10.3 安全内存交互

```
检测加密内存(MTE / SME / CCA / TrustZone):
  方法 1:静态(BootROM 配置)
    - 通过 BYPASS_CFG 寄存器把加密内存区间标记为 "no-compress"
    - 该区间走 Bypass 路径,不经压缩,只过 Cache(可选)

  方法 2:动态(AXI prot 信号)
    - aw_prot[1] = Secure(0)/Non-Secure(1)
    - 可配置:Secure 事务全 bypass / 走 cache 但不压缩 / 正常处理

为何加密数据不可压缩:
  - 加密后熵接近随机,压缩率 1.0×(浪费功耗)
  - 部分加密方案(如 AES-XTS)要求块对齐写,变长压缩破坏对齐
```

### 10.4 故障与降级路径

| 故障 | 检测 | 降级动作 |
|------|------|---------|
| Tag/Data RAM 双 bit 错 | ECC 报告 | 该 way 标记不可用,降级为 (N-1)-way |
| 解压 CRC 错(可重试) | CRC 比较 | 重读一次 + 软错误计数 |
| 解压 CRC 错(持久) | 重试仍错 | LA 页 Permanent Error,IRQ_DECOMP_ERR |
| L2P 表损坏(单副本) | 软件 CRC32 | **先尝试从备副本恢复(§10.7)**;两副本均坏才整 IP Bypass + 告警 |
| 全局压缩率持续劣化 | Pressure 监控 | OS 协同 swap;严重时申请扩容比下调 |
| GC 卡死 | Watchdog | 强制重置 GC 状态机,继续业务 |

### 10.5 一键 Bypass

任何上述持久性故障下,通过 APB CTRL.bit0=0 即可关闭 Cache,所有事务直通 DDR(地址不再压缩,需要先 Flush + 反压缩到对齐布局,见 §11.3)。

### 10.6 压缩侧信道(安全边界声明)⭐

压缩比**数据相关**:压缩后 size、容量水位、Reloc 时序都随明文内容变化,构成经典压缩预言机(CRIME 类)侧信道。在多 Master 共享场景下:

- 一个 Master 可通过观测**全局容量水位 / 自身可分配空间 / 访问延迟尖刺(Reloc)**,推断另一安全域数据的可压缩性,进而做内容猜测。
- §10.3 的"加密内存 bypass"只消除了"对加密数据做无用压缩",**并不消除非加密但敏感数据的 size/timing 侧信道**。

**安全边界声明(必须写入产品安全手册)**:

| 维度 | 本 IP 的保证 |
|------|------------|
| 加密内存(Secure/NCA/标记区间) | 走 Bypass,不压缩,无 size 侧信道 |
| 非加密内存的内容保密性 | **不保证跨域 size/timing 保密** —— 压缩比可观测 |
| 缓解(可选,有性能代价) | 按 Master/安全域**分区配额**(各域独立水位,互不可见对方占用);或对敏感域强制 CapRatio=1.0(等效 bypass) |

> 对安全敏感产品:把"是否允许压缩"作为**安全域属性**(via `aw_prot` / 区间配置),默认敏感域 bypass。

### 10.7 关键元数据冗余(L2P 双副本,基线)⭐

L2P 表承载**全系统内存的地址映射**,是单点故障核心:单条 Entry 损坏即丢失对应 LA 页全部数据;表头损坏可致整 IP 不可用。因此**冗余从"可选"提升为基线**:

```
- L2P 表在 DDR 元数据区存 **双副本**(主 + 备,物理 Bank 分离以抗局部故障)
- 每个 L2P Block(64B)带软件 CRC32;读时校验:
    主副本 CRC ok → 用主
    主坏 / 备好    → 用备 + 后台修复主副本
    两副本均坏     → 该 Block 涉及的 LA 页标记 Error,IRQ + SLVERR(不静默)
- 写 L2P 时双写(异步:主副本同步写,备副本经 Write Buffer 合并写,降带宽)
- 成本:L2P 表 12MB → 24MB(占 4GB 的 +0.29%),可接受
```

> Buddy Free List / GC Bitmap 可由 L2P + Page Header 在启动时**重建**,故只需单副本 + CRC;
> 唯有 L2P 是不可重建的权威映射,必须双副本。

---

## 11. 启动与运行时管理

### 11.1 冷启动初始化流程

```
0. Power-On Reset
1. PHY Training(由 DDRC 完成,本 IP 不参与)
2. 元数据区清零:
   - BootROM 写 L2P Table 区:全 0(所有 Entry State = Unmapped)
   - 写 Buddy Bitmap:全 0(全部 PPA 空闲)
   - 写 GC Bitmap:全 0
   - 总写流量 ≈ 32 MB,800MHz × 256bit/cycle DDR4 ≈ 1ms
3. Cache 初始化:
   - Tag RAM 全 Invalid
   - Data RAM 不初始化(Tag 控制)
4. APB 配置:
   - 设置 L2P_BASE / META_BASE
   - 配置 BYPASS_CFG 区间(代码段、显存等已知不压缩区)
   - 设置 CAP_RATIO
   - 写 INT_MASK,使能必要中断
5. 上报内存容量:
   - DT/E820 报告 6GB(或 CapRatio × 4GB)
   - OS 启动后驱动接管中断
6. 进入正常服务状态
```

### 11.2 OS 驱动设计(关键)

> **完整 ABI 见 [docs/04_os_driver_abi.md](docs/04_os_driver_abi.md)**

驱动模块清单(对应 Linux platform driver 形态):
```
ddr_zc_drv/
├── probe.c          // 中断/MMIO 注册,接管 4 个 IRQ
├── pressure.c       // IRQ_PRESSURE / HARD_FULL 处理
│                    //   读 Mailbox 中"建议释放的 LA 页列表"
│                    //   调用 vmscan / shrink_slab 释放
│                    //   通过 mailbox 通知 IP 已释放页
├── error.c          // IRQ_DECOMP_ERR 处理
│                    //   读 Mailbox bad_page_report
│                    //   隔离损坏页,通知应用层(SIGBUS)
├── perf.c           // 性能计数器导出到 sysfs
│                    //   /sys/class/zc/zc0/perf/...
├── mailbox.c        // 双向 ring buffer + doorbell + 消息分发
└── debugfs.c        // 故障注入 + trace dump
```

### 11.3 Flush / Invalidate

| 操作 | 行为 | 用途 |
|------|------|------|
| **Soft Flush** | 把所有 dirty cache line 压缩写回 DDR,不清 Tag | 进入 self-refresh 前 |
| **Hard Flush** | Soft Flush + 清 Tag(invalidate) | 切换 IP 状态 / 重配置 |
| **Bypass Flush** | 把所有压缩数据**反压缩**写回 DDR(地址按 LA 线性) | 关闭压缩进入 bypass 模式时 |

> **Bypass Flush 是关键操作**:容量扩展器关闭压缩后,DDR 不再有"逻辑空间 > 物理空间"的能力,必须先把所有数据反压缩并按 LA 线性放置。如果总数据量已超过 DDR 物理容量,Bypass Flush 失败,只能 OS 层 swap。

### 11.4 低功耗与 DDR Self-Refresh

```
SoC 进入低功耗:
  1. CPU 停止访问 → Cache 仍服务其他 Master(if any)
  2. 全 SoC idle → 触发 Self-Refresh 准备:
     a) Soft Flush(所有 dirty line 写回压缩 DDR)
     b) Cache + Compress IP 各 SRAM 时钟门控
     c) DDRC 进入 Self-Refresh
  3. 唤醒:
     a) DDRC 退出 Self-Refresh
     b) IP 时钟恢复
     c) Tag/Data 仍有效,Cache 命中率不损失
```

> **关键**:L2P 表与压缩数据都在 DDR,Self-Refresh 期间数据保持,无需重建。

### 11.5 Hot Reset 与 Hot Plug

- Hot Reset:仅复位 Cache 和压缩流水,**不动 DDR 元数据**,业务可恢复
- Hot Plug:目前不支持,需要 DDR 颗粒变化(超出范围)

---

## 12. 可配置参数

| 参数 | 范围 | 默认 | 说明 | 可改时机 |
|------|------|------|------|---------|
| ADDR_WIDTH | 32 / 40 / 48 | 40 | LA 位宽 | 综合 |
| DATA_WIDTH | 128 / 256 / 512 | 256 | AXI 数据位宽 | 综合 |
| ID_WIDTH | 6-16 | 10 | AXI ID 位宽(预留 3 bit 给内部) | 综合 |
| CACHE_SIZE | 64K / 128K / 256K | 128K | Cache 总容量 | 综合 |
| CACHE_WAY | 2 / 4 / 8 | 4 | 路数 | 综合 |
| LINE_SIZE | 32 / 64 / 128 | 64 | Cache Line 字节 | 综合 |
| MSHR_DEPTH | 4 / 8 / 16 | 8 | Outstanding Miss 深度 | 综合 |
| META_CACHE_SIZE | 8K / 16K / 32K | 16K | L2P + Header 共池 | 综合 |
| COMPRESS_ENGINE | NONE / BDI / ZERO / BD / BDI+ZERO+BD | 三引擎 | 压缩引擎组合 | 综合 |
| PAGE_SIZE | 4K | 4K | 元数据管理粒度 | 综合 |
| **CAP_RATIO** | **1.00 / 1.25 / 1.5 / 1.75 / 2.00** | **1.5** | **容量申报比例** | **运行时(strap pin)** |
| SOFT_HIGH | 80~99% | 95% | 压力中断阈值 | 运行时(APB) |
| SOFT_LOW | 50~90% | 80% | GC 启动阈值 | 运行时 |
| HARD_FULL | 95~100% | 99% | 拒分阈值 | 运行时 |
| GC_BW_LIMIT | 1~20% | 5% | GC 占用 DDR 带宽上限 | 运行时 |
| BYPASS_REGION_NUM | 4 / 8 / 16 | 8 | Bypass 区间数 | 综合 |

---

## 13. 实现计划(4 阶段,15-18 周)

### Phase 0:架构 + 工具链(2 周,与 Phase 1 并行)

**目标**:搭建仿真与评估基础设施,后续阶段不再为工具阻塞

- ✅ compress_eval.py 已交付([tools/compress_eval.py](tools/compress_eval.py)),mock 模式可跑通,
  gem5 trace 接入仅需 trace 格式适配器
- ✅ Page Header codec 已交付([tools/page_header_codec.py](tools/page_header_codec.py)),
  含全部单测,作为 RTL golden model
- 🟡 gem5 ZCMemTraceProbe 改造(待开发)
- 🟡 SPEC + MLPerf workload 集成(待开发)
- 🟡 DPI-C / SystemC 压缩参考模型(用于 RTL co-sim)
- 🟡 验证环境骨架(UVM testbench、AXI VIP 集成)

**交付物**:
- 评估报告:三种 workload 的加权压缩率分布([docs/01a 模板](docs/01a_phase0_eval_report_template.md))
- CapRatio strap 决策(每场景推荐值)
- BYPASS_CFG 配置(每 SoC 产品)
- Phase 0 工具链冻结

### Phase 1:Cache + L2P 骨架(5-6 周)⭐(关键调整)

**目标**:验证 Cache 主流水 + L2P 元数据通路,**不引入压缩,但接口预留**

> 与原方案的关键差异:**Phase 1 已经有 L2P / Meta Cache / 元数据区**,Phase 2 加压缩时不需要返工接口。

- cache_pipe_ctrl + tag_ram + data_ram + mshr
- l2p_meta_cache + l2p_dma(L2P 直存 PPA Ptr,Size 字段先固定 4096)
- space_alloc(Buddy 简化版,无 Slab)
- 元数据初始化逻辑
- req_buffer / addr_decode / resp_merge
- 性能计数器骨架(命中率、Miss 分布)

**验证**:
- 单元仿真:Cache 主流水的 Hit/Miss/Evict
- 集成仿真:接入 DDRC,跑随机 traffic
- 性能基准:命中率 vs Cache 容量

**交付物**:
- RTL + UVM testbench
- Hit 路径 4 cycle 时序闭环报告
- 命中率仿真曲线

### Phase 2:三引擎压缩 + 整页重定位(5-6 周)

**目标**:接入压缩引擎,完整跑通容量扩展功能

- compress_top + 三引擎 + Size Comparator + CRC8
- decompress_top + algo MUX + CRC Check
- page_reloc 流水
- L2P Entry 完整字段(State / Size / AlgoMix)
- Page Header 读写
- 错误中断与降级路径

**验证**:
- 各引擎独立功能验证(全模式覆盖)
- 三引擎并行选择正确性
- 端到端数据完整性(随机 + 定向 pattern,百万级请求)
- 重定位路径压力测试
- 加权 workload 仿真,验证 1.5× 容量申报安全性

**交付物**:
- 完整 RTL
- 各算法命中分布 + 压缩率报告
- 重定位频率统计

### Phase 3:GC + Pressure + OS 协同(3-4 周)

**目标**:闭环运行时管理,具备产品级稳定性

- gc_engine 完整 FSM(Hole / Compaction / Defrag GC)
- pressure_mon + 中断系统
- mailbox + APB 配置寄存器完整
- OS 驱动联调(Linux 5.x 验证)
- ECC 全覆盖(Tag / Data / Meta)

**验证**:
- 长时间随机压力(72 小时)
- 内存碎片回归测试
- 故障注入(ECC 错、CRC 错、压力)
- OS 协同闭环(swap / OOM 路径)

**交付物**:
- 产品级 RTL
- Linux 驱动
- 故障注入测试报告

### Phase 4:综合优化与签核(2-3 周)

- DFT(Scan / MBIST)
- 时序闭环(STA)
- 功耗优化(Clock Gating / Power Gating)
- FPGA 原型验证(Xilinx VCU128 或 Zynq UltraScale+)
- ASIC 综合 + 后端

**交付物**:
- 综合报告(面积 / 时序 / 功耗)
- FPGA demo
- 设计文档完整版

---

## 14. 性能监测与 Debug

### 14.1 性能计数器(32 项)

```
分类                  计数器                    说明
─────────────────────────────────────────────────────────────
访问统计 (4)          hit_cnt                   总命中数
                     miss_cnt                  总缺失数
                     write_hit_cnt             写命中数
                     write_miss_cnt            写缺失数

缺失分类 (4)          cold_miss_cnt             冷缺失
                     capacity_miss_cnt         容量缺失
                     conflict_miss_cnt         冲突缺失
                     coherence_miss_cnt        一致性缺失(本设计为 0)

L2P / Meta (4)       l2p_cache_hit_cnt
                     l2p_cache_miss_cnt
                     l2p_dma_cnt               DDR 访问 L2P 次数
                     header_miss_cnt           Page Header miss

压缩 (6)              comp_total_cnt            压缩调用次数
                     comp_bdi_chosen_cnt       BDI 选中次数
                     comp_zero_chosen_cnt
                     comp_bd_chosen_cnt
                     comp_uncompressible_cnt   不可压次数
                     comp_total_input_bytes / comp_total_output_bytes  → 压缩率

重定位与 GC (4)       reloc_cnt                 整页重定位次数
                     gc_hole_cnt               Hole GC 次数
                     gc_compaction_cnt
                     gc_defrag_cnt

容量水位 (3)          pressure_soft_high_cnt    SOFT_HIGH 触发次数
                     pressure_hard_full_cnt
                     gc_bw_used                 GC 累计 DDR 带宽

错误 (4)              ecc_corr_cnt              ECC 可纠正错
                     ecc_uncorr_cnt            ECC 不可纠正错
                     decomp_crc_err_cnt        解压 CRC 错
                     allocator_fail_cnt

延迟分布 (3)          read_lat_histogram[16]    读延迟直方图(16 个 bin)
                     write_lat_histogram[16]
                     reloc_lat_histogram[8]
```

### 14.2 Trace Buffer

```
环形缓冲区(片上 4 KB SRAM 或写到 DDR 元数据区):
  每条 record 32 byte:
    timestamp(8) / event_type(1) / la_addr(8) / ppa_addr(8) /
    size(2) / algo(1) / latency(2) / ext(2)

  触发条件(APB 配置):
    - 任意 Miss
    - 重定位
    - CRC 错
    - 延迟超阈值
    - 特定 ID / 地址范围

  导出:
    - 通过 mailbox / DDR ring buffer
    - 工具链 ddr_zc_trace 转换为 perfetto trace
```

### 14.3 Bus Error 注入

调试用,通过 APB 触发:
- Tag/Data RAM 单 bit / 双 bit 翻转
- 解压 CRC 错(强制 mismatch)
- L2P Entry 损坏
- 容量水位强制为 X%(测试压力路径)
- GC 错误注入

### 14.4 DFD(Design for Debug)

- 所有 FSM 状态可观测(scan + 寄存器读)
- 关键事件计数器溢出告警
- Bus monitor:可记录任何 N 拍内的 AXI 接口波形(片上 ring buffer 1 KB)

---

## 15. 验证与签核

### 15.1 验证层级

| 层级 | 工具 | 范围 | 覆盖率目标 |
|------|------|------|-----------|
| **单元** | UVM + SystemVerilog | 每个 RTL 模块 | 行 100%,功能 95% |
| **子系统** | UVM | Cache 流水 / 压缩 / GC | 功能 90% |
| **集成** | UVM + AXI VIP | 全 IP + 模拟 DDR | 功能 85% |
| **形式** | Cadence JasperGold | 死锁 / 活锁 / 状态可达 | 关键 FSM 全证 |
| **系统级** | gem5 / FPGA | OS 启动 + benchmark | benchmark 通过 |

### 15.2 关键验证点

```
正确性:
  ✓ 所有 LA 写后读结果一致(端到端数据完整性)
  ✓ 重定位前后数据不变
  ✓ Self-Refresh 后数据不变
  ✓ ECC 错误正确纠正 / 上报
  ✓ 压力中断后 OS 释放,空间正确回收

性能:
  ✓ Hit 4 cycle(STA + 仿真 latency 测量)
  ✓ Miss 延迟开销 ≤ 30%
  ✓ 重定位频率 < 1%(典型 workload)
  ✓ 压缩率 ≥ 1.5×(典型 workload)

边界:
  ✓ 全 Cache flush 不丢数据
  ✓ HARD_FULL 触发拒分,SLVERR 正确返回
  ✓ GC 与 Evict 抢占
  ✓ 大事务(burst 16 × 256B)正确拆分

故障:
  ✓ 单 bit ECC 错恢复
  ✓ 解压 CRC 错重读 / 上报
  ✓ L2P 损坏检测
  ✓ Bypass 切换正确
```

### 15.3 形式验证目标

```
死锁证明:
  - 任意输入序列下,MSHR/重定位/GC 不死锁
  - 三者抢占顺序不产生饥饿

活锁证明:
  - 重定位后必然在有限拍完成
  - GC 可在抢占解除后恢复

不变式:
  - L2P Entry State 转换合法性
  - PPA Buddy 树空间守恒(分配总和 = 总容量 - 空闲)
  - Page Header CRC 链路完整性
```

### 15.4 系统级验证

- **Linux 启动**:driver 加载,/proc/meminfo 显示 6GB
- **MLPerf Tiny**:NPU 推理压缩率与延迟
- **SPEC CPU 2017**:CPU 工作负载下命中率与延迟
- **stress-ng**:24 小时压力,无 hang/数据损坏
- **kernel selftests**:VM 子系统 + memory pressure

---

## 16. 风险与权衡

### 16.1 风险表(重新校准)

| 风险 | 影响 | 概率 | 缓解措施 |
|------|------|------|---------|
| **加权压缩率低于 1.5×** | 容量申报失败,频繁 SOFT_HIGH | **中-高** | 真实 trace 验证 → strap pin 调整 CAP_RATIO;场景化标定 |
| **写更新触发重定位频繁** | 写带宽倒退,延迟尖刺 | 中 | 监控 reloc 频率;Cache 容量↑ 减小 Evict 频率;Slab 优化 |
| **Meta Cache 命中率不足** | Miss 延迟翻倍 | 中 | 加大 Meta Cache;Page Header 共池缓存;预取 |
| **GC 占用带宽过高** | 业务带宽下降 | 中 | GC_BW_LIMIT 限速;GC 抢占 |
| **Hit 路径时序不收敛** | 频率下降 | 低 | 4-Way 并行读;流水寄存器切割;关键路径降频 |
| **解压 CRC 错** | 数据损坏静默 | 低 | 8 bit CRC + 重读 + 上报 |
| **OS 驱动响应慢** | HARD_FULL 触发 SLVERR | 中 | 抢先 SOFT_HIGH(95% 阈值留缓冲);驱动用高优先级 wakeup |
| **L2P 表损坏** | IP 不可用 | 极低 | 软件 CRC32 + **双副本(基线,§10.7)**,单副本坏自动从备恢复 |
| **加密内存比例高** | 实际压缩率低 | 中 | BYPASS_CFG 标记 + AXI prot 检测 |
| **大事务跨 Line** | 流水复杂度↑ | 低 | Phase 1 拆分实现 + Reorder Buffer |
| **三引擎面积** | 芯片面积+ | 低 | 三种均为简单组合;解压侧 clock gate |
| **Self-Refresh 退出后元数据不一致** | 数据损坏 | 极低 | DDR ECC + 启动时元数据 CRC32 校验 |

### 16.2 核心权衡

```
1. 压缩率 vs 写复杂度
   - 高压缩率 → 重定位频率高 → 写延迟尖刺
   - 妥协:三引擎 + 整页重定位(避免页内 RMW)+ GC 后台合并

2. Cache 容量 vs 重定位频率
   - Cache 容量 ↑ → Evict 频率 ↓ → Reloc 频率 ↓ → 写带宽收益 ↑
   - 妥协:128 KB 默认,可配 256 KB

3. CAP_RATIO 激进度 vs OS 干扰
   - 高 → 节省颗粒成本但 SOFT_HIGH 频繁打断 OS
   - 低 → OS 干净但容量收益打折
   - 妥协:1.5× 默认 + strap pin 配置 + workload 自适应(未来 Phase 5)

4. Meta Cache vs SRAM 面积
   - 大 Meta Cache → Miss 延迟低 → 但芯片面积+
   - 妥协:16 KB 共池(L2P + Header) → 实测 hit rate ≥ 85%

5. 整页重定位 vs 页内重排
   - 整页:简单可控,延迟集中(100-300 cycle 一次)
   - 页内:频繁小代价,但 RMW 风暴
   - 选择:整页(本方案)

6. Hit 路径功能完整性
   - 加 Meta 查询 / QoS 判断会增加 Hit 延迟
   - Hit 路径只做 Tag + Data,Meta 仅 Miss 路径
   - 4 cycle 硬约束
```

---

## 17. 开源参考

### 17.1 Cache 架构参考

| 项目 | 语言 | 参考价值 |
|------|------|---------|
| [BlackParrot](https://github.com/black-parrot/black-parrot) | SystemVerilog | Cache 状态机、Tag/Data 组织、流水线 |
| [CVA6](https://github.com/openhwgroup/cva6) | SystemVerilog | AXI Cache,工业级 RTL 风格 |
| [OpenPiton](https://github.com/PrincetonUniversity/openpiton) | Verilog/SV | 共享 L2,多核一致性 |
| [PULP AXI](https://github.com/pulp-platform/axi) | SystemVerilog | AXI 基础设施(arbiter, mux, demux) |

### 17.2 压缩算法参考

| 资源 | 类型 | 参考价值 |
|------|------|---------|
| BDI 论文(PACT 2012) | 学术 | BDI 算法原理 |
| FPC 论文(HPCA 2004) | 学术 | FPC,可作为补充算法 |
| [gem5](https://github.com/gem5/gem5) | 仿真器 | BDI/FPC 功能模型 |
| [Xilinx Vitis Libraries](https://github.com/Xilinx/Vitis_Libraries) | HLS | LZ4/Snappy 硬件压缩参考 |

### 17.3 容量扩展参考

| 资源 | 类型 | 参考价值 |
|------|------|---------|
| **IBM AME(Active Memory Expansion)** | 商业方案 | **透明硬件压缩 + OS 协同的工业级先例**;CAP_RATIO 设计、压力反馈机制 |
| zswap / zram(Linux) | 软件方案 | OS 协同接口(swap-out 触发、L2P 表组织)、压力管理思路 |
| Compresso(USENIX ATC '23) | 学术 | DRAM 透明压缩的最新研究 |
| CXL.mem with HW compression(规范草案) | 标准 | 未来扩展方向 |

### 17.4 DDR 控制器参考

| 项目 | 类型 | 参考价值 |
|------|------|---------|
| [LiteDRAM](https://github.com/enjoy-digital/litedram) | Python/HDL | 集成验证 DDR 模型 |

---

## 附录 A:术语表

| 术语 | 说明 |
|------|------|
| LA | Logical Address,Master 视角的内存地址 |
| PPA | Pseudo Physical Address,IP 内部分配的连续物理空间 |
| DPA | DDR Physical Address,实际 DDR 颗粒地址(本方案 PPA == DPA) |
| L2P Map | Logical-to-Physical Map,LA 页 → PPA 区段的映射表 |
| BDI | Base-Delta-Immediate,Cache Line 压缩算法 |
| FPC | Frequent Pattern Compression |
| MSHR | Miss Status Holding Register |
| DFI | DDR PHY Interface |
| pLRU | Pseudo-LRU 替换策略 |
| CMO | Cache Maintenance Operation |
| NCA | Non-Cacheable Attribute |
| WAF | Write Amplification Factor |
| CapRatio | 容量申报比例(对外申报容量 / 实际 DDR 容量) |
| Reloc | 整页重定位 |
| GC | Garbage Collection |
| AME | Active Memory Expansion(IBM 的硬件压缩内存扩展技术) |
| SECDED | Single-Error-Correct, Double-Error-Detect |

---

## 附录 B:数据格式速查

### B.1 L2P Entry(8 byte)

```
bit  0     : Valid
bit  1-3   : State (3 bit)
bit  4-35  : PPA Ptr (32 bit, 64B 对齐)
bit 36-48  : Size (13 bit, 0~4272 = 4096 数据 + 176 Header)
bit 49-56  : AlgoMix (8 bit = 4 算法 × 2 bit 占比档位,GC/统计用)
bit 57-63  : Reserved
```

> **PPA Ptr 位宽说明**:4GB PPA @64B 对齐只需 26 bit;此处用满 32 bit(可寻址 256GB)是
> **为未来 >4GB DDR 预留**。当前实现高 6 bit 恒 0,可在缩减 DDR 成本敏感产品上压回 26 bit
> 把空出的 6 bit 给 Reserved(L2P Entry 仍 8B 对齐,不改表大小)。

### B.2 Page Header(176 byte)

> 详见 [docs/02_page_header_spec.md](docs/02_page_header_spec.md)。

```
Offset  Field                   Size
0x00    Magic                   2 B   (0xCC55)
0x02    Reserved                2 B
0x04    Generation              4 B   (重定位计数器)
0x08    Total Comp Size         2 B
0x0A    Reserved                2 B
0x0C    Page CRC32              4 B
0x10    Line Info Array         88 B  (64 × 11 bit packed)
0x68    Line CRC8 Array         64 B  (64 × 8 bit)
0xA8    Reserved                8 B
0xB0    [End]

Line Info (11 bit):
  bit 0-1  : algo_id (BDI/Zero/BD/None)
  bit 2-4  : mode
  bit 5-10 : size - 1 (1~64 → 0~63)
```

### B.3 压缩 Line 格式

```
BDI:    [mode 3bit] [base 4/8B] [delta_array]
Zero:   [mode 3bit] [pattern 1B] [bitmap 8B] (Mode 2 稀疏)
ByteDelta: [mode 3bit] [base 1/2/4B] [delta_array]

总长度由 Page Header 中的 size 字段记录
```

---

## 附录 C:典型命令时序

### C.1 Read Hit

```
clk     1   2   3   4   5
ar_v    H   .   .   .   .
ar_a   ADDR ..  ..  ..  ..
        REQ TAG DATA RESP
                        r_v=1
                        r_d=DATA
```

### C.2 Read Miss + L2P Hit + Header 共池命中

```
clk     1   2   3   4   5  ...  68  69  70  71
ar_v    H
        REQ TAG DATA(stall, MSHR alloc)
                MSHR     L2P   DDR_CMD ... DDR_DATA
                                              DECOMP
                                                  FILL
                                                      r_v=1

延迟约 71 cycle
```

### C.3 整页重定位

```
event       cycle
Evict trig  0
读 64Line   1-100  (从 Cache 取已有,DDR 取剩余)
解压        100-200 (流水)
重压缩      200-280
申请新页    281
写新页      282-350 (DDR 写,部分 pipeline)
更新 L2P    351
释放旧页    352
完成        353

Master 该 LA 页访问阻塞约 350 cycle
```

---

**文档结束。**

## 版本历史

### v2.2(当前)— 一致性修正 + 关键风险量化

按优先级修正与增强:

**P0(影响 RTL/golden model 正确性与方案成立)**
1. **Page Header 大小全文统一 176B**:清除主文档 §3.2.4/§3.4/§5.5.2/§7.5 及 02 文档残留的 128B/160B。
2. **CRC 对齐 golden model**:page_crc32 覆盖 172 字节(0x00-0x0B + 0x10-0xAF);CRC8 多项式更正为 0x1D(SAE-J1850),与 [tools/page_header_codec.py](tools/page_header_codec.py) 一致。
3. **§7.5 写带宽/WAF 模型重做**:旧 WAF=3.22 与"省带宽"矛盾;引入 Header 合并因子 k 与 Reloc 频率 f,给出诚实结论——25% 写带宽节省需 k≥12 且 f≤0.1%,否则写带宽降为 P1。§1.2 相应调整。
4. **[compress_eval.py](tools/compress_eval.py) 增加 Reloc 频率模拟**:按 trace 时序演化 Buddy 槽位,输出 reloc_per_write/overwrite;新增 `--rewrite-prob`。

**P1**
5. **[compress_eval.py](tools/compress_eval.py) BDI 早退 bug 修正**:不再在 max_abs32<128 时提前 return,改为收集全部候选取 min(对齐 RTL)。
6. **§8.3.1 Miss 延迟敏感性**:有效 Miss 延迟随 Meta Cache 命中率变化,30% 目标需 h≥95%(此前 §16 假设 85%,矛盾已标注);§8.3.2 把三跳并行预取从 Phase 2 提前为基线。
7. **§3.3.4 SLVERR-on-store 危险语义**:增加 memory hotplug / balloon 替代契约,列为最高优先级 OS 联评项。

**P2**
8. 元数据开销口径统一(5.4%,含 L2P 双副本);L2P Size 上限统一 4272;PPA Ptr 位宽说明;AlgoMix 语义澄清。
9. **§10.6 压缩侧信道安全边界声明**;**§10.7 L2P 双副本提升为基线**;CRC8 失败**禁止静默零填充**,改 Error+SLVERR。
10. [compress_eval.py](tools/compress_eval.py) rng 注入修正 + 已知局限(不建模命中率/读流量/Header 合并)显式登记。

**P3**
11. §6.7 ByteDelta vs FPC 选型说明;§6.8 AIoT 页内去重/小窗口 LZ 探索(Phase 5);02 文档 offset 锚点替代方案。

### v2.1

新增 4 份子文档 + 2 个工具,落地关键设计细节:

1. **Phase 0 评估框架**:[docs/01_phase0_trace_eval.md](docs/01_phase0_trace_eval.md) +
   [tools/compress_eval.py](tools/compress_eval.py) — trace 格式、gem5 集成方案、
   评估器(自包含可执行)、5 个 workload 示范报告
2. **Page Header byte-precise 规范**:[docs/02_page_header_spec.md](docs/02_page_header_spec.md) +
   [tools/page_header_codec.py](tools/page_header_codec.py) — V2 (176B) 三方案对比、
   C struct 定义、打包/解包伪代码、CRC 链路、单测全绿
3. **Reloc FSM 详细设计**:[docs/03_page_reloc_fsm.md](docs/03_page_reloc_fsm.md) —
   9 状态 FSM、MSHR 抢占协议、5 类异常处理、4 种时序图、11 项验证向量
4. **OS 驱动 ABI**:[docs/04_os_driver_abi.md](docs/04_os_driver_abi.md) —
   MMIO 寄存器映射、4 中断协议、Mailbox 双向 ring + 8 类消息、性能计数器、
   sysfs/debugfs 接口、与 OS 团队评审清单

**主文档相应修正**:
- §3.2.3 Header 大小 128B → **176B**;Line Info 14bit → 11bit + 单独 8bit CRC 数组
- §3.5 元数据开销重新计算(5.1%,Header 含在 PPA 内)
- §6.1.4 加 Phase 0 工具链与 mock 评估示范的交叉引用
- §7.3 Reloc 流水从 7 阶段细化到 9 状态 FSM,加抢占规则
- §9 / §11.2 加 OS Driver ABI 引用
- §13 Phase 0 标记已交付组件
- 附录 B.2 Page Header 格式与 v2 对齐
- 文档矩阵新增

### v2.0

1. **产品定位明确为容量扩展器**(LA 6GB,DDR 4GB,1.5× 申报)
2. **新增 §3 寻址与容量模型**:三层地址空间 / L2P Map / 压力反馈
3. **§7 空间管理重写**:Buddy + Slab 分配器、整页重定位、GC 三类
4. **§10 可靠性与安全章节**:全链路 ECC + Line CRC + 加密内存交互
5. **§11 启动与运行时**:冷启动、OS 驱动、Flush 三种模式、低功耗
6. **§14 性能监测**:32 项计数器 + Trace Buffer + 故障注入
7. **§15 验证与签核**:四级验证 + 形式验证目标 + 系统级 benchmark
8. **§6.1.3 加权压缩率分析**:3 个真实 workload 场景
9. **§16 风险表重新校准**:重定位频率、加权压缩率列为中-高风险
10. **§13 Phase 划分调整**:Phase 1 即引入 L2P 骨架,避免 Phase 2 接口返工
