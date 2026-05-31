# RTL-1 / 模块 06:mshr(Miss Status Holding Registers)

> **角色**:Miss 的多周期处理引擎。`MSHR_DEPTH=8` 项,每项一个 9 状态 FSM,串起 L2P 查询→Evict 压缩→分配→DDR 读→解压→Fill 全链;并做同地址合并与 reloc 序列化。
> **代码**:[rtl/mshr.sv](../../rtl/mshr.sv)
> **架构出处**:§5.4 / §5.7 / §8.2 / §8.4;文档 03(reloc 抢占);接口分组 (E)(F)(G)(H)。

---

## 1. 功能与边界

| 做什么 | 不做什么 |
|--------|---------|
| 8 项 outstanding miss 跟踪 | Tag/Data 命中(pipe) |
| **同地址合并**:同 line 多请求挂一个 entry 的 ReqList | 数据 SRAM 读写(经 pipe 的 fill 口) |
| 驱动 L2P 查询(meta)→ DDR 读 Header+Line → 解压 → Fill | L2P/Header 存储(l2p_meta_cache) |
| Evict:victim 脏行 → 压缩 → 决策原位/重定位 | 压缩本体(compress_top) |
| 调用 space_alloc;触发 page_reloc | 分配算法 / reloc FSM(各自模块) |
| **reloc 序列化**:同 LA 页有 reloc 在飞 → 阻塞 | reloc 状态机(page_reloc) |
| 防同 set 重复 Evict | — |

---

## 2. 端口表(冻结,按对端分组)

| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `clk`/`rst_n` | in | 1 | |
| **(E) ← cache_pipe_ctrl** | | | |
| `i_alloc` | in | 1 | Miss 请求建项 |
| `i_addr` | in | LA_ADDR_W | |
| `i_is_write` | in | 1 | Write-Allocate |
| `i_victim_way`/`i_victim_valid`/`i_victim_dirty`/`i_victim_tag` | in | — | victim 信息 |
| `o_full` | out | 1 | 无空项 |
| `o_merge` | out | 1 | 命中已有 entry(合并) |
| **fill → pipe** | | | |
| `o_fill_valid`/`i_fill_ready` | out/in | 1 | 回填握手 |
| `o_fill_index`/`o_fill_way`/`o_fill_tag`/`o_fill_data`/`o_fill_dirty` | out | — | 回填载荷 |
| **(F) ↔ l2p_meta_cache** | | | |
| `o_meta_lookup`/`o_meta_page` | out | — | L2P 查询 |
| `i_meta_hit`/`i_meta_entry`/`i_meta_hdr_valid`/`i_meta_hdr` | in | — | 结果 + Header |
| **(G) ↔ compress / decompress** | | | |
| `o_comp_req`/`o_comp_in` ... `i_comp_*` | — | — | Evict 压缩 |
| `o_decomp_req`/`o_decomp_*` ... `i_decomp_*` | — | — | Fill 解压 |
| **(H) ↔ space_alloc / page_reloc** | | | |
| `o_alloc_req`/`o_alloc_size`/`i_alloc_ack`/`i_alloc_fail`/`i_alloc_ppa` | — | — | 分配 |
| `o_reloc_trig`/`o_reloc_page`/`i_reloc_busy`/`i_reloc_done` | — | — | 触发重定位 |
| `o_block_la_valid`/`o_block_la_page` | out | — | 阻塞同 LA(给 pipe) |
| **下游 DDR(经 m_axi,内部 ID class)** | | | |
| `o_ddr_*` / `i_ddr_*` | — | — | 读 Header/Line、写 Evict/Reloc |

---

## 3. 每项 FSM(`mshr_state_e`,9 态)

```
 MSHR_IDLE
    │ i_alloc(非合并)
    ▼
 MSHR_L2P_LOOKUP ── 查 meta;miss → 触发 l2p_dma,等 i_meta_hit
    │
    ├─(victim 脏)─► MSHR_EVICT_PEND ─► MSHR_COMP_PEND(三引擎压缩)
    │                                      │ 原位够? ──No──► (触发 reloc) ──┐
    │                                      │ Yes                            │
    │                                      ▼                                │
    │                                 MSHR_DDR_WRITE(写压缩 Line+Header)    │
    └─(victim 干净/无)──────────────────────┐                              │
                                            ▼                              │
                                    MSHR_ALLOC_PEND(本 miss 需空间时)       │
                                            │ i_alloc_ack                  │
                                            ▼                              │
                                     MSHR_FILL_REQ(发 DDR 读 Header+Line) ◄─┘
                                            │ 数据返回
                                            ▼
                                   MSHR_FILL_DECOMP(解压 + CRC 校验)
                                            │ o_fill_valid & i_fill_ready
                                            ▼
                                       MSHR_DONE ─► 唤醒 ReqList,回 IDLE
```

> Evict 与 Fill 可 pipeline(§8.4):Evict 写在后台,不阻塞本 miss 的 Fill 读。
> alloc 失败(i_alloc_fail)→ 停在 ALLOC_PEND,触发 IRQ_HARD_FULL,等 OS(文档 03 §7.3 / §8)。

---

## 4. 每项寄存器(对齐 §5.4)

```
struct {
  valid;
  addr_tag        [TAG_W];        // 同地址合并比较键(+ index)
  index           [IDX_W];
  state           mshr_state_e;
  req_list        [MSHR_DEPTH];   // bitmap:挂载等待同 line 的请求(含各自 id/offset)
  way_alloc       [WAY_W];        // 目标填充路
  is_write;                       // Write-Allocate
  victim_dirty; victim_tag;       // Evict 用
  l2p_entry       l2p_entry_t;    // 查回的映射
  gen_at_lookup   [31:0];         // generation,ABA 检测(配合 reloc)
}
block_la_table[1]  // reloc 锁(深度 1,可配 2;文档 03 §5.1)
```

---

## 5. 同地址合并 & reloc 序列化

```
i_alloc 到达:
  for e in entries:
    if e.valid && e.addr_tag==tag && e.index==index:
        e.req_list |= 1<<new_req;  o_merge=1;  return   // 合并,不新建
  if block_la_table.valid && block_la_table.page==la_page(addr):
        stall(由 pipe 的 o_block_la_valid 实现)            // reloc 锁
  else: 分配空 entry,state=L2P_LOOKUP

防重复 Evict:同 index 已有 entry 在 EVICT/DDR_WRITE → 新同 set miss 在 pipe 侧串行(03 §5)。
```

---

## 6. 波形

### 6.1 Read Miss 全链(L2P 命中,victim 干净)

```
cycle        T0    T1      T2..T5      T6      ...        Tn      Tn+3
            ────  ────    ──────      ────                ────   ────
i_alloc      1
state       IDLE  L2P_    L2P_LOOKUP  ALLOC_  FILL_REQ   FILL_   DONE
                  LOOKUP  (meta hit)  PEND               DECOMP
o_meta_lookup -    1       0
i_meta_hit    -    -       1(命中)
o_alloc_req   -    -       -           1
i_alloc_ack   -    -       -           1
o_ddr(rd hdr+line)-  -     -           -       1(发读)
i_ddr(data)   -    -       -           -       .          1(回)
o_decomp_req  -    -       -           -       -          1
o_fill_valid  -    -       -           -       -          -       1
i_fill_ready  -    -       -           -       -          -       1
state→IDLE                                                        ↑唤醒 req_list
```

### 6.2 Read Miss + 脏 victim Evict(与 Fill pipeline)

```
cycle        T0    T1      T2     T3      T4 ...        (并行)
            ────  ────    ────   ────
i_alloc      1
i_victim_dirty 1
state       IDLE  L2P_    EVICT_ COMP_   DDR_WRITE(Evict 写,后台)
                  LOOKUP  PEND   PEND
o_comp_req    -    -       -      1                      ← 三引擎压缩 victim
原位够?       -    -       -      -      Yes→DDR_WRITE / No→o_reloc_trig
            (Fill 链同时推进:本 miss 的 FILL_REQ 不等 Evict 写完)
```

### 6.3 同地址合并

```
cycle        T0    T1
            ────  ────
i_alloc      1     1       ← 两个请求,同一 line 地址
o_merge      0     1       ← 第二个合并到同 entry 的 req_list
(只发一次 DDR 读;DONE 时一次唤醒两个请求)
```

### 6.4 alloc 失败 → 等 OS

```
cycle        T0      ...        (≤OOM_TIMEOUT)
            ────
state       ALLOC_PEND ──────────────► (i_alloc_ack 后) FILL_REQ
i_alloc_fail 1
→ 触发 IRQ_HARD_FULL(pressure_mon);本 entry 停在 ALLOC_PEND;
  同 LA 页经 o_block_la_valid 阻塞;超时由上层 SLVERR(文档 03 §8)
```

---

## 7. 验证要点

| 编号 | 场景 | 期望 |
|------|------|------|
| MS01 | 单 miss 全链 | L2P→读→解压→fill,数据正确 |
| MS02 | 同地址 N 合并 | 1 次 DDR 读,N 个请求都被唤醒 |
| MS03 | 脏 victim Evict + Fill | Evict 写与 Fill 读 pipeline,互不阻塞 |
| MS04 | Evict 压缩超原位 | 触发 o_reloc_trig,序列化正确 |
| MS05 | 8 项打满 | o_full 反压,无丢失 |
| MS06 | 同 set 连续 miss | 无重复 Evict |
| MS07 | reloc 锁同页 | 阻塞至 i_reloc_done |
| MS08 | alloc 失败 | 停 ALLOC_PEND + IRQ_HARD_FULL,恢复后继续 |
| MS09 | Fill 解压 CRC 错 | 重读/上报(禁止静默零填充,§10.7) |

形式:每项 FSM 无死锁;8 项并发不互锁;合并不丢请求;generation ABA 检测正确。

---

## 8. 决策清单
- [x] 端口冻结 + 9 态 FSM + 合并/序列化规则
- [x] **read-miss 子集已实现**:[rtl/mshr_min.sv](../../rtl/mshr_min.sv)(单条 FETCH→DECOMP→FILL),
      用于 miss 链集成。简化:假设 L2P 命中、{algo,mode,size,crc8} 随 DDR 数据返回、不处理 evict/合并。
- [x] **写回(Evict)子集已实现**:[rtl/mshr_wb.sv](../../rtl/mshr_wb.sv)(EVICT_COMP→EVICT_WR→FETCH→DECOMP→FILL),
      脏 victim 压缩写回压缩 DDR;write-allocate 由上层重发写置 dirty。
- [x] **miss 链端到端验证**(Questa 0/0):`dv/sim/sub_miss.do` → `tb_sub_miss: ALL PASS`
      (read-miss→DDR 压缩行→解压→fill→重读命中,6 类数据均返回正确原始值)
- [x] **写读闭环验证**(Questa 0/0):`dv/sim/sub_wb.do` → `tb_sub_wb: ALL PASS`
      (write-miss→write-alloc→写入→evict 压缩 64B→4B 存 DDR→read 解压读回原值)
- [ ] 全功能 mshr.sv:9 态 + 同地址合并 + reloc 序列化 + L2P 经 meta cache + 多 outstanding
- [ ] UVM MS01-MS09 + 形式
