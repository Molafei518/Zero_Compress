# RTL-3 / 模块 21:gc_engine(后台垃圾回收)

> **角色**:独立硬件 FSM,做 Hole / Compaction / Defrag 三类 GC;限速、可被业务抢占。
> **代码**:[gc_engine.sv](../../rtl/gc_engine.sv)
> **架构出处**:§7.4;接口分组 (H,触发 page_reloc)。

---

## 1. 三类 GC(§7.4.1)

| 类型 | 目的 | 触发 |
|------|------|------|
| Hole GC | 回收原位写产生的小空隙 | 后台扫描 |
| Compaction GC | 页内空闲 >25% → 整页重写紧凑 | GC Bitmap hole_ratio≥4 |
| Defrag GC | Buddy 高级别块不足 → 合并低级别 | allocator 反馈 |

> Compaction/Defrag 通过触发 `page_reloc`(trig=GC_COMPACT/GC_DEFRAG,**可被业务抢占**,文档 03 §5)。

---

## 2. 端口(冻结)

| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `clk`/`rst_n` | in | 1 | |
| `i_gc_en` | in | 1 | `cfg_gc_en` |
| `i_waterlevel` | in | waterlevel_e | SOFT_LOW 启动 |
| `i_alloc_shortage` | in | 1 | 高级别块不足 → Defrag |
| `i_explicit_req` | in | 1 | 驱动显式 GC(mailbox) |
| `i_bw_limit_pct` | in | 5 | GC DDR 带宽上限%(默认 5) |
| `i_gc_bitmap_*`/`o_gc_bitmap_*` | — | — | GC Bitmap 读(每页 hole_ratio[3:0]) |
| `o_reloc_trig` | out | reloc_trig_e | GC_COMPACT / GC_DEFRAG |
| `o_reloc_page` | out | LA_PAGE_W | |
| `i_reloc_busy`/`i_reloc_done` | in | 1 | |
| `o_gc_done_pulse` | out | 1 | 一轮完成 → IRQ_GC_DONE |
| `o_bw_used` | out | — | 累计 GC DDR 带宽(perf) |

---

## 3. FSM + 限速 + 抢占

```
 G_IDLE → (en && (SOFT_LOW||shortage||explicit)) → G_SCAN
 G_SCAN  : 读 GC Bitmap,找 hole_ratio≥4 的页 / 评估 Buddy 级别
 G_SELECT: 选目标页 → o_reloc_trig=GC_COMPACT/DEFRAG
 G_WAIT  : 等 i_reloc_done(reloc 可被业务抢占,GC 不介意延迟)
 G_THROTTLE: 累计带宽 > i_bw_limit_pct → 暂停若干周期(令牌桶)
 → 回 G_SCAN;一轮扫完 → o_gc_done_pulse → G_IDLE

限速:令牌桶,每窗口允许的 GC DDR beat 数 = 总带宽 × bw_limit%;
抢占:GC 自身不抢业务;它发起的 reloc 在 page_reloc 内被业务抢占(文档 03 §5.3)。
```

---

## 4. 波形

### 4.1 SOFT_LOW 触发 Compaction

```
cycle        T0      T1      T2        ...        Tn
            ────    ────    ────                  ────
i_waterlevel SOFT_LOW
state       IDLE    SCAN    SELECT    WAIT        SCAN...
o_reloc_trig -      -       GC_COMPACT
o_reloc_page -      -       P(hole≥25%)
i_reloc_busy -      -       -         1
i_reloc_done -      -       -         -           1
o_gc_done_pulse(扫完一轮)                          1
```

### 4.2 带宽限速(令牌耗尽暂停)

```
bw_used 达 i_bw_limit_pct → G_THROTTLE 暂停 → 令牌恢复后继续(业务带宽优先)
```

---

## 5. 验证要点

| 编号 | 场景 | 期望 |
|------|------|------|
| GC01 | SOFT_LOW 启 Hole/Compaction | 选 hole_ratio≥4 页 reloc |
| GC02 | Defrag(shortage) | 合并低级别块 |
| GC03 | 带宽限速 | GC DDR ≤ bw_limit% |
| GC04 | 业务抢占 GC reloc | reloc 让路,GC 进度保存 |
| GC05 | gc_en=0 | 不活动 |
| GC06 | 一轮完成 | o_gc_done_pulse → IRQ_GC_DONE |

---

## 6. 决策清单
- [x] 端口冻结 + 三类 GC + 限速/抢占
- [ ] RTL(扫描 FSM + 令牌桶 + GC Bitmap 访问)
- [ ] UVM GC01-GC06
