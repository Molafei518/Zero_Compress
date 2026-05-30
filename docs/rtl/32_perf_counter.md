# RTL-4 / 模块 32:perf_counter(性能计数器)

> **角色**:32 个 32-bit 计数器,采样各模块事件脉冲,溢出处理,APB 读出。
> **代码**:[perf_counter.sv](../../rtl/perf_counter.sv)
> **架构出处**:§14.1;文档 04 §6(`zc_perf_id` 枚举)。

---

## 1. 端口(冻结)

| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `clk`/`rst_n` | in | 1 | |
| `i_en`/`i_reset` | in | 1 | PERF_CTRL.enable/reset |
| `i_inc` | in | N_PERF_CNT | 各计数器 +1 脉冲(汇聚自各模块) |
| `i_rd_idx` | in | 5 | APB 读索引 |
| `o_rd_val` | out | 32 | 计数值 |
| `o_overflow` | out | 1 | 任一计数器回绕 → IRQ_PERF_OVERFLOW(可选) |

> 计数器 id 对齐文档 04 §6 `zc_perf_id`(PERF_HIT/MISS/.../LAT_*)。延迟直方图 bin 由专门的 inc 索引累加。

---

## 2. 逻辑

```
for each k: if (i_en && i_inc[k]) cnt[k]++;  回绕置 overflow
i_reset → 全清;APB 用 i_rd_idx 选 o_rd_val
软件侧把 32-bit 累加到 64-bit(文档 04 §6)
```

---

## 3. 波形

```
cycle      T0    T1    T2
i_en        1     1     1
i_inc[HIT]  1     0     1
cnt[HIT]    n    n+1   n+1  →n+2
i_rd_idx    HIT   -     -
o_rd_val    -    n+1    -
```

## 4. 验证:CV01 计数正确 / CV02 reset / CV03 overflow / CV04 APB 读一致。

## 5. 决策清单:[x] 端口冻结  [ ] RTL  [ ] UVM
