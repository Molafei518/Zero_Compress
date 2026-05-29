# RTL-0:顶层接口与全局参数冻结

> **目的**:在逐模块 RTL 之前,冻结(1)全局参数与派生几何、(2)顶层端口与总线、(3)内部 ID 编码、(4)模块间接口、(5)时钟/复位/CDC、(6)命名约定。
> **代码**:[rtl/zc_pkg.sv](../../rtl/zc_pkg.sv)(参数/类型)、[rtl/zc_if.sv](../../rtl/zc_if.sv)(AXI/APB 接口)、[rtl/cache_compress_top.sv](../../rtl/cache_compress_top.sv)(顶层骨架)。
> **依赖**:架构主文档 §3 / §4 / §5 / §9 / §12。
> **冻结等级**:参数与 L2P/Header 结构改动需 rev 本文件 + 文档 02。

---

## 1. 顶层框图(RTL 层次)

```
                       From Arbiter (zc_axi_if.slave  s_axi)
                                   │
                          ┌────────┴────────┐
                          │   req_buffer    │  outstanding 跟踪 + burst 拆分
                          └────────┬────────┘
                                   │ (A)
                          ┌────────┴────────┐
                          │   addr_decode   │  Bypass/NCA 判定(8 区间)
                          └────────┬────────┘
                                   │ (B)
                   ┌───────────────┴───────────────┐
                   │       cache_pipe_ctrl         │  4 级流水 REQ/TAG/DATA/RESP
                   │       + MSHR 控制接口          │
                   └──┬────────┬────────┬──────────┘
              (C)│   (D)│  (E)│        │(F)
            ┌──────┐ ┌──────┐ ┌──────┐ ┌──────────────┐
            │tag_  │ │data_ │ │ mshr │ │ l2p_meta_    │──(F)──┐
            │ram   │ │ram   │ │      │ │ cache        │       │
            │+ecc  │ │+ecc  │ └──────┘ │ + l2p_dma    │   ┌───┴────┐
            └──────┘ └──────┘          └──────┬───────┘   │l2p_dma │→ m_axi
                                       (G)│   │           └────────┘
                            ┌─────────────┴┐ ┌┴─────────────┐
                            │ compress_top │ │decompress_top│
                            │ (3 引擎‖)    │ │(algo 分发)   │
                            └──────┬───────┘ └──────┬───────┘
                                (H)│                │
                          ┌────────┴───────┐   ┌────┴────────┐
                          │ space_alloc    │   │ page_reloc  │
                          │ +free_list+gc  │   │ (9 状态 FSM)│
                          └────────┬───────┘   └────┬────────┘
                                   │ (H)            │
                          ┌────────┴────────────────┴───┐
                          │   resp_merge + Reorder       │──(I)── m_axi / s_axi.R/B
                          └──────────────────────────────┘
            pressure_mon ──(J)── apb_cfg ── APB / IRQ×4 / Mailbox
            perf_counter ──(K)── (旁挂,采样各模块事件)
```

字母 (A)~(K) 对应 [cache_compress_top.sv](../../rtl/cache_compress_top.sv) 第 1 节的互联网分组。

---

## 2. 全局参数(冻结值 = 出厂默认)

来源 [zc_pkg.sv](../../rtl/zc_pkg.sv) §1;派生量见 §2。**禁止在模块内重算派生量,统一引用本包**。

### 2.1 配置参数

| 参数 | 值 | 含义 | 架构出处 |
|------|----|------|---------|
| `LA_ADDR_W` | 40 | Master 逻辑地址位宽 | §12 |
| `PPA_ADDR_W` / `DPA_ADDR_W` | 32 / 32 | 内部伪物理 / DDR 物理(4GB,PPA==DPA) | §3.1 |
| `AXI_DATA_W` | 256 | AXI 单 beat 位宽 | §12 |
| `AXI_ID_W` | 10 | 上游 AXI ID 位宽 | §12 |
| `CACHE_BYTES` | 128 KB | Cache 总容量 | §5.1 |
| `N_WAY` | 4 | 路数 | §5.1 |
| `LINE_BYTES` | 64 | Cache Line | §5.1 |
| `MSHR_DEPTH` | 8 | Outstanding Miss | §5.4 |
| `META_BYTES` / `META_N_WAY` | 16 KB / 2 | Meta Cache(L2P+Header 共池) | §5.5 |
| `PAGE_BYTES` | 4096 | L2P 映射粒度 | §3.2.1 |
| `HEADER_BYTES` | 176 | Page Header(文档 02 V2) | §3.2.3 |
| `N_BYPASS_REGION` | 8 | Bypass 区间数 | §2.4 |
| `RELOC_FIFO_DEPTH` | 8 | 待处理 reloc 排队 | 文档 03 §5.4 |
| `N_PERF_CNT` | 32 | 性能计数器 | §14.1 |

### 2.2 派生几何(自动推导,见 zc_pkg §2)

| 派生量 | 公式 | 值 |
|--------|------|----|
| `N_LINES` | CACHE_BYTES/LINE_BYTES | 2048 |
| `N_SETS` | N_LINES/N_WAY | 512 |
| `IDX_W` | log2(N_SETS) | 9 |
| `OFFSET_W` | log2(LINE_BYTES) | 6 |
| `TAG_W` | LA_ADDR_W−IDX_W−OFFSET_W | 25 |
| `WAY_W` / `PLRU_W` | log2(N_WAY) / N_WAY−1 | 2 / 3 |
| `LINE_IDX_W` | log2(LINES_PER_PAGE) | 6 (LA[11:6]) |
| `LA_PAGE_W` | LA_ADDR_W−PAGE_OFFSET_W | 28 (LA[39:12]) |
| `BEATS_PER_LINE` | LINE_BYTES/BEAT_BYTES | 2 |
| `DS_ID_W` | AXI_ID_W+3 | 13 |

> **LA 地址分解**(zc_pkg 提供 `la_page_num/la_line_idx/cache_index/cache_tag` 函数):
> ```
>  LA[39:0] = | tag[24:0] (LA[39:15]) | index[8:0] (LA[14:6]) | offset[5:0] |
>  页视角   = | la_page[27:0] (LA[39:12]) | line_idx[5:0] (LA[11:6]) | byte[5:0] |
> ```
> 注:Cache index/tag 切分与"页号/页内行号"切分是**两套正交视角**,分别服务 Cache 命中判定与 L2P/Header 寻址。

---

## 3. 总线接口

### 3.1 上游 AXI4(`s_axi`,IP 为 slave)

标准 AXI4 5 通道,ID 宽 `AXI_ID_W=10`。`rresp/bresp` 用 `SLVERR` 表达压力/CRC 错。
详见 [zc_if.sv](../../rtl/zc_if.sv) `zc_axi_if`(modport `slave`)。

### 3.2 下游 AXI(`m_axi`,IP 为 master)

与上游对称,但 **ID 宽 = `DS_ID_W=13`**(= 上游 10 + 3 bit 类别前缀)。

### 3.3 下游 ID 编码(冻结)

`DS_ID = { class[2:0], sub_id }`,`class` 见 zc_pkg `ds_id_class_e`:

| class[2:0] | 含义 | sub_id 内容 |
|------------|------|-------------|
| `000` IDC_MASTER | 直通 Master 读 | 原 master id[9:0] |
| `100` IDC_EVICT | Evict 写 | MSHR idx |
| `101` IDC_RELOC | Reloc 读/写 | reloc 子序号 |
| `110` IDC_GC | GC 读/写 | gc 子序号 |
| `111` IDC_META | L2P/Header DMA | meta 请求序号 |

> 选 `DS_ID_W = AXI_ID_W+3` 的理由:让 master 读请求 id **直通**(便于下游 Bank 调度保序),内部发起的事务用独立 class 空间,二者绝不冲突。

### 3.4 APB(`apb`,IP 为 slave)

12-bit 地址 / 32-bit 数据。寄存器映射见文档 [04 §2](../04_os_driver_abi.md);RTL 由 `apb_cfg` 实现(RTL-4)。

---

## 4. 模块间接口冻结表

下表是 §1 框图中 (A)~(K) 的接口契约。每条信号在 [cache_compress_top.sv](../../rtl/cache_compress_top.sv) 第 1 节有声明;具体模块例化在各模块设计文档冻结端口后启用。

| 组 | 源 → 目的 | 关键信号 | 握手 |
|----|----------|---------|------|
| A | req_buffer → addr_decode | addr/id/is_write/len/prot/cache | valid/ready |
| B | addr_decode → cache_pipe_ctrl | addr/id/is_write/**path**(NORMAL/BYPASS/NCA) | valid/ready |
| C | pipe ↔ tag_ram | rd_en/index → rdata[N_WAY];wr_en/way/wdata;pLRU | 同步 SRAM,1 cyc |
| D | pipe ↔ data_ram | rd_en/index/way → rdata[512b];wr_en/wdata/wstrb | 同步 SRAM,1 cyc |
| E | pipe ↔ mshr | alloc/addr;full/hit_existing;state[] | 流控 |
| F | mshr ↔ l2p_meta_cache/dma | lookup_page→hit/entry/hdr;dma_req/done | 多周期 |
| G | (pipe/mshr/reloc) ↔ compress/decompress | comp_in→{algo,mode,size,out,crc8};decomp 反向 | req/done |
| H | (mshr/reloc) ↔ space_alloc | alloc_size→ack/fail/ppa_ptr;free | req/ack |
| H | (evict/gc/header) → page_reloc | trig+page → state/busy/done;block_la | 触发/回执 |
| I | resp_merge → s_axi / m_axi | resp valid/id/data/code;Reorder | valid/ready |
| J | pressure_mon/apb_cfg | waterlevel/cap_usage;cfg_*;irq_set | 寄存器/电平 |
| K | perf_counter | inc[N_PERF_CNT] 事件脉冲 | 旁挂采样 |

---

## 5. 时钟、复位与 CDC

| 域 | 时钟 | 说明 |
|----|------|------|
| 核心域 | `clk`(800MHz) | 数据通路 / Cache / 压缩 / 元数据 全部同步于此 |
| APB 域 | `pclk` | 配置寄存器;通常低频 |
| Mailbox SRAM | `clk` | IP 侧同步;OS 侧由 SoC 总线访问(双口 SRAM 隔离) |

**CDC 点(冻结)**:
1. `apb` ↔ 核心域:配置寄存器写在 APB 域采样,经 2-flop 同步器送核心域;状态/性能计数器反向同步(或用握手读)。
2. `irq`:核心域置位 → 边沿/电平,经同步器到 SoC 中断控制器(SoC 侧负责)。
3. Mailbox:双口 SRAM 物理隔离两域;ring 指针用格雷码 + 同步器(文档 04 §4.4 doorbell 协议)。

复位:`rst_n` 异步断言、同步释放(每域各自做 reset 同步器)。`presetn` 同理。

---

## 6. 命名约定(全工程统一)

| 约定 | 规则 | 示例 |
|------|------|------|
| 文件/模块 | snake_case,模块名 = 文件名 | `cache_pipe_ctrl.sv` |
| 时钟/复位 | `clk` / `rst_n`(低有效) | — |
| 端口方向前缀 | 输入 `i_` / 输出 `o_`(模块内部接口);AXI/APB 用 interface | `i_valid` / `o_addr` |
| 互联网 | `<src>_<dst>_<signal>` | `rb_ad_addr` |
| 握手 | `valid` / `ready`,源出 valid 目的出 ready | — |
| 配置 | `cfg_*`(来自 apb_cfg) | `cfg_cache_en` |
| 状态机状态 | `*_state_e` 枚举(集中在 zc_pkg) | `mshr_state_e` |
| 参数 | 全大写,集中 zc_pkg;模块可参数化覆盖但默认引用包 | `N_WAY` |
| 断言 | `// synthesis translate_off` 包裹仿真断言 | — |

---

## 7. 后续模块产出顺序(RTL-1..4)

| 批次 | 模块 | Phase | 文档编号(规划) |
|------|------|-------|----------------|
| RTL-1 | req_buffer, addr_decode, cache_pipe_ctrl, tag_ram, data_ram, mshr, l2p_meta_cache, l2p_dma | 1 | docs/rtl/01..08 |
| RTL-2 | compress_top, bdi/zero/bytedelta_compress, line_crc8, decompress_top + 三引擎, crc_check | 2 | docs/rtl/10..1x |
| RTL-3 | space_alloc, free_list, gc_engine, page_reloc | 2-3 | docs/rtl/20..23 |
| RTL-4 | pressure_mon, resp_merge, perf_counter, apb_cfg, ecc(tag/data/meta) | 1-3 | docs/rtl/30..3x |

每模块产出 = **设计文档(功能/端口/框图/FSM/时序/验证要点)+ .sv 骨架(端口冻结 + 关键结构,内部逻辑 TODO)**。

---

## 8. 决策清单

- [x] 全局参数与派生几何冻结(zc_pkg.sv)
- [x] AXI/APB 接口定义(zc_if.sv)
- [x] 顶层端口 + 互联网 + 例化层次(cache_compress_top.sv)
- [x] 下游 ID 编码冻结
- [x] 时钟/复位/CDC 点
- [x] 命名约定
- [ ] RTL-1 模块逐个展开
