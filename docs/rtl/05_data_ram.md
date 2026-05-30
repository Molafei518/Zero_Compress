# RTL-1 / 模块 05:data_ram(4-way 数据 SRAM + SECDED)

> **角色**:Cache 数据存储。N_WAY 块 SRAM,**同 cycle 并行读出全部 way**(供 pipe 在 S2/S3 way-mux);单路按字节写。
> **代码**:[rtl/data_ram.sv](../../rtl/data_ram.sv)
> **架构出处**:§5.3 / §10.1;接口分组 (D)。

---

## 1. 功能与边界

| 做什么 | 不做什么 |
|--------|---------|
| 存 `N_SETS × N_WAY × LINE_BITS`(=128KB) | way 选择(pipe mux) |
| 同步读:给 index,1 拍后输出 **N_WAY 路整 line** | 命中判定 |
| 单路写:wstrb 字节使能,可子-line 写(写命中部分字节) | 压缩/解压 |
| Data SECDED:每 32-bit + 7-bit ECC | — |

> 为何并行读全部 way(而非按 way 读):§5.3 决策——让 tag 比较结果只做 mux,不串到 SRAM 读地址,保 Hit 4-cyc。代价是读功耗↑(可接受)。

---

## 2. 端口表(冻结)

| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `clk`/`rst_n` | in | 1 | |
| `i_rd_en` | in | 1 | 读使能 |
| `i_index` | in | IDX_W | set |
| `o_rdata` | out | LINE_BITS × N_WAY | N_WAY 路并行读出(1 拍后) |
| `o_ecc_corr`/`o_ecc_uncorr` | out | 1 | ECC 状态脉冲 |
| `i_wr_en` | in | 1 | 写使能 |
| `i_wr_way` | in | WAY_W | 写路 |
| `i_wr_index` | in | IDX_W | 写 set |
| `i_wdata` | in | LINE_BITS | 写数据(整 line) |
| `i_wstrb` | in | LINE_BYTES | 字节使能(子-line 写) |

---

## 3. 内部结构

```
  data_array : N_WAY 块 SRAM,每块 N_SETS × (LINE_BITS + ECC)
               ECC 粒度 = 32-bit 数据 + 7-bit SECDED → 每 line 16 段 × 7 = 112 bit ECC
  写:子-line 写需 RMW(读-改-写)以维护 32-bit ECC 段:
       - 若 wstrb 覆盖整个 32-bit 段 → 直接写该段 + 重算 ECC
       - 若部分覆盖 → 读出该段、合并字节、重算 ECC、写回(同周期或加 1 拍)
  读:N_WAY 块同 index 并行读 → registered 输出
```

> **写端口竞争**:data_ram 只有一个写口;pipe 内部已仲裁(fill > 写命中,见 03 §5),保证同拍至多一个写。

---

## 4. 波形

### 4.1 4-way 并行读(1 拍)

```
cycle          T0     T1
              ────   ────
i_rd_en        1      -
i_index        IX     -
o_rdata[0..3]  -      {D0,D1,D2,D3}   ← 4 路整 line 同拍输出
```

### 4.2 写命中(子-line 写,部分 wstrb,含 RMW)

```
cycle          T0     T1     T2
              ────   ────   ────
i_wr_en        1      -      -
i_wr_way       Wh     -      -
i_wr_index     IX     -      -
i_wdata        WD     -      -
i_wstrb        部分   -      -
(内部)RMW读段  rd     merge  wr      ← 部分覆盖的 32b 段:读→合并→写回+ECC
```
> 若 wstrb 恰好按 32-bit 段对齐(整段写),则无 RMW,T0 直接写。

---

## 5. 验证要点

| 编号 | 场景 | 期望 |
|------|------|------|
| DR01 | 写后读同 way/set | 一致 |
| DR02 | 4-way 并行读 | 4 路均正确 |
| DR03 | 整段对齐写 | 无 RMW,1 拍 |
| DR04 | 部分字节写(RMW) | 未写字节保持,ECC 重算正确 |
| DR05 | 注入单/双 bit 错 | corr 纠正 / uncorr 上报 |
| DR06 | 同 index 读写并发 | 由 pipe 仲裁,行为确定 |

---

## 6. 决策清单
- [x] 端口冻结 + 并行读策略 + ECC 粒度(32b)
- [ ] RTL(SRAM + 子-line RMW + ECC)
- [ ] UVM DR01-DR06
