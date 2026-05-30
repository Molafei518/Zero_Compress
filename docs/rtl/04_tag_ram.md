# RTL-1 / 模块 04:tag_ram(Tag 存储 + pLRU + SECDED)

> **角色**:N_WAY 路 Tag SRAM,同步读(1 cyc),单路写;附 set 级 tree-pLRU 存储与 Tag SECDED ECC。
> **代码**:[rtl/tag_ram.sv](../../rtl/tag_ram.sv)
> **架构出处**:§5.2 / §10.1;接口分组 (C)。

---

## 1. 功能与边界

| 做什么 | 不做什么 |
|--------|---------|
| 存 `N_SETS × N_WAY` 个 `tag_entry_t`(valid/dirty/tag) | 命中判定(cache_pipe_ctrl 比较) |
| 同步读:给 index,1 拍后输出 N_WAY 路 tag | way 选择 |
| 单路写:置/清 valid、dirty,写 tag | victim 选择(pipe 用 pLRU) |
| set 级 pLRU(`PLRU_W=3`)读出 + 写回 | pLRU 更新算法(pipe 算 next) |
| Tag SECDED:写时生成校验,读时纠 1 检 2 | — |

---

## 2. 端口表(冻结)

| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `clk`/`rst_n` | in | 1 | |
| `i_rd_en` | in | 1 | 读使能 |
| `i_index` | in | IDX_W | set 索引 |
| `o_rdata` | out | tag_entry_t × N_WAY | N_WAY 路并行读出(1 拍后) |
| `o_plru` | out | PLRU_W | 该 set pLRU |
| `o_ecc_corr` | out | 1 | 本次读发生可纠正错(脉冲,给 perf/IRQ) |
| `o_ecc_uncorr` | out | 1 | 不可纠正(双 bit)→ way 降级 |
| `i_wr_en` | in | 1 | tag 写使能 |
| `i_wr_way` | in | WAY_W | 写哪路 |
| `i_wr_index` | in | IDX_W | 写 set |
| `i_wdata` | in | tag_entry_t | 新 tag entry |
| `i_plru_we` | in | 1 | pLRU 写使能 |
| `i_plru_wr_index` | in | IDX_W | pLRU 写 set |
| `i_plru_upd` | in | PLRU_W | pLRU 新值 |
| `i_inval_all` | in | 1 | 全 invalidate(Hard Flush) |

---

## 3. 内部结构

```
  tag_array : N_WAY 块 SRAM,每块 N_SETS × (TAG_ENTRY_W + ECC_W)
              ECC_W = SECDED(Hamming) over {valid,dirty,tag}(TAG_W+2 ≈ 27 bit → 6 bit ECC)
  plru_array: 1 块 SRAM,N_SETS × PLRU_W(3 bit/set);或寄存器堆(512×3=192B)

  读:i_index → 同拍发 N_WAY 块 + plru;下一拍输出寄存(registered SRAM)
  写:i_wr_way 选块,i_wr_index 写;生成 ECC
  invalidate_all:可用 flash-clear 的 valid 位阵列(独立 FF),避免逐 set 清
```

读写**同 index 同拍**冲突:写优先 + 读返回旁路写值(write-first),或由 pipe 保证不同拍(基线:write-first 旁路)。

---

## 4. 波形

### 4.1 同步读(1 拍延迟)

```
cycle          T0     T1     T2
              ────   ────   ────
i_rd_en        1      1      0
i_index        IX0    IX1    -
o_rdata        -      TG0[4] TG1[4]    ← registered SRAM,T0 读 → T1 出
o_plru         -      PL0    PL1
```

### 4.2 写(置 dirty)+ pLRU 更新,与读并发

```
cycle          T0     T1
              ────   ────
i_wr_en        1      0
i_wr_way       Wh     -
i_wr_index     IXw    -
i_wdata        {tag,dirty=1,valid=1}
i_plru_we      1      0
i_plru_upd     PLn    -
i_rd_en        1      .       ← 同拍另一请求读
i_index        IXr    .
o_rdata        -      若 IXr==IXw 则旁路新值(write-first)
```

### 4.3 读发生可纠正 ECC 错

```
cycle          T0     T1
              ────   ────
i_rd_en        1      -
o_rdata        -      TG(已纠正)
o_ecc_corr     -      1        ← 单 bit 翻转被纠正,计数+1
```

---

## 5. 验证要点

| 编号 | 场景 | 期望 |
|------|------|------|
| TR01 | 写后读同 way/set | 读回一致 |
| TR02 | 1 拍读延迟 | T0 读 → T1 出 |
| TR03 | 同 index 读写并发 | write-first 旁路正确 |
| TR04 | inval_all | 所有 valid 清 0(1 拍) |
| TR05 | 注入单 bit 错 | o_ecc_corr,数据已纠 |
| TR06 | 注入双 bit 错 | o_ecc_uncorr,该 way 标记降级 |
| TR07 | pLRU 读写 | 读回 pipe 写入值 |

---

## 6. 决策清单
- [x] 端口冻结 + ECC 策略(SECDED)
- [ ] RTL(SRAM 例化 / ECC enc-dec / flash-clear valid)
- [ ] UVM TR01-TR07
