# RTL-4 / 模块 30:pressure_mon(容量水位监控)

> **角色**:监控 PPA 占用率,产生水位等级与压力中断,管 OOM 超时。
> **代码**:[pressure_mon.sv](../../rtl/pressure_mon.sv)
> **架构出处**:§3.3;文档 04 §3;接口分组 (J)。

---

## 1. 功能

| 做什么 | 不做什么 |
|--------|---------|
| 比 `o_used_pct`(来自 space_alloc)与三阈值 → `waterlevel_e` | 分配(space_alloc) |
| SOFT_LOW→启 GC;SOFT_HIGH→IRQ_PRESSURE;HARD_FULL→IRQ_HARD_FULL | GC(gc_engine) |
| OOM 计时:HARD_FULL 后 `OOM_TIMEOUT_MS` 未缓解 → `o_oom_tripped`(写 SLVERR) | SLVERR 本体(resp_merge/mshr) |
| 滞回(避免阈值抖动) | hotplug/OS(§3.3.4,OS 侧) |

---

## 2. 端口(冻结)

| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `clk`/`rst_n` | in | 1 | |
| `i_used_pct` | in | 7 | 当前占用%(space_alloc) |
| `i_th_soft_low`/`i_th_soft_high`/`i_th_hard_full` | in | 7 | 阈值(APB) |
| `i_oom_timeout_ms` | in | 16 | HARD_FULL 超时 |
| `i_clk_mhz` | in | 12 | 计时换算(默认 800) |
| `o_waterlevel` | out | waterlevel_e | NORMAL/SOFT_LOW/SOFT_HIGH/HARD_FULL |
| `o_irq_pressure` | out | 1 | level,占用≥SOFT_HIGH |
| `o_irq_hard_full` | out | 1 | level,占用≥HARD_FULL |
| `o_oom_tripped` | out | 1 | 超时未缓解 → 受影响写 SLVERR |
| `i_os_relieved` | in | 1 | OS 经 mailbox 通告已释放(清计时) |

---

## 3. 逻辑

```
waterlevel = used≥hard_full ? HARD_FULL :
             used≥soft_high ? SOFT_HIGH :
             used≥soft_low  ? SOFT_LOW  : NORMAL
（带滞回:下降需低于阈值 - HYST 才降级)

o_irq_pressure  = (waterlevel >= SOFT_HIGH)
o_irq_hard_full = (waterlevel == HARD_FULL)

OOM 计时:进入 HARD_FULL 启动倒计时(oom_timeout_ms × clk_mhz × 1000);
         i_os_relieved 或 used<hard_full → 清零;
         倒计时到 0 → o_oom_tripped=1(锁存,直到缓解)
```

---

## 4. 波形

```
cycle/time   ...        进入HARD_FULL      +10ms(无缓解)        OS释放
i_used_pct   94  96(SOFT_HIGH)  99(HARD_FULL) ...               80
o_waterlevel NORM SOFT_HIGH     HARD_FULL                       SOFT_LOW
o_irq_pressure 0   1            1                               0
o_irq_hard_full 0  0            1                               0
oom_timer      -   -            T→...→0
o_oom_tripped  0   0            0 ───────────► 1                →0(i_os_relieved)
```

---

## 5. 验证要点

| 编号 | 场景 | 期望 |
|------|------|------|
| PM01 | 跨各阈值 | waterlevel/IRQ 正确 |
| PM02 | 滞回 | 阈值附近不抖动 |
| PM03 | HARD_FULL→OS 及时释放 | 不 trip |
| PM04 | HARD_FULL→超时 | o_oom_tripped,后续写 SLVERR |
| PM05 | i_os_relieved 清计时 | trip 解除 |

---

## 6. 决策清单
- [x] 端口冻结 + 水位/滞回/OOM 计时
- [x] **RTL 已实现**:[pressure_mon.sv](../../rtl/pressure_mon.sv)(三水位判定 + irq_pressure/hard_full + OOM 计时)
- [x] **验证**(Questa 0/0):随 `dv/sim/sub_cfg.do` → `tb_sub_cfg: ALL PASS`
      (used_pct 过 NORMAL→SOFT_LOW→SOFT_HIGH→HARD_FULL,waterlevel/irq 正确)
- [ ] 精确滞回(降级需低于阈值−HYST)+ OOM trip 长计时器分段 + UVM PM01-PM05
