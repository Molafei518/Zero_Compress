# RTL-2 / 模块 10:compress_top + 三引擎 + line_crc8

> **角色**:64B Line → 三引擎并行压缩 → Size 比较器选最小 → 输出 {algo,mode,size,data,crc8}。
> **代码**:[compress_top.sv](../../rtl/compress_top.sv) / [bdi_compress.sv](../../rtl/bdi_compress.sv) / [zero_compress.sv](../../rtl/zero_compress.sv) / [bytedelta_compress.sv](../../rtl/bytedelta_compress.sv) / [line_crc8.sv](../../rtl/line_crc8.sv)
> **架构出处**:§6.1~§6.4;golden model:[tools/compress_eval.py](../../tools/compress_eval.py)。
> **接口分组**:(G)。

---

## 1. 结构

```
            i_line[512]
                │
    ┌───────────┼───────────┐
    ▼           ▼           ▼
┌────────┐ ┌────────┐ ┌──────────┐
│bdi     │ │zero    │ │bytedelta │   各出 {mode,size}(组合/2-3 cyc)
│compress│ │compress│ │compress  │
└───┬────┘ └───┬────┘ └────┬─────┘
    └──────────┼───────────┘
               ▼
      ┌────────────────────┐
      │ Size Comparator     │  选最小 size;
      │ + Tie Breaker       │  并列时优先级 Zero>ByteDelta>BDI(解压延迟低)
      └─────────┬───────────┘
                ▼  {algo,mode,size,comp_data}
         ┌──────────────┐
         │ line_crc8     │  CRC-8/SAE-J1850(0x1D),覆盖压缩 byte 序列
         └──────┬────────┘
                ▼ {algo,mode,size,data,crc8}
```

若最小 size ≥ 64 → 输出 `algo=ALGO_NONE, size=64`(原始直通)。

---

## 2. compress_top 端口(冻结)

| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `clk`/`rst_n` | in | 1 | |
| `i_req` | in | 1 | 压缩请求 |
| `i_line` | in | LINE_BITS | 原始 64B |
| `o_done` | out | 1 | 结果有效 |
| `o_algo` | out | algo_e | 选中算法 |
| `o_mode` | out | 3 | 算法内 mode |
| `o_size` | out | 7 | 压缩字节 1..64 |
| `o_data` | out | LINE_BITS | 压缩 byte 序列(左对齐,高位 0 填充) |
| `o_crc8` | out | 8 | line CRC8 |

> 三引擎为组合或浅流水;`compress_top` 用 `i_req`→`o_done` 表达延迟(综合后 3-4 cyc,§6.4)。

---

## 3. 三引擎算法(与 golden model 等价)

### 3.1 zero_compress(§6.1 / compress_eval.compress_zero)
| mode | 条件 | size |
|------|------|------|
| 0 | 全零 | 1 |
| 1 | 按 4B word,非零 word ≤ 8 | 1 + 2(bitmap) + 4×nz_words |
| 2 | 否则 | 64(不适合) |

### 3.2 bdi_compress(§6.2 / compress_eval.compress_bdi)
| mode | base+delta | size | 条件 |
|------|-----------|------|------|
| 0 | 全零 | 1 | all zero |
| 1 | 单值重复(4B) | 4 | 所有 4B word 相等 |
| 2 | B4+Δ1×16 | 20 | max\|Δ32\|<128 |
| 3 | B4+Δ2×16 | 36 | max\|Δ32\|<32768 |
| 4 | B8+Δ1×8 | 16 | max\|Δ64\|<128 |
| 5 | B8+Δ2×8 | 24 | max\|Δ64\|<32768 |
| 6 | B8+Δ4×8 | 40 | max\|Δ64\|<2^31 |
| 7 | 不可压 | 64 | — |

> **取最小**:收集所有满足条件的 mode 再取 min(对齐 P1-C3 修复后的 golden model,**不可在 mode2 命中即提前返回**,否则漏掉 16B 的 mode4)。

### 3.3 bytedelta_compress(§6.3 / compress_eval.compress_bytedelta)
| mode | 形式 | size | 条件 |
|------|------|------|------|
| 0 | 全零 | 1 | |
| 1 | 单 byte 重复 | 2 | all bytes equal |
| 2 | B1+4bit×63 | 34 | 相邻 byte Δ∈[-8,8) |
| 3 | B2+8bit×31 | 34 | 16b word Δ∈[-128,128) |
| 4 | B4+16bit×15 | 35 | 32b word Δ∈[-32768,32768) |
| 5 | 不可压 | 64 | |

### 3.4 line_crc8
CRC-8/SAE-J1850,`poly=0x1D, init=0xFF`(zc_pkg `CRC8_POLY/CRC8_INIT`);覆盖压缩后 `size` 个字节(不含 padding)。与 [page_header_codec.py](../../tools/page_header_codec.py) `crc8()` 逐位一致。

---

## 4. 波形

### 4.1 压缩(三引擎并行 → 选最小 → CRC)

```
cycle        T0     T1      T2      T3
            ────   ────    ────    ────
i_req        1
i_line       LINE
(bdi)        -      {m,sz}                  ← 各引擎组合/浅流水出结果
(zero)       -      {m,sz}
(bytedelta)  -      {m,sz}
size_cmp     -      -       sel             ← 比较 + tie-break
crc8         -      -       -       CRC
o_done       0      0       0       1
o_algo/mode/size/data/crc8  -  -   -   V
```

### 4.2 选中示例(稀疏页:Zero 胜)

```
bdi.size=20  zero.size=9  bytedelta.size=34
→ 最小=9(Zero);o_algo=ALGO_ZERO, o_mode=1, o_size=9
```

### 4.3 并列 tie-break

```
zero.size=64(不适合) bytedelta.size=34  bdi.size=34
→ 并列 34:优先级 ByteDelta > BDI → o_algo=ALGO_BYTEDELTA
```

---

## 5. 验证要点

| 编号 | 场景 | 期望 |
|------|------|------|
| CP01 | 全零 line | algo=Zero/BDI,size=1 |
| CP02 | 各 mode 定向 pattern | size 与 golden model 逐一致 |
| CP03 | 取最小正确 | 与 compress_eval.compress_line 一致(百万随机) |
| CP04 | tie-break 优先级 | Zero>ByteDelta>BDI |
| CP05 | 不可压 | algo=NONE,size=64 |
| CP06 | CRC8 | 与 page_header_codec.crc8 逐位一致 |

> **黄金对比**:RTL DPI-C / 仿真输出喂同一组 line 给 compress_eval.py,逐 line 比 {algo,mode,size};CRC8 比 page_header_codec.crc8。

---

## 6. 决策清单
- [x] 结构 + 端口冻结 + 三引擎 mode 表(对齐 golden model)
- [x] tie-break 优先级 + CRC8 多项式
- [ ] RTL 内部(各引擎 datapath + 打包 + 比较器)
- [ ] DPI-C 黄金对比 CP01-CP06
