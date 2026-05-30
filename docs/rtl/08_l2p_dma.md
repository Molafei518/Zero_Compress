# RTL-1 / 模块 08:l2p_dma(元数据 DMA 引擎)

> **角色**:Meta Cache miss 时,从 DDR 取 L2P Block(64B)与 Page Header(176B),回填 Meta Cache。可并行/链式发起以隐藏延迟(§8.3.2)。
> **代码**:[rtl/l2p_dma.sv](../../rtl/l2p_dma.sv)
> **架构出处**:§3.2.4 / §8.3 / §8.3.2(三跳并行预取);接口分组 (F)→下游 m_axi(ID class=IDC_META)。

---

## 1. 功能与边界

| 做什么 | 不做什么 |
|--------|---------|
| 收 meta 的 `dma_req` → 算 DDR 地址 → 发下游读 | Meta Cache 存储(l2p_meta_cache) |
| L2P Block 地址 = `l2p_base + page*8` 向 64B 对齐 | L2P 表内容解析 |
| Header 地址 = `ppa_to_byte(entry.ppa_ptr)` | 压缩页数据读(mshr 直接发) |
| **并行发起 L2P+Header+Line**(§8.3.2,把 3 跳折叠) | 命中判定 |
| 下游用 `IDC_META` class ID | — |

---

## 2. 端口表(冻结)

| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `clk`/`rst_n` | in | 1 | |
| **← l2p_meta_cache** | | | |
| `i_req` | in | 1 | DMA 请求 |
| `i_page` | in | LA_PAGE_W | LA 页号(算 L2P 地址) |
| `i_want_hdr` | in | 1 | 是否一并取 Header |
| `i_ppa_ptr` | in | 32 | 取 Header 用(若已知 entry) |
| `o_busy` | out | 1 | DMA 忙 |
| **→ l2p_meta_cache(回填)** | | | |
| `o_valid` | out | 1 | 回填有效 |
| `o_block` | out | L2P_BLOCK_BYTES*8 | 64B Block |
| `o_hdr_valid`/`o_hdr` | out | — | Header(176B) |
| **配置** | | | |
| `i_cfg_l2p_base` | in | DPA_ADDR_W | L2P 表基址 |
| **下游 DDR 读(经 m_axi,ID=IDC_META)** | | | |
| `o_rd_req`/`o_rd_addr`/`o_rd_len` | out | — | 读事务 |
| `i_rd_valid`/`i_rd_data`/`i_rd_last` | in | — | 返回 |

---

## 3. 地址计算与 FSM

```
L2P Block 字节地址:
  l2p_byte = i_cfg_l2p_base + (i_page * 8)            // 每 entry 8B
  block_aligned = l2p_byte & ~(64-1)                  // 64B Block 对齐

Header 字节地址:
  hdr_byte = ppa_to_byte(i_ppa_ptr)                   // = ppa_ptr<<6

FSM:S_IDLE → S_RD_L2P → (并行/接力) S_RD_HDR → S_FILL → S_IDLE
  - 优化(§8.3.2):L2P Block 返回后立刻可算 ppa_ptr → 同一突发/相邻 Bank 取 Header,
    省掉 "等 Header 地址" 的串行。若调用方已传 i_ppa_ptr,则 L2P 与 Header 读可同时发。
```

---

## 4. 波形

### 4.1 取 L2P Block(64B,~64 cyc DDR)

```
cycle        T0     T1      ...        T64     T65
            ────   ────                ────    ────
i_req        1
o_busy       0      1                          0
o_rd_req     -      1       0
o_rd_addr    -      L2P_ALIGNED
i_rd_valid   -      -       .          1(burst 返回)
o_valid      -      -       -          -        1     ← 回填 Meta Cache
o_block      -      -       -          -        BLK
```

### 4.2 L2P + Header 接力(L2P 回来后算地址再取 Header)

```
cycle        T0    T1     ..T64    T65     ..T129   T130
            ────  ────            ────             ────
o_rd_req     -    1(L2P)  0       1(HDR)  0
i_rd_valid   -    -       1       -       1
（算 ppa_ptr）              ▲ L2P 到,得 entry.ppa_ptr → 发 Header 读
o_valid      -    -       -       -       -        1   ← Block+Header 一并回填
o_hdr_valid  -    -       -       -       -        1
```
> 若调用方已知 `i_ppa_ptr`,L2P 与 Header 两笔可在 T1 同时发(§8.3.2),总延迟 ~64 而非 ~128。

---

## 5. 验证要点

| 编号 | 场景 | 期望 |
|------|------|------|
| LD01 | 取 L2P Block | 地址对齐正确,回填 64B |
| LD02 | L2P+Header 接力 | ppa_ptr 正确,两笔都回填 |
| LD03 | 已知 ppa_ptr 并行取 | 两笔同时发,延迟≈1 跳 |
| LD04 | 下游 ID = IDC_META | ID class 正确,不撞 master |
| LD05 | 背靠背多次 req | 串行/流水正确,o_busy 准确 |

---

## 6. 决策清单
- [x] 端口冻结 + 地址计算 + 并行预取策略
- [ ] RTL(FSM + 下游 AXI 读事务 + 回填)
- [ ] UVM LD01-LD05
