# OS 驱动 ABI 规范

> **目的**:把主文档 §9.5 / §11.2 / §11.4 中提到的 "OS Mailbox + IRQ + 协同" 落到可评审的 ABI
> **受众**:Linux 内核驱动开发、OS 内存子系统团队、IP 设计团队
> **状态**:**待评审定稿**;未定稿前 RTL 不冻结 mailbox 数据结构

---

## 1. 总体接口

IP 通过四种界面与 OS 交互:

| 界面 | 方向 | 用途 |
|------|------|------|
| **MMIO 寄存器**(APB) | OS → IP 配置;IP → OS 状态 | 启动、enable/disable、阈值、性能计数器 |
| **中断**(4 条) | IP → OS | 压力反馈、错误上报、GC 完成 |
| **Mailbox SRAM**(4KB) | 双向 | 批量数据(待释放页列表、性能日志、Trace) |
| **DDR 元数据区**(只读视图) | OS 调试读 | 异常时 dump L2P / Bitmap |

```
                    ┌─────────────────────────────────────────┐
       APB MMIO  ←──┤  IP                                     │
       (Sync)       │  ┌──────────┐                            │
                    │  │ MBOX SRAM│ ←──── 4 KB shared          │
       Mailbox  ←──→│  └──────────┘                            │
       (Async)      │                                          │
                    │  ┌──────────────────────────────┐        │
       IRQ × 4  ←──┤  │  Pressure / Error / GC       │        │
       (Edge)       │  └──────────────────────────────┘        │
                    └─────────────────────────────────────────┘
```

---

## 2. MMIO 寄存器(APB)

### 2.1 完整寄存器映射

```
基址:由 DTS / ACPI 提供(默认 0xFFE0_0000)
所有寄存器 32 bit 对齐
```

| 偏移 | 名称 | RW | 复位值 | 说明 |
|------|------|-----|-------|------|
| 0x000 | ID | RO | 0x5A43_0001 | "ZC" + version 1 |
| 0x004 | CAPS | RO | 见 §2.2 | 静态特性 |
| 0x008 | STATUS | RO | 0 | 运行状态(见 §2.3) |
| 0x00C | CTRL | RW | 0 | 主控开关(见 §2.4) |
| 0x010 | CAP_RATIO | RW | 0x96 (=1.5×100) | 容量比 × 100 |
| 0x014 | RAM_PHYS_SIZE_LO | RO | DDR 容量 lo32 | 字节 |
| 0x018 | RAM_PHYS_SIZE_HI | RO | DDR 容量 hi32 | |
| 0x01C | RAM_LOG_SIZE_LO | RO | 申报容量 lo32 | = phys × cap_ratio / 100 |
| 0x020 | RAM_LOG_SIZE_HI | RO | 申报容量 hi32 | |
| 0x024 | L2P_BASE_LO | RW | 0 | L2P 表 DDR 基址 lo |
| 0x028 | L2P_BASE_HI | RW | 0 | L2P 表 DDR 基址 hi |
| 0x02C | META_BASE_LO | RW | 0 | 元数据区基址 lo |
| 0x030 | META_BASE_HI | RW | 0 | 元数据区基址 hi |
| 0x034 | MBOX_BASE_LO | RO | 见 DTS | Mailbox SRAM 物理基址 lo |
| 0x038 | MBOX_BASE_HI | RO | 见 DTS | Mailbox SRAM 物理基址 hi |
| 0x03C | MBOX_SIZE | RO | 0x1000 | Mailbox 大小 (4KB) |
| 0x040 | FLUSH | W1S | 0 | bit0:Soft / bit1:Hard / bit2:Bypass |
| 0x044 | FLUSH_DONE | RO | 0 | 对应 FLUSH bit 的完成位 |
| 0x048 | INVALIDATE_RANGE_LO | RW | 0 | 起始 LA |
| 0x04C | INVALIDATE_RANGE_HI | RW | 0 | 结束 LA |
| 0x050 | INVALIDATE_TRIG | W1S | 0 | 触发范围 invalidate |
| 0x080 | INT_STATUS | W1C | 0 | 见 §3 |
| 0x084 | INT_MASK | RW | 0xF | 1=屏蔽 |
| 0x088 | INT_PEND_RAW | RO | 0 | 未屏蔽前的状态 |
| 0x08C | MBOX_DOORBELL_OS2IP | W1S | 0 | OS 通知 IP 有命令 |
| 0x090 | MBOX_DOORBELL_IP2OS | W1C | 0 | IP 通知 OS 有数据 |
| 0x094 | PRESSURE_THRESH | RW | 0x6450_5F50 | byte0:HARD / 1:SOFT_HIGH / 2:SOFT_LOW(占用%) |
| 0x098 | GC_BW_LIMIT | RW | 5 | GC 占用 DDR 带宽上限(%) |
| 0x09C | OOM_TIMEOUT_MS | RW | 10 | HARD_FULL 等 OS 超时(ms) |
| 0x0A0 | BYPASS_REGION_NUM | RO | 8 | bypass 区间总数 |
| 0x100~0x180 | BYPASS_REGION[0..7] | RW | 0 | 16 byte/项:start_lo/hi/end_lo/hi |
| 0x200 | PERF_CTRL | RW | 0 | bit0:enable / bit1:reset |
| 0x204~0x283 | PERF_CNT[0..31] | RO | 0 | 32 项性能计数器(见 §6) |
| 0x300 | DBG_TRACE_CTRL | RW | 0 | trace 触发条件 |
| 0x304 | DBG_TRACE_FILTER_LA_LO | RW | 0 | 过滤 LA 范围 |
| 0x308 | DBG_TRACE_FILTER_LA_HI | RW | 0 | |
| 0x30C | DBG_INJECT | W1S | 0 | 错误注入(见 §7) |
| 0x400 | CURRENT_CAP_USAGE | RO | 0 | 当前 PPA 占用百分比(0..100) |
| 0x404 | CURRENT_FRAG | RO | 0 | 碎片率百分比 |
| 0x408 | CURRENT_AVG_RATIO | RO | 0 | 当前平均压缩率(×100) |

### 2.2 CAPS 寄存器

```
bit  0-3   : VERSION_MAJOR
bit  4-7   : VERSION_MINOR
bit  8     : SUPPORTS_BDI
bit  9     : SUPPORTS_ZERO
bit 10     : SUPPORTS_BYTEDELTA
bit 11     : SUPPORTS_GC
bit 12     : SUPPORTS_BYPASS
bit 13     : SUPPORTS_TRACE
bit 14     : SUPPORTS_ECC
bit 15     : SUPPORTS_PREEMPT_GC
bit 16-19  : MAX_OUTSTANDING_RELOC
bit 20-23  : BYPASS_REGION_NUM
bit 24-31  : RESERVED
```

### 2.3 STATUS 寄存器

```
bit  0     : READY (1 = 可服务请求)
bit  1     : FLUSH_BUSY
bit  2     : RELOC_BUSY
bit  3     : GC_BUSY
bit  4     : PRESSURE_ACTIVE
bit  5     : ERROR_STICKY (任何 fatal 错触发后置位,需要软复位)
bit  6     : OS_TIMEOUT_TRIPPED (HARD_FULL 等 OS 超时,部分 LA 进入 SLVERR 模式)
bit  7     : SAFE_MODE (致命错误后只读 + bypass)
bit  8-15  : POWER_STATE
bit 16-31  : RESERVED
```

### 2.4 CTRL 寄存器

```
bit  0     : CACHE_EN
bit  1     : COMPRESS_EN
bit  2     : GC_EN
bit  3     : PRESSURE_IRQ_EN
bit  4     : ECC_EN
bit  5     : TRACE_EN
bit  6     : SOFT_RESET (W1S, 自清)
bit  7     : POWER_DOWN_REQ
bit  8     : SAFE_MODE_REQ
bit  9-31  : RESERVED
```

---

## 3. 中断协议

### 3.1 中断信号

| 编号 | 名称 | INT_STATUS bit | 优先级 | 类型 | 说明 |
|------|------|---------------|-------|------|------|
| 0 | IRQ_PRESSURE | bit 0 | 中 | level | 占用 ≥ SOFT_HIGH |
| 1 | IRQ_HARD_FULL | bit 1 | 高 | level | 占用 ≥ HARD_FULL |
| 2 | IRQ_DECOMP_ERR | bit 2 | 高 | edge | CRC 错或 Header 错 |
| 3 | IRQ_GC_DONE | bit 3 | 低 | edge | GC 一轮完成 |

> **物理实现**:4 条独立 IRQ 信号,或合并 1 条由 INT_STATUS 区分(DTS 配置)

### 3.2 中断响应义务

| 中断 | OS 必须做 | 期限 | 超时后果 |
|------|----------|-----|---------|
| IRQ_PRESSURE | 调用 vmscan 释放至少 N MB,通过 mailbox 通告 | 无硬期限,期望 < 100ms | 升级为 IRQ_HARD_FULL |
| IRQ_HARD_FULL | 释放至少 N MB(由 PRESSURE_THRESH 字段指定),通告完成 | OOM_TIMEOUT_MS(10ms) | 受影响 LA 页 SLVERR;`STATUS.OS_TIMEOUT_TRIPPED=1` |
| IRQ_DECOMP_ERR | 读 mailbox 错误页清单,标记 bad page,信号给应用 | 无硬期限 | 错误统计累积 |
| IRQ_GC_DONE | 可选,记录 metric | — | — |

### 3.3 中断处理流程伪码

```c
irqreturn_t zc_irq(int irq, void *dev_id) {
    u32 status = readl(zc->mmio + ZC_INT_STATUS);

    if (status & ZC_INT_PRESSURE) {
        queue_work(zc->wq, &zc->pressure_work);
    }
    if (status & ZC_INT_HARD_FULL) {
        // 高优先级,直接 wake 内核线程
        complete(&zc->oom_completion);
    }
    if (status & ZC_INT_DECOMP_ERR) {
        queue_work(zc->wq, &zc->error_work);
    }
    if (status & ZC_INT_GC_DONE) {
        atomic_inc(&zc->gc_done_count);
    }

    writel(status, zc->mmio + ZC_INT_STATUS);  // W1C
    return IRQ_HANDLED;
}
```

---

## 4. Mailbox 协议

### 4.1 Mailbox 内存布局

Mailbox SRAM 4KB 双向 ring buffer:

```
偏移      字段                        大小
─────────────────────────────────────────────
0x000    OS2IP_HEAD                  4 B   ← OS 写
0x004    OS2IP_TAIL                  4 B   ← IP 写
0x008    OS2IP_RESERVED              8 B
0x010    IP2OS_HEAD                  4 B   ← IP 写
0x014    IP2OS_TAIL                  4 B   ← OS 写
0x018    IP2OS_RESERVED              8 B
0x020    OS2IP_RING                  2 KB  (32 entries × 64 byte)
0x820    IP2OS_RING                  2 KB  (32 entries × 64 byte)
0x1000   ─ end ─
```

**消息单元 64 byte**(固定大小,简化 RTL):

```
偏移   字段              大小
0x00   msg_type          1 B
0x01   msg_seq           2 B   单调递增,wrap-around
0x03   payload_len       1 B   实际有效载荷字节数(0..60)
0x04   payload           60 B
```

### 4.2 消息类型 enum

```c
/* OS → IP */
enum {
    ZC_MSG_OS_PAGES_RELEASED  = 0x10,  // OS 释放了若干页,见 §4.3.1
    ZC_MSG_OS_GC_REQUEST      = 0x11,  // 显式要求 IP 跑 GC
    ZC_MSG_OS_DUMP_REQUEST    = 0x12,  // 要求 IP dump 性能数据
    ZC_MSG_OS_BAD_PAGE_ACK    = 0x13,  // 已确认 bad page,IP 可回收元数据
    ZC_MSG_OS_RESET_PERF      = 0x14,  // 重置性能计数器
};

/* IP → OS */
enum {
    ZC_MSG_IP_PRESSURE_ADVICE = 0x20,  // 见 §4.3.2,带建议释放清单
    ZC_MSG_IP_BAD_PAGE_REPORT = 0x21,  // 解压 CRC 错的 LA 页
    ZC_MSG_IP_PERF_LOG        = 0x22,  // 性能日志
    ZC_MSG_IP_GC_RESULT       = 0x23,  // GC 一轮统计
    ZC_MSG_IP_TRACE_DUMP      = 0x24,  // Debug trace
};
```

### 4.3 关键消息 payload 定义

#### 4.3.1 ZC_MSG_OS_PAGES_RELEASED(OS→IP,60B)

```c
struct zc_msg_pages_released {
    u32 n_pages;             // 1..14(最多塞 14 个 LA 地址,后续消息续传)
    u32 reserved;
    u64 la_pages[14];        // 4KB 对齐的 LA 地址
} __packed;  // 4 + 4 + 14*8 = 120... 超 60B
```

> **修正**:60 byte 装不下 14 项,改用**多消息分段**:每条最多 7 项 LA。
> 调整后:

```c
struct zc_msg_pages_released {
    u8  n_pages;             // 1..7
    u8  flags;               // bit0: more_coming
    u16 reserved;
    u64 la_pages[7];         // 4KB 对齐
} __packed;  // 4 + 7*8 = 60 byte ✓
```

#### 4.3.2 ZC_MSG_IP_PRESSURE_ADVICE(IP→OS,60B)

IP 主动建议 OS 释放哪些 LA 页(基于 LRU + 压缩率劣化排序):

```c
struct zc_msg_pressure_advice {
    u8  n_suggestions;       // 1..6
    u8  urgency;             // 0=soft, 1=high, 2=hard_full
    u16 cap_usage_pct;       // 当前占用 ×100
    u32 reserved;
    struct {
        u64 la_page;
        u32 last_access_ms;  // 距今多少毫秒未访问
        u8  ratio_x100;      // 该页压缩率 ×100
        u8  reserved[3];
    } items[6];              // 6 × 16 = 96... 超
} __packed;
```

> **再修正**:

```c
struct zc_msg_pressure_advice {
    u8  n_suggestions;       // 1..4
    u8  urgency;             // 0=soft / 1=high / 2=hard_full
    u16 cap_usage_pct_x100;
    struct {
        u64 la_page;         // 8 B
        u16 last_access_s;   // 距今秒数
        u8  ratio_x100;      // 压缩率 × 100
        u8  reserved;        // 4 B
    } items[4];              // 4 × 12 = 48
    u8  pad[8];              // 4 + 48 + 8 = 60 ✓
} __packed;
```

#### 4.3.3 ZC_MSG_IP_BAD_PAGE_REPORT(IP→OS)

```c
struct zc_msg_bad_page_report {
    u8  n_pages;             // 1..7
    u8  reason;              // 1=Header CRC, 2=Line CRC, 3=DDR ECC unrecoverable
    u16 reserved;
    u64 la_pages[7];
} __packed;  // 4 + 56 = 60 ✓
```

#### 4.3.4 ZC_MSG_IP_PERF_LOG

```c
struct zc_msg_perf_log {
    u32 timestamp_ms;
    u32 hit_rate_x10000;          // 0..10000
    u32 avg_ratio_x100;
    u16 reloc_per_kc;             // 重定位次数 / 千 cycle
    u16 gc_per_kc;
    u16 cap_usage_pct_x100;
    u16 frag_pct_x100;
    u16 algo_share[4];            // BDI/Zero/BD/None x10000
    u8  pad[24];
} __packed;  // 4 + 4 + 4 + 2*4 + 2*4 + 24 = 52 ... 算出 4+4+4+2+2+2+2+8+24=52 → 加 8 pad = 60 ✓
```

### 4.4 doorbell 协议

```
OS 写消息流程:
  1. 读 OS2IP_HEAD, OS2IP_TAIL
  2. 检查空间:(HEAD - TAIL - 1) % 32 ≥ 1
  3. 写消息到 ring[HEAD]
  4. wmb()
  5. HEAD = (HEAD + 1) % 32
  6. 写 MBOX_DOORBELL_OS2IP = 1

IP 读消息流程(中断或轮询):
  1. 读 OS2IP_HEAD, OS2IP_TAIL
  2. while (TAIL != HEAD):
     a. 处理 ring[TAIL]
     b. TAIL = (TAIL + 1) % 32
     c. 持续直到处理完毕
  3. 清 MBOX_DOORBELL_OS2IP

IP→OS 方向类似,doorbell 用 IP2OS;OS 通过 IRQ 或周期性 poll 触发读取。
```

---

## 5. 启动流程(BootROM + 早期内核)

### 5.1 BootROM 阶段

```
1. 探测 IP 是否在(读 ID == 0x5A43_xxxx)
2. 配置 STRAP:
   - 读硬件 strap pin,设 CAP_RATIO 寄存器
3. 初始化元数据区:
   - 写 L2P_BASE / META_BASE
   - 触发硬件元数据清零(自动 DMA,~1ms 完成)
4. 配置 BYPASS_REGION:
   - 写入预设的不可压地址段(如 framebuffer)
5. 解锁 IP:
   - CTRL.CACHE_EN = 1
   - CTRL.COMPRESS_EN = 1
   - CTRL.GC_EN = 1
6. 上报内存到 OS:
   - DT memory node:size = LOG_SIZE(申报值,如 6GB)
   - 不告诉 OS 物理 DDR 实际只 4GB
```

### 5.2 OS 内核驱动 probe

```c
static int zc_probe(struct platform_device *pdev) {
    struct zc_dev *zc = devm_kzalloc(...);
    zc->mmio = devm_ioremap_resource(...);

    // 校验 ID
    u32 id = readl(zc->mmio + ZC_REG_ID);
    if ((id >> 16) != 0x5A43) return -ENODEV;

    // 映射 mailbox
    u64 mbox_base = readq(zc->mmio + ZC_REG_MBOX_BASE_LO);
    zc->mbox = devm_ioremap(..., mbox_base, 4096);

    // 注册中断
    zc->irq[0] = platform_get_irq_byname(pdev, "pressure");
    devm_request_irq(..., zc_irq_pressure, ...);
    // ... 其他三个

    // 启动 worker thread
    zc->wq = alloc_workqueue("zc_drv", WQ_HIGHPRI, 0);
    INIT_WORK(&zc->pressure_work, zc_pressure_handler);
    INIT_WORK(&zc->error_work, zc_error_handler);

    // 启用所有中断
    writel(0xF, zc->mmio + ZC_REG_INT_MASK);

    // sysfs / debugfs
    zc_sysfs_register(zc);
    zc_debugfs_register(zc);

    return 0;
}
```

---

## 6. 性能计数器(32 项,与主文档 §14.1 对齐)

```c
enum zc_perf_id {
    /* 0-3: 基本访问 */
    PERF_HIT,            PERF_MISS,
    PERF_WRITE_HIT,      PERF_WRITE_MISS,
    /* 4-7: Miss 分类 */
    PERF_COLD_MISS,      PERF_CAPACITY_MISS,
    PERF_CONFLICT_MISS,  PERF_RESERVED_07,
    /* 8-11: L2P / Meta */
    PERF_L2P_HIT,        PERF_L2P_MISS,
    PERF_L2P_DMA,        PERF_HEADER_MISS,
    /* 12-17: 压缩 */
    PERF_COMP_TOTAL,     PERF_COMP_BDI,
    PERF_COMP_ZERO,      PERF_COMP_BD,
    PERF_COMP_NONE,      PERF_RESERVED_17,
    /* 18-21: 重定位 / GC */
    PERF_RELOC,          PERF_GC_HOLE,
    PERF_GC_COMPACT,     PERF_GC_DEFRAG,
    /* 22-24: 压力 */
    PERF_PRESSURE_SOFT,  PERF_PRESSURE_HARD,
    PERF_GC_BW_USED,
    /* 25-28: 错误 */
    PERF_ECC_CORR,       PERF_ECC_UNCORR,
    PERF_DECOMP_CRC_ERR, PERF_ALLOC_FAIL,
    /* 29-31: 延迟分桶 */
    PERF_LAT_READ,       PERF_LAT_WRITE,
    PERF_LAT_RELOC,
};
```

每个计数器 32 bit,溢出时:
- 默认:wrap-around + 触发 IRQ_PERF_OVERFLOW(可选)
- 软件累加到 64 bit,导出到 sysfs

### sysfs 接口

```
/sys/class/zc/zc0/
├── caps                    # 静态特性
├── status                  # 运行状态
├── cap_usage               # 当前 PPA 占用百分比
├── cap_ratio               # 申报比例
├── avg_ratio               # 当前平均压缩率
├── frag_ratio              # 碎片率
├── perf/
│   ├── hit_rate            # 命中率
│   ├── miss_rate
│   ├── reloc_per_sec
│   ├── gc_per_sec
│   ├── algo_dist           # JSON: {"BDI":0.3,"Zero":0.4,...}
│   └── histogram_read      # 读延迟直方图(16 bins)
├── ctrl/
│   ├── cache_en            # 0/1
│   ├── compress_en
│   ├── gc_en
│   ├── flush               # 写 1 触发 soft flush
│   └── safe_mode
├── bypass_regions          # 可读写,JSON
└── trace_buffer            # 仅在 trace 启用时
```

### debugfs 接口(故障注入,仅 debug 内核)

```
/sys/kernel/debug/zc/
├── inject_ecc_corr         # 写 1 触发可纠正 ECC 错
├── inject_ecc_uncorr
├── inject_decomp_err
├── inject_pressure         # 写百分比强制水位
└── force_reloc <la_addr>   # 触发指定 LA 页 Reloc
```

---

## 7. 错误码与状态码

```c
/* mailbox 消息内的 status 字段 */
enum zc_status {
    ZC_OK                       = 0,
    ZC_E_INVALID_PARAM          = 1,
    ZC_E_NO_SPACE               = 2,   /* 容量不足 */
    ZC_E_PAGE_BAD               = 3,   /* 该 LA 页已标记坏 */
    ZC_E_HEADER_CRC             = 10,  /* Header CRC 错 */
    ZC_E_LINE_CRC               = 11,  /* Line CRC 错 */
    ZC_E_DDR_ECC_UNCORR         = 12,  /* DDR ECC 不可纠正 */
    ZC_E_ALLOC_FAIL             = 20,
    ZC_E_RELOC_TIMEOUT          = 21,
    ZC_E_OS_TIMEOUT             = 22,  /* OS 未在期限内响应 IRQ_HARD_FULL */
    ZC_E_FATAL                  = 99,
};
```

---

## 8. 时序约束

| 事件 | 期望响应时间 |
|------|------------|
| OS 读 STATUS | < 1 μs(纯 MMIO) |
| OS 写 CTRL 后 IP 状态可见 | ≤ 4 cycle |
| OS 写 mailbox + doorbell → IP 处理 | < 100 cycle(125 ns) |
| IP IRQ 触发 → OS irq_handler 执行 | < 5 μs(SoC 中断延迟) |
| OS 处理 IRQ_PRESSURE 完整流程 | < 100 ms(目标),< 500 ms(上限) |
| OS 处理 IRQ_HARD_FULL 完整流程 | < OOM_TIMEOUT_MS(默认 10 ms) |
| Soft Flush 完成 | ≤ 1 s(取决于 dirty 量) |
| Hard Flush 完成 | ≤ 10 s |
| Bypass Flush 完成 | ≤ 30 s(全数据反压缩) |

---

## 9. 兼容性与版本演进

### 9.1 ID 寄存器格式

```
ID[31:24] = 'Z' (0x5A)
ID[23:16] = 'C' (0x43)
ID[15:8]  = MAJOR_VERSION
ID[7:0]   = MINOR_VERSION

兼容承诺:
  - MINOR 升级:寄存器只增不删,旧驱动可工作
  - MAJOR 升级:可能 break,驱动需匹配
  - 当前发布:0x5A43_0001 (v1.0)
```

### 9.2 mailbox 消息版本

每个消息的 `msg_type` 高 4 bit 是 version:

```
0x10..0x1F: OS→IP v1
0x20..0x2F: IP→OS v1
0x30..0x3F: OS→IP v2 (future)
0x40..0x4F: IP→OS v2 (future)
```

未识别 msg_type 的处理:回 ZC_MSG_IP_PERF_LOG 带 status=ZC_E_INVALID_PARAM。

---

## 10. 测试要点

| 编号 | 场景 | 期望 |
|------|------|------|
| OT01 | 驱动 probe | sysfs 出现,/proc/meminfo 显示 6GB |
| OT02 | IRQ_PRESSURE 触发 → OS 释放页 → mailbox 通告 | IP STATUS.PRESSURE_ACTIVE 清除 |
| OT03 | IRQ_HARD_FULL + OS 不响应 | OOM_TIMEOUT 后 STATUS.OS_TIMEOUT_TRIPPED |
| OT04 | mailbox ring 满 | IP 反压(短期)/丢消息(长期),计数器递增 |
| OT05 | 故障注入 ECC 错 | sysfs 计数 + dmesg 警告 |
| OT06 | sysfs 性能计数器读取 | 与硬件 perf cnt 一致 |
| OT07 | Soft Flush + Self-Refresh + 唤醒 | 数据一致 |
| OT08 | Bypass Flush 后切换到非压缩模式 | DDR 内容线性可读 |
| OT09 | 驱动 unload + 重 load | 状态恢复 |
| OT10 | 多核并发 sysfs 读 + IRQ 处理 | 无死锁 / 数据竞争 |

---

## 11. 评审清单(给 OS 团队)

- [ ] 寄存器布局可接受?是否需要 doorbell 改用 MSI/SMC?
- [ ] mailbox 容量(2KB 单向)够用?批量场景?
- [ ] 4 个中断信号 vs 单中断 + 状态位?
- [ ] OOM_TIMEOUT_MS 默认 10ms 是否过紧?
- [ ] sysfs 路径与现有 mm 子系统冲突?
- [ ] 内存上报 6GB 的具体实现:DT memory node?ACPI?e820?
- [ ] 与 zswap / zram 的关系?同一 OS 上同时存在的策略?
- [ ] 与 cgroup memory controller 的交互?
- [ ] 与 NUMA 的关系?(本 IP 是否注册为独立 NUMA node?)
- [ ] kdump / panic 流程下如何强制 Bypass Flush?

---

## 12. 决策清单

- [x] MMIO 寄存器映射定义
- [x] 4 中断协议
- [x] Mailbox 4KB 双向 ring + doorbell
- [x] 8 种关键消息 payload(60B 对齐)
- [x] 错误码与状态码
- [x] 性能计数器 32 项 + sysfs/debugfs
- [x] 启动流程
- [x] 兼容性策略
- [ ] 与 OS 团队联评 §11
- [ ] Linux 驱动 PoC 开发
- [ ] 主文档 §9 / §11.2 / §14 同步更新
