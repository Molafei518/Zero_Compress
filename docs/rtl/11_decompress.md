# RTL-2 / 模块 11:decompress_top + 三解码器 + crc_check

> **角色**:{algo,mode,size,data,crc8} → CRC 校验 → 按 algo 分发解码 → 还原 64B。
> **代码**:[decompress_top.sv](../../rtl/decompress_top.sv) / [bdi_decompress.sv](../../rtl/bdi_decompress.sv) / [zero_decompress.sv](../../rtl/zero_decompress.sv) / [bytedelta_decompress.sv](../../rtl/bytedelta_decompress.sv) / [crc_check.sv](../../rtl/crc_check.sv)
> **架构出处**:§6.5 / §6.6 / §10.2;接口分组 (G)。

---

## 1. 结构

```
   {algo,mode,size,comp_data,crc8_exp}
                │
        ┌───────┴────────┐
        │  crc_check      │  calc_crc8(comp_data[size]) ?= crc8_exp
        └───────┬────────┘  失败 → o_crc_err(触发 IRQ_DECOMP_ERR + SLVERR;禁止静默零填充)
                │ algo
       ┌────────┼────────┐
       ▼        ▼        ▼
  ┌────────┐┌──────┐┌──────────┐
  │bdi_dec ││zero_ ││bytedelta_│   未选中引擎 clock-gate(§6.5)
  │        ││dec   ││dec       │
  └───┬────┘└──┬───┘└────┬─────┘
      └────────┼─────────┘
               ▼ MUX(by algo)
          o_line[512]
```

ALGO_NONE → 直接旁路 comp_data 的前 64B。

---

## 2. decompress_top 端口(冻结)

| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `clk`/`rst_n` | in | 1 | |
| `i_req` | in | 1 | 解压请求 |
| `i_algo` | in | algo_e | |
| `i_mode` | in | 3 | |
| `i_size` | in | 7 | 压缩字节 |
| `i_data` | in | LINE_BITS | 压缩 byte 序列 |
| `i_crc8_exp` | in | 8 | 期望 CRC(来自 Page Header) |
| `o_done` | out | 1 | |
| `o_line` | out | LINE_BITS | 还原 64B |
| `o_crc_err` | out | 1 | CRC 失败(脉冲) |

> 延迟 2-3 cyc(含 CRC 1 cyc,§6.5)。CWF:解压完成整 line forward(§6.6)。

---

## 3. 解码器(三引擎逆运算)

各 mode 逆运算与 §3 compress 表一一对应:
- **zero_dec**:mode0→全零;mode1→bitmap 展开非零 word,其余补零。
- **bdi_dec**:还原 base + Δ 累加;mode 决定 base/delta 宽度。
- **bytedelta_dec**:base + byte/word Δ 还原。

> 解码均为定长输入定位 + 加法/移位,组合或 1-2 cyc。

---

## 4. crc_check
- `calc = crc8(i_data[0 +: i_size*8])`(poly 0x1D,init 0xFF)
- `o_crc_err = i_req & (calc != i_crc8_exp)`
- 失败处理(§10.2 / §10.7):上报 IRQ_DECOMP_ERR + 该 line SLVERR;调用方(mshr/reloc)可重读一次;**不得静默零填充当有效数据**。

---

## 5. 波形

### 5.1 正常解压(CRC ok)

```
cycle        T0      T1       T2
            ────    ────     ────
i_req        1
i_algo/mode/size/data/crc8  V
crc_calc     -       calc
crc_ok       -       1
(dec)        -       partial  line
o_done       0       0        1
o_line       -       -        LINE
o_crc_err    0       0        0
```

### 5.2 CRC 失败

```
cycle        T0      T1
            ────    ────
i_req        1
crc_calc     -       calc≠exp
o_crc_err    -       1        ← 触发 IRQ_DECOMP_ERR;mshr 重读或标记坏页
o_done       -       1        (附带 err,line 数据无效)
```

---

## 6. 验证要点

| 编号 | 场景 | 期望 |
|------|------|------|
| DC01 | 各 algo/mode 解压 | 还原 = 原始(与 compress 往返一致) |
| DC02 | 往返(compress→decompress) | 任意 line round-trip 恒等 |
| DC03 | CRC 正确 | o_crc_err=0 |
| DC04 | 注入 bit flip | o_crc_err=1,不输出错误"有效"数据 |
| DC05 | ALGO_NONE 旁路 | 前 64B 直通 |
| DC06 | 未选中引擎 gate | 功耗:非活动引擎无翻转(仿真检查) |

> **黄金对比**:与 page_header_codec / compress_eval 往返;CRC 与 crc8() 一致。

---

## 7. 决策清单
- [x] 结构 + 端口冻结 + CRC 失败策略(禁零填充)
- [ ] RTL(三解码器 + MUX + crc_check + clock gate)
- [ ] DPI-C 往返对比 DC01-DC06
