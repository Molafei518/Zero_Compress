# 整页重定位 FSM 与 MSHR 抢占规则

> **目的**:把主文档 §7.3 的 7 阶段流水细化为 RTL 级 FSM,并定义与 MSHR、Cache 主流水、GC 三方的抢占协议
> **依赖**:[../cache_compress_ip_architecture.md](../cache_compress_ip_architecture.md) §5.7 / §7.3 / §8.4

---

## 1. 触发场景汇总

整页 Reloc 由以下 5 种事件触发,所有触发都进入同一 FSM:

| 触发源 | 描述 | 优先级 | 频率(估) |
|-------|------|-------|---------|
| **EVICT_OVERFLOW** | Evict 时新压缩 size > 页内剩余空间 | P1 | < 1% / Evict |
| **WRITE_INPLACE_FAIL** | Cache 不命中的写直达 + 压缩 size 超原槽 | P1 | < 0.1% |
| **GC_COMPACTION** | 后台 GC 发现页空闲 > 25% | P3 | 配置限速 |
| **GC_DEFRAG** | Buddy 分配高级别块不足 | P3 | 偶发 |
| **HEADER_REPAIR** | Page Header CRC 错重读后仍错(尝试修复) | P2 | 极低 |

> 不同触发源的差别仅在 FSM 入口分支,主流水共享。

---

## 2. FSM 状态定义(9 状态)

主文档 §7.3 的 7 阶段是面向人的描述,实际 RTL 拆出**预校验**和**完成回执**两个状态,共 9 个:

```
状态                     说明                              典型 cycle
────────────────────────────────────────────────────────────────────
S_IDLE                   等待触发                          0
S_LOCK                   置 L2P Entry State=Pending,
                         锁定本 LA 页所有后续访问           2-3
S_COLLECT_PLAN           枚举 64 条 Line,标记
                         哪些在 Cache / 哪些需 DDR 取      3-5
S_COLLECT_FETCH          从 DDR 读出未在 Cache 的 Line     ≤ 64 × DDR_BL
                         (与 S_RECOMP 部分 pipeline)
S_RECOMP                 三引擎重压缩(并行,流水)          64 × 3 ≈ 64 cyc
S_ALLOC                  从 Allocator 申请新 PPA 区段      4-32(若 cache miss)
S_WRITE_NEW              写新 Page Header + Line 序列      ≤ 4KB / DDR_BW
S_COMMIT                 更新 L2P Entry,释放旧 PPA        2-3
S_DONE                   通知触发源,转 S_IDLE             1
```

---

## 3. 状态机详图

```
         ┌──────────────────────────┐
    ┌──→ │       S_IDLE             │ ←──────────┐
    │    └─────┬────────────────────┘            │
    │          │ trigger_pulse                   │
    │          ▼                                 │
    │    ┌──────────────────────────┐            │
    │    │       S_LOCK             │            │
    │    │  - 写 L2P[la].state=Pend  │            │
    │    │  - 增 generation         │            │
    │    │  - 通知 MSHR 阻塞同 LA   │            │
    │    └─────┬────────────────────┘            │
    │          │ lock_done                       │
    │          ▼                                 │
    │    ┌──────────────────────────┐            │
    │    │  S_COLLECT_PLAN          │            │
    │    │  - 读旧 Page Header       │            │
    │    │  - 对 64 条 Line 标记:   │            │
    │    │    in_cache / need_fetch │            │
    │    └─────┬────────────────────┘            │
    │          │                                 │
    │          ▼                                 │
    │    ┌──────────────────────────┐            │
    │    │  S_COLLECT_FETCH ⇄ RECOMP│            │
    │    │  - DDR 取需 fetch 的 Line │            │
    │    │  - 同时已就位的 Line      │            │
    │    │    进入 S_RECOMP 流水     │            │
    │    └─────┬────────────────────┘            │
    │          │ all 64 lines compressed         │
    │          ▼                                 │
    │    ┌──────────────────────────┐            │
    │    │  S_ALLOC                 │            │
    │    │  - 计算 new_total_size    │            │
    │    │  - 调用 space_alloc       │            │
    │    │    若失败 → 触发 IRQ_HARD_│            │
    │    │    FULL,FSM 暂停在 S_ALLOC│            │
    │    │    等待 OS 释放空间        │            │
    │    └─────┬────────────────────┘            │
    │          │ alloc_ok                        │
    │          ▼                                 │
    │    ┌──────────────────────────┐            │
    │    │  S_WRITE_NEW             │            │
    │    │  - 写新 Page Header       │            │
    │    │  - 写 64 条 Line 序列     │            │
    │    └─────┬────────────────────┘            │
    │          │ all writes acked                │
    │          ▼                                 │
    │    ┌──────────────────────────┐            │
    │    │  S_COMMIT                │            │
    │    │  - 写 L2P[la]={mapped,   │            │
    │    │       new_ppa, new_size, │            │
    │    │       generation}        │            │
    │    │  - 旧 PPA 加入 GC 回收队列 │            │
    │    └─────┬────────────────────┘            │
    │          │ l2p ack                         │
    │          ▼                                 │
    │    ┌──────────────────────────┐            │
    │    │  S_DONE                  │            │
    │    │  - 解阻 MSHR 同 LA        │            │
    │    │  - notify trigger source │            │
    │    └─────┬────────────────────┘            │
    └──────────┘                                  │
                                                  │
       异常通路:S_ALLOC 失败 → 等 OS → 重试 ─────┘
       异常通路:S_WRITE_NEW DDR 写错 → 回滚 ─────┘
```

---

## 4. 关键信号定义

### 4.1 FSM 控制信号

```verilog
// 触发(任一拉高即进入 LOCK,优先级见 §6)
input  trig_evict_overflow,
input  trig_write_inplace_fail,
input  trig_gc_compaction,
input  trig_gc_defrag,
input  trig_header_repair,

// 触发载荷
input  [LA_PAGE_W-1:0] trig_la_page,
input  [2:0]           trig_source_id,    // 用于 done 回执路由

// 状态输出
output [3:0] reloc_state,            // 当前状态
output       reloc_busy,             // S_IDLE 之外
output       reloc_done_pulse,       // 进入 S_DONE 的单拍
output [LA_PAGE_W-1:0] reloc_la_page, // 当前处理的 LA 页

// 错误
output       reloc_alloc_fail,       // 进入 S_ALLOC fail wait
output       reloc_ddr_err,          // DDR 写错(致命)

// 与 MSHR 接口
output       mshr_block_la_valid,    // 拉高时 MSHR 拒绝该 LA 的新请求
output [LA_PAGE_W-1:0] mshr_block_la_page,

// 与 L2P 接口
output       l2p_write_req,
output [LA_PAGE_W-1:0] l2p_write_addr,
output [63:0] l2p_write_data,
input        l2p_write_ack,

// 与 Compress / Decompress 引擎接口(借用,高优先级)
output       comp_req,
output [63:0] comp_in_data,         // 64B
input  [10:0] comp_out_info,        // {algo, mode, size}
input        comp_done,
```

### 4.2 内部 scratch SRAM

```
名称: reloc_scratch_ram
容量: 4 KB(一整页解压后的原始数据)
端口: 双口(读/写),宽 256 bit
用途:
  - S_COLLECT_FETCH 写入解压后数据
  - S_RECOMP 读出供压缩
  - S_WRITE_NEW 也可直接读压缩后数据(if 双 buffer)
```

---

## 5. 与 MSHR 的抢占协议

### 5.1 MSHR 阻塞表

MSHR 维护 `block_la_table`,容量 = 同时进行中的 Reloc 数(默认 1,可配 2):

```
struct {
    valid;
    la_page;
    generation_at_lock;   // 锁定时的 L2P generation
}
```

MSHR 行为:
- 收到新 Miss/Evict 时,先查 `block_la_table`
  - 命中 → 请求停滞在 MSHR Wait 队列(不出 MSHR slot,但 stall 后续同 ID)
  - 不命中 → 正常分配 MSHR slot
- Reloc 进入 S_DONE 时清除 `block_la_table` 对应项,Wait 队列重新调度

### 5.2 优先级与抢占规则

```
┌─ 业务请求(Master 来) ───────┐  最高优先级
│                              │
├─ Reloc(EVICT_OVERFLOW 触发)─┤  必须完成才能 unblock LA
│                              │
├─ Reloc(WRITE_INPLACE_FAIL)──┤
│                              │
├─ Reloc(HEADER_REPAIR)───────┤
│                              │
├─ Reloc(GC_COMPACTION)───────┤  可被业务请求抢占
│                              │
└─ Reloc(GC_DEFRAG)────────────┘  最低,任何信号都可抢占
```

### 5.3 抢占机制(仅 GC 触发的 Reloc)

GC 发起的 Reloc **可被业务请求抢占**。规则:

```
每个状态(除 S_IDLE / S_DONE / S_COMMIT)都设抢占检查点:
  if (gc_triggered_reloc && master_req_pending_for_other_la) {
      save current state to scratch register
      yield to master pipeline for 1-2 cycle
      resume on next free cycle
  }

例外:
  - S_LOCK / S_ALLOC / S_COMMIT:必须原子完成,不能抢占
  - S_WRITE_NEW:已开始写 DDR 必须写完(否则旧/新页混合状态)
```

> EVICT/WRITE/HEADER_REPAIR 触发的 Reloc **不抢占**,因为这是同步路径——业务请求在等它完成。

### 5.4 多 Reloc 并发限制

为简化设计,**同时只允许 1 个 Reloc**(`block_la_table` 深度=1)。
后续触发进入 reloc_pending_fifo(深度 8),依次处理。

升级到 2 并发的成本:
- scratch RAM × 2(8 KB)
- L2P 写仲裁
- 收益有限(Reloc 频率 < 1%),Phase 4 评估

---

## 6. 触发优先级与仲裁

```
trigger_arb:
  if (trig_header_repair)         // P0,数据完整性优先
      grant = repair;
  else if (trig_evict_overflow)   // P1,业务路径
      grant = evict;
  else if (trig_write_inplace_fail)
      grant = write;
  else if (trig_gc_compaction)
      grant = gc_compact;
  else if (trig_gc_defrag)
      grant = gc_defrag;
```

---

## 7. 时序图

时序图采用 cycle-level 视角,标注关键事件。**假设 800MHz,DDR4 单笔 64 cycle**。

### 7.1 典型场景:Evict 触发 Reloc(无抢占)

```
clk:       0   2   4   6   8  10  ...  64  68  70  72  74  ...
              S_LOCK
          │L2P_W│
                   S_COLLECT_PLAN
                  │读 PageHdr (DDR cmd)│  ... wait ... │data ret│
                                                      S_FETCH ⇄ RECOMP
                                                     │读 line0 │ ...
                                                     ... 64 lines pipeline
                                                                            S_ALLOC│
                                                                                 buddy hit
                                                                                       S_WRITE_NEW
                                                                                       │写 Hdr+ 64 line │
                                                                                                ... 90 cyc
                                                                                                          S_COMMIT │ S_DONE
                                                                                                          │L2P_W│
事件标尺:
   c0:    Evict trigger
   c2-3:  L2P 锁定,MSHR 标记
   c4-67: 读 PageHeader (~64c)
   c68-130: Collect+Recomp pipeline(假设 50% Line 已在 Cache,32 行需 fetch)
   c131-220: WriteNew(假设 1.5KB 新页,~90c DDR 写)
   c221-222: Commit + L2P 写
   c223:  Done

总耗时:~220 cycle ≈ 275 ns @ 800MHz

业务影响:
   - 同 LA 页的 Master 请求阻塞 ~220 cycle
   - 异 LA 页的 Master 请求不影响(Cache 主流水正常)
```

### 7.2 GC 触发 Reloc 被业务抢占

```
clk:    0   ...  50   52   54   56   58   ...  120  ...
       GC_trig_high
        S_LOCK ... S_RECOMP (mid)
                   ▼
                   抢占检查:master_req_to_other_la = high
                   ▼
                   save state (1c)
                   ▼
                   release one cycle to master pipeline
                                 (master Hit/Miss流水进 1 拍)
                                       ▼
                                       resume RECOMP
                                       ...
                                                          S_WRITE_NEW
                                                                      ...

抢占次数:每检查点最多 1 cycle yield,本次 Reloc 共 yield 5 次 = +5 cycle
对业务的 collateral:0(本来就在主流水)
对 Reloc 的延长:~3-5%(可接受,GC 不是关键路径)
```

### 7.3 S_ALLOC 失败(空间不够,等 OS)

```
clk:    0  ... 100   ...  10ms ...
                 S_ALLOC (fail)
                  ▼ alloc_fail_pulse → IRQ_HARD_FULL
                  ▼ stall here
                  ▼ MSHR 同 LA 持续阻塞
                            ...
                            OS 处理 IRQ,通过 mailbox 通知释放完成
                            ▼
                            alloc_retry
                                       ▼
                                       alloc_ok → S_WRITE_NEW

最坏延迟:OS 响应时间(目标 10ms,即 8M cycle)
若 OS 超时 → 升级:本 LA 页所有读写永久 SLVERR
```

### 7.4 多 Reloc 排队

```
clk:    0   ...  220  ...  440  ...  660
       Reloc#1 (Evict触发)
        ████████████████ S_DONE
                          Reloc#2 (GC触发) 出 fifo
                          ████████████████ S_DONE
                                            Reloc#3 (WriteFail触发) 优先级被前面占用
                                            ████████████████

待处理 fifo 深度 8 = 最多 8 × 220 cyc = 1760 cyc 排队
若 fifo 满 → Evict 触发被反压(Cache evict 暂停)
```

---

## 8. 异常处理

| 异常 | 检测点 | 处理 | 副作用 |
|------|-------|------|--------|
| Page Header CRC 错(读旧) | S_COLLECT_PLAN | 重读 1 次,仍错 → IRQ_DECOMP_ERR + LA 页坏页标记 | 该 LA 页不再服务 |
| Compressed Line CRC 错 | S_COLLECT_FETCH 解压时 | 该 Line 用零填充 + IRQ_DECOMP_ERR(单 Line) | Reloc 完成,但数据已损 |
| 重压缩失败(< 64B 总和)|S_RECOMP后| 改 State=Uncompressed,占 4KB+176B|空间略增|
| Allocator 失败 | S_ALLOC | IRQ_HARD_FULL,等 OS;超时升级 SLVERR | 同 LA 页阻塞 |
| DDR 写返回错 | S_WRITE_NEW | 重试 1 次;仍错 → 回滚到 S_LOCK 之前(L2P 不动),IRQ_DECOMP_ERR | 旧页保留可用 |
| L2P 写错 | S_COMMIT | 重试 1 次;仍错 → 致命错误,IP 进入 safe mode | 系统级处理 |
| Reloc 超时(>10ms 未完成) | watchdog | 强制回滚,标记 LA 页坏 | 该页不可用 |

> **设计原则**:任何中途失败必须保证 L2P Entry **保持原值**或**进入 Error 状态**,绝不 leave dangling 指针。

---

## 9. 性能目标

| 指标 | 目标 | 监控点 |
|------|------|-------|
| Reloc 总延迟 p50 | ≤ 250 cycle | perf_cnt:reloc_lat_histogram |
| Reloc 总延迟 p99 | ≤ 500 cycle | 同上 |
| Reloc 频率 | < 1% / Evict(典型 workload) | perf_cnt:reloc_cnt / evict_cnt |
| 同 LA 页阻塞时间 p99 | ≤ 1 μs(800 cycle) | perf_cnt:la_block_lat_histogram |
| Allocator hit 率 | ≥ 95% | perf_cnt:alloc_cache_hit / alloc_cnt |

---

## 10. 验证向量(给 UVM testbench)

| 编号 | 场景 | 期望结果 |
|------|------|---------|
| RV01 | Evict 原位成功(size 不变) | 不进入 FSM,直接写 |
| RV02 | Evict 触发 Reloc,Cache 命中 60% | FSM 完成 ≤ 250c |
| RV03 | Evict 触发 Reloc,Cache 全 miss | FSM 完成 ≤ 500c |
| RV04 | GC Reloc 被业务抢占 5 次 | 抢占恢复正确,数据完整 |
| RV05 | S_ALLOC 失败 → 等 OS → 重试成功 | 等待期间 IRQ_HARD_FULL 上报 |
| RV06 | S_WRITE_NEW DDR 写错重试 | 重试后成功,L2P 一致 |
| RV07 | 同时 8 个 Reloc 排队 | 串行完成,fifo 不溢出 |
| RV08 | Reloc 期间同 LA 页 Master 读 | 阻塞至 S_DONE 后返回新数据 |
| RV09 | Reloc 期间不同 LA 页 Master 读 | 不受影响,Hit 4 cycle |
| RV10 | Header CRC 错 → 重读仍错 → 标记坏页 | 后续访问该页直接 SLVERR |
| RV11 | 重压缩后 size > 4KB → Uncompressed 模式 | L2P State=Uncompressed,占 4272B |

---

## 11. 与主文档的差异

| 主文档原版 (v2.0 §7.3) | 本规范 (v2.1) | 行动 |
|---|---|---|
| 7 阶段流水 | **9 状态 FSM**(拆 LOCK / DONE) | 主文档 §7.3 更新 |
| 阻塞描述含糊 | **MSHR block_la_table** 明确机制 | 主文档 §5.4 / §7.3 更新 |
| 抢占规则未提 | **GC 可抢占,业务路径不抢占** | 主文档 §7.4 更新 |
| 失败 IRQ 含糊 | **5 种异常路径明确** | 主文档 §10.4 更新 |
| 时序仅文字描述 | **4 种时序图** | 主文档 §8.4 / 附录 C 更新 |

---

## 12. 决策清单

- [x] 9 状态 FSM 设计完成
- [x] MSHR 阻塞表机制定义
- [x] 抢占规则(仅 GC 触发的 Reloc 可抢占)
- [x] 5 种异常路径
- [x] 验证向量 11 项
- [ ] RTL `page_reloc_fsm.sv` 实现
- [ ] UVM testbench 集成
- [ ] 主文档同步更新
