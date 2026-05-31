# RTL-1 / 模块 07:l2p_meta_cache(L2P + Page Header 共池缓存)

> **角色**:缓存热门 L2P Block 与 Page Header,避免每次 Miss 串行两次 DDR 访问。2-way,L2P 区 + Header 区共池。
> **代码**:[rtl/l2p_meta_cache.sv](../../rtl/l2p_meta_cache.sv)
> **架构出处**:§5.5 / §8.2 / §8.3.1(命中率决定 Miss 延迟);接口分组 (F)。

---

## 1. 功能与边界

| 做什么 | 不做什么 |
|--------|---------|
| 缓存 256 个 L2P Block(8KB,每 Block=8 Entry)+ Header 区(8KB) | L2P 表 DDR 存储 |
| `o_meta_page` 查询:命中返 `l2p_entry` | miss 时的 DDR 取(l2p_dma) |
| Header 共池:命中则同时给 `i_meta_hdr` | Header 解析(mshr/reloc 用) |
| 顺序预取(N,N+1→预取 N+3 的 Block) | 压缩/解压 |
| Meta SECDED | — |

> Header 槽位对齐 192B(§5.5.2 修正),Header 区 8KB → 42 个驻留;META_BYTES 可配 32KB 提升命中率。

---

## 2. 端口表(冻结)

| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `clk`/`rst_n` | in | 1 | |
| **(F) ← mshr / reloc** | | | |
| `i_lookup` | in | 1 | 查询请求 |
| `i_page` | in | LA_PAGE_W | 要查的 LA 页号 |
| `i_want_hdr` | in | 1 | 是否同时要 Page Header |
| `o_hit` | out | 1 | L2P 命中 |
| `o_entry` | out | l2p_entry_t | 命中的 L2P entry |
| `o_hdr_valid` | out | 1 | Header 也在共池 |
| `o_hdr` | out | HEADER_BYTES*8 | Header 数据 |
| **↔ l2p_dma(miss 时回填)** | | | |
| `o_dma_req` | out | 1 | 请求从 DDR 取 Block(+Header) |
| `o_dma_page` | out | LA_PAGE_W | |
| `o_dma_want_hdr`/`o_dma_ppa` | out | — | 取 Header 用 PPA Ptr |
| `i_dma_valid` | in | 1 | 回填有效 |
| `i_dma_block` | in | L2P_BLOCK_BYTES*8 | 64B = 8 entry |
| `i_dma_hdr_valid`/`i_dma_hdr` | in | — | Header 回填 |
| **L2P 写(reloc/evict 更新映射)** | | | |
| `i_wr_en`/`i_wr_page`/`i_wr_entry` | in | — | 更新某 LA 页的 entry |
| **配置 / 采样** | | | |
| `i_cfg_l2p_base` | in | DPA_ADDR_W | L2P 表基址 |
| `o_perf_hit`/`o_perf_miss`/`o_perf_hdr_miss` | out | 1 | 性能脉冲 |

---

## 3. 内部结构

```
 Meta SRAM 16KB(2-way):
   ┌──────────────────────┐ 0
   │ L2P Block 区 8KB      │ 256 Block × 64B(每 Block 8 个 8B entry)
   ├──────────────────────┤ 8KB
   │ Header 区 8KB         │ 42 槽 × 192B(176B Header 上对齐 192)
   └──────────────────────┘ 16KB

 查询:i_page → block_addr = page>>3(8 entry/Block);entry_sel = page[2:0]
       tag 比较(2-way)→ hit → 选 entry
 Header:L2P hit 后,若该页 Header 在 Header 区(独立 tag)→ o_hdr_valid
 替换:L2P Block LRU;Header 跟随其 Block(同页 Header 优先驻留,§5.5.3)
 预取:连续 page 命中检测 → o_dma_req 预取 page+3 的 Block
```

---

## 4. 波形

### 4.1 L2P 命中 + Header 共池命中(最优:0 次 DDR)

```
cycle        T0     T1
            ────   ────
i_lookup     1      0
i_page       P      -
i_want_hdr   1      -
o_hit        -      1        ← 1 拍 SRAM 读 + tag 比较
o_entry      -      ENT
o_hdr_valid  -      1
o_hdr        -      HDR
o_perf_hit   -      1
```

### 4.2 L2P miss → 触发 l2p_dma 回填

```
cycle        T0     T1      T2 ...        Tn       Tn+1
            ────   ────                  ────     ────
i_lookup     1      0
o_hit        -      0                              ← miss
o_dma_req    -      1       0                       ← 请求 DDR 取 Block
o_dma_page   -      P
i_dma_valid  -      -       .            1          ← l2p_dma 回填(约 64 cyc)
i_dma_block  -      -       -            BLK
(写入 SRAM,后续同页查询命中)
o_perf_miss  -      1
```

### 4.3 顺序预取

```
连续命中 P, P+1 → 检出顺序流 → o_dma_req 预取 P+3 的 Block(后台,不阻塞当前)
```

---

## 5. 验证要点

| 编号 | 场景 | 期望 |
|------|------|------|
| MC01 | L2P 命中 | 1 拍返回 entry |
| MC02 | Header 共池命中 | o_hdr_valid + 正确 Header |
| MC03 | L2P miss | o_dma_req,回填后命中 |
| MC04 | Header miss(L2P 命中) | o_hdr_valid=0,上层另取 |
| MC05 | L2P 写更新(reloc) | 后续查询见新 entry |
| MC06 | 顺序预取 | P,P+1 后预取 P+3 |
| MC07 | 2-way 替换 | LRU 正确 |
| MC08 | Meta ECC 错 | corr/uncorr 上报 |

---

## 6. 决策清单
- [x] 端口冻结 + 共池组织 + 预取策略
- [x] **L2P block 缓存已实现**:[l2p_meta_cache.sv](../../rtl/l2p_meta_cache.sv) —— 写穿直映射,
      lookup FSM(命中即返回 / miss→l2p_dma 取块回填),写=更新块内 entry + write-through(写 miss 先 fetch)。
      接口对齐 miss 引擎(rd/o_valid/o_entry + wr/o_done),可作 L2P 模型 drop-in。
- [x] **子系统验证**(Questa 0/0):`dv/sim/sub_l2p.do` → `tb_sub_l2p: ALL PASS`
      (命中 / 同 block 多 entry 共享 / 冲突淘汰+write-through+refetch 值保留)
- [ ] 2-way LRU + 顺序预取(§5.5.3)+ Page Header 共池 + Meta SECDED + 接入 miss 引擎(替代直查 L2P 模型)
- [ ] UVM MC01-MC08
