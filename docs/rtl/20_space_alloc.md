# RTL-3 / 模块 20:space_alloc + free_list(PPA 空间分配器)

> **角色**:PPA 空间的 Buddy(7 级)+ Slab 二级分配器;片上 Allocator Cache 命中 1 cyc。
> **代码**:[space_alloc.sv](../../rtl/space_alloc.sv) / [free_list.sv](../../rtl/free_list.sv)
> **架构出处**:§7.1;接口分组 (H)。

---

## 1. 功能与边界

| 做什么 | 不做什么 |
|--------|---------|
| `alloc(size)` → 向上取整 Buddy 级 → 返回 64B 对齐 ppa_ptr | 写 Page Header / 数据(mshr/reloc) |
| `free(ppa,size)` → 归还,Buddy 合并 | GC 触发(gc_engine) |
| 7 级 Buddy(64/128/256/512/1K/2K/4K)bitmap(DDR 16MB) | 压力中断(pressure_mon) |
| Slab:1K/1.5K/2K/3K 预切池(占 73% 分配) | — |
| 片上 Allocator Cache:每级缓存 256 free 索引 | — |
| 占用率统计(给 pressure_mon) | — |

---

## 2. space_alloc 端口(冻结)

| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `clk`/`rst_n` | in | 1 | |
| `i_alloc_req` | in | 1 | 分配请求 |
| `i_alloc_size` | in | 13 | 需要字节(含 Header,1..4272) |
| `o_alloc_ack` | out | 1 | 分配成功 |
| `o_alloc_fail` | out | 1 | 无空间 → pressure HARD_FULL |
| `o_alloc_ppa` | out | 32 | 64B 对齐 ppa_ptr |
| `i_free_req` | in | 1 | 释放请求 |
| `i_free_ppa` | in | 32 | |
| `i_free_size` | in | 13 | |
| `o_used_pct` | out | 7 | 当前 PPA 占用% → pressure_mon |
| **↔ free_list(DDR bitmap)** | | | |
| `o_fl_*`/`i_fl_*` | — | — | bitmap 读改写(经下游 DDR / 片上 cache) |
| `i_cfg_meta_base` | in | DPA_ADDR_W | Free List Tree 基址 |

---

## 3. 内部结构

```
 alloc_size → ceil 到 Buddy 级 lvl = level_of(size)   // 64→0 ... 4096→6
   ┌─ Allocator Cache[lvl] 有 free? ──Yes─► 弹出 1 个 → ppa_ptr(1 cyc)
   │                                  No ─► 向 free_list(DDR bitmap)取一段,
   │                                        必要时高级别拆分(buddy split)
   └─ Slab 优化:1K/1.5K/2K/3K 命中预切池 → 直接给

 free(ppa,size):标记 bitmap free;尝试 buddy 合并;回填 Allocator Cache

 占用统计:已分配块数 × 级容量 累加 / 总容量 → o_used_pct
```

> Allocator Cache miss 时后台 DMA 读 bitmap 段(§7.1.2),不阻塞命中路径。

---

## 4. 波形

### 4.1 分配命中 Allocator Cache(1 cyc)

```
cycle          T0     T1
              ────   ────
i_alloc_req    1
i_alloc_size   1600   -        ← 落入 2KB 级(lvl=5)
cache[5]有free 1      -
o_alloc_ack    -      1
o_alloc_ppa    -      PPA
```

### 4.2 分配 miss → DDR 取 bitmap(多周期)

```
cycle          T0     T1 ...      Tn      Tn+1
              ────                ────    ────
i_alloc_req    1
cache[lvl]空   1
o_fl_rd(req)   -      1(读 bitmap 段)
i_fl_data      -      .          BITMAP
o_alloc_ack    -      -          -        1
(回填 Allocator Cache)
```

### 4.3 无空间

```
i_alloc_req=1,所有级无 free 且无法拆分 → o_alloc_fail=1 → pressure HARD_FULL
```

---

## 5. 验证要点

| 编号 | 场景 | 期望 |
|------|------|------|
| SA01 | 各级 alloc/free | size 取整正确,ppa 64B 对齐 |
| SA02 | buddy 拆分 | 高级别拆低级别 |
| SA03 | buddy 合并 | free 后相邻合并 |
| SA04 | Slab 命中 | 1K/1.5K/2K/3K 直接给 |
| SA05 | Allocator Cache miss | DDR 取 bitmap 回填 |
| SA06 | 占满 | o_alloc_fail,o_used_pct=100 |
| SA07 | 空间守恒(形式) | 分配总和 = 总容量 − 空闲(§15.3) |

---

## 6. 决策清单
- [x] 端口冻结 + Buddy/Slab + Allocator Cache 策略
- [x] **Buddy 分配已实现**:[space_alloc.sv](../../rtl/space_alloc.sv) —— 每级 free-block 栈;
      alloc 命中级弹出,否则从最近高级别块逐级拆分(A_SCAN→A_SPLIT FSM);free 归还到对应级栈;
      占用率统计。**buddy 合并未做**(归 Defrag GC,§7.4.1)。
- [x] **单元验证**(Questa 0/0):`dv/sim/unit_alloc.do` → `tb_unit_alloc: ALL PASS`
      (SA01 对齐 / SA02 多级拆分 / SA06 耗尽 fail+used_pct=100 / free 复用,验证不重叠)
- [ ] buddy 合并(Defrag GC)+ Slab 预切池 + DDR bitmap spill(超片上栈)+ 接入 mshr(替代 identity PPA)
- [ ] UVM SA01-SA07 + 形式守恒
