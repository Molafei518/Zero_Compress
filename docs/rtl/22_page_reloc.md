# RTL-3 / 模块 22:page_reloc(整页重定位)

> **角色**:整页重定位 9 状态 FSM 的 RTL 实现。
> **FSM/抢占/异常的完整设计见 [docs/03_page_reloc_fsm.md](../03_page_reloc_fsm.md)** —— 本文只给 RTL 端口冻结、scratch RAM、端口级波形,不重复 FSM 语义。
> **代码**:[page_reloc.sv](../../rtl/page_reloc.sv)
> **状态枚举**:`zc_pkg::reloc_state_e`(9 态)/ `reloc_trig_e`(5 触发源)。
> **接口分组**:(H) + 借用 (G) compress/decompress。

---

## 1. 端口表(冻结)

| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `clk`/`rst_n` | in | 1 | |
| **触发(文档 03 §1,优先级 §6)** | | | |
| `i_trig` | in | reloc_trig_e | NONE/HEADER_REPAIR/EVICT_OVF/WRITE_FAIL/GC_COMPACT/GC_DEFRAG |
| `i_trig_page` | in | LA_PAGE_W | 目标 LA 页 |
| `o_busy` | out | 1 | 非 IDLE |
| `o_state` | out | reloc_state_e | 当前状态(可观测) |
| `o_done_pulse` | out | 1 | 进入 DONE 单拍 |
| **MSHR 阻塞(文档 03 §5)** | | | |
| `o_block_la_valid`/`o_block_la_page` | out | — | 锁定本 LA 页 |
| `i_master_req_other_la` | in | 1 | 抢占检查点(仅 GC 触发可抢占) |
| **L2P 写(经 l2p_meta_cache)** | | | |
| `o_l2p_wr`/`o_l2p_page`/`o_l2p_entry` | out | — | COMMIT 时更新映射 |
| `i_l2p_ack` | in | 1 | |
| **compress/decompress(借用,高优先级)** | | | |
| `o_comp_*`/`i_comp_*` / `o_decomp_*`/`i_decomp_*` | — | — | RECOMP / COLLECT 解压 |
| **space_alloc** | | | |
| `o_alloc_req`/`o_alloc_size`/`i_alloc_ack`/`i_alloc_fail`/`i_alloc_ppa` | — | — | ALLOC |
| `o_free_req`/`o_free_ppa` | out | — | 旧页归还 |
| **下游 DDR** | | | |
| `o_ddr_*`/`i_ddr_*` | — | — | 读旧页 / 写新页 |
| **异常 → 中断** | | | |
| `o_irq_decomp_err`/`o_irq_hard_full` | out | 1 | 文档 03 §8 |
| `o_bad_page`/`o_bad_page_la` | out | — | 标记坏页(禁静默零填充) |

---

## 2. 内部:scratch RAM(文档 03 §4.2)

```
reloc_scratch_ram:4KB 双口,宽 256b
  - S_COLLECT_FETCH 写入解压后整页(64 行 × 64B)
  - S_RECOMP 读出供三引擎重压缩
  - S_WRITE_NEW 读压缩结果写新页(可双 buffer)
reloc_pending_fifo:深度 RELOC_FIFO_DEPTH(8),多触发排队(文档 03 §5.4)
block_la_table:深度 1(可配 2)
```

---

## 3. 端口级波形(Evict 触发,无抢占;FSM 细节见 03 §7.1)

```
state:  IDLE  LOCK  COLLECT_  COLLECT_   RECOMP   ALLOC  WRITE_   COMMIT  DONE
                    PLAN      FETCH⇄RECOMP        NEW
o_busy   0    1 ───────────────────────────────────────────────────── 1    0
o_block_la_valid  1 ──────────────────────────────────────────────── 1   →0
o_l2p_wr  -    1(Pend) -    -          -        -      -        1(map)  -
o_decomp_req -  -      -    脉冲×N     -        -      -        -       -
o_comp_req   -  -      -    -          脉冲×64  -      -        -       -
o_alloc_req  -  -      -    -          -        1      -        -       -
o_ddr(rd旧/wr新) -  -  rd hdr  rd line  -        -      wr 页    -       -
o_done_pulse -  -      -    -          -        -      -        -       1
≈ 220 cycle(p50,文档 03 §7.1)
```

GC 触发被抢占的波形见 [03 §7.2];alloc 失败等 OS 见 [03 §7.3];排队见 [03 §7.4]。

---

## 4. 验证要点

直接复用 [docs/03_page_reloc_fsm.md §10](../03_page_reloc_fsm.md) 的 **RV01–RV11**(端到端数据完整性、抢占、异常、排队等)。RTL 额外:
- FSM 状态可观测(`o_state`)对齐 RV 编号;
- scratch RAM 双口无冲突;
- block_la_table 与 MSHR 联调(MS07/PV08)。

---

## 5. 决策清单
- [x] 端口冻结 + scratch/fifo/block 表
- [ ] RTL(9 态 FSM + 抢占检查点 + 异常回滚,见 03 §8)
- [ ] UVM 复用 RV01-RV11
