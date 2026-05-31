# RTL-4 / 模块 33:apb_cfg(APB 配置/状态寄存器)

> **角色**:APB 从设备,实现 [文档 04 §2](../04_os_driver_abi.md) 的寄存器映射;驱动全局 `cfg_*`,汇集 STATUS/性能。
> **代码**:[apb_cfg.sv](../../rtl/apb_cfg.sv)
> **寄存器映射以 [docs/04 §2](../04_os_driver_abi.md) 为准**,本文不重复,只给端口与 APB 时序。

---

## 1. 端口(冻结,摘要)

| 端口 | 方向 | 说明 |
|------|------|------|
| `clk`/`rst_n` | in | 核心域 |
| `apb`(zc_apb_if.slave) | — | PSEL/PENABLE/PWRITE/PADDR/PWDATA/PRDATA/PREADY/PSLVERR |
| `i_strap_cap_ratio` | in | 复位时初始化 CAP_RATIO |
| **配置输出(cfg_*)** | out | cache_en/compress_en/gc_en/cap_ratio/l2p_base/meta_base/bypass[N]/thresholds/gc_bw_limit/oom_timeout/nca_mode... |
| **状态/性能输入** | in | used_pct/frag/avg_ratio/waterlevel/perf 读口/int_status |
| `o_int_mask`/`i_int_raw`/`o_irq` | — | 中断屏蔽与合并(文档 04 §3) |
| `o_mbox_*`/`i_mbox_*` | — | doorbell + ring 指针(文档 04 §4) |

> APB 域与核心域跨时钟:配置寄存器在核心域,APB 写经 2-flop 同步(见 [00 §5](00_top_and_interfaces.md) CDC)。本骨架先假设同 `clk`,集成时加同步器。

---

## 2. APB 时序(标准 2 拍访问)

```
            Setup(T0)        Access(T1)
psel         1                1
penable      0                1
pwrite       W                W
paddr        A                A
pwdata       D(写)            D
pready       0                1        ← 1 拍完成
prdata       -                Q(读)
pslverr      -                0/1
```

## 3. 验证:AC01 寄存器读写 / AC02 W1C(INT_STATUS)/ AC03 RO 保护 / AC04 strap 初值 / AC05 doorbell。

## 4. 决策清单
- [x] 端口冻结(映射见 04)
- [x] **RTL 已实现**:[apb_cfg.sv](../../rtl/apb_cfg.sv) —— APB 握手 + ID/CAPS/STATUS/CTRL/CAP_RATIO/
      PRESSURE_TH/INT_STATUS(置位+W1C)/INT_MASK/L2P_BASE/META_BASE/GC_BW/OOM/NCA 读写 + IRQ 聚合(mask)。
- [x] **验证**(Questa 0/0):`dv/sim/sub_cfg.do` → `tb_sub_cfg: ALL PASS`
      (CTRL 写读 / 阈值配置喂 pressure_mon / INT_STATUS 置位 / INT_MASK 门控 / W1C 清除)
- [ ] 完整寄存器映射(BYPASS_REGION[8]/PERF_CNT[32]/DBG)+ APB↔核心域 CDC 同步器 + UVM
