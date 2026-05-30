# RTL-4 / 模块 34:ecc_secded(通用 SECDED,tag/data/meta 复用)

> **角色**:参数化 SECDED(Hamming + 整体奇偶)编/解码。tag_ram / data_ram / l2p_meta_cache 各按自身宽度例化。
> **代码**:[ecc_secded.sv](../../rtl/ecc_secded.sv)
> **架构出处**:§10.1;替代 §4.2 的 tag_ecc/data_ecc/meta_ecc 三文件(统一为一个参数化模块)。

---

## 1. 例化映射

| 例化 | DATA_W | 用途 |
|------|--------|------|
| tag_ecc | TAG_W+2(valid/dirty/tag ≈ 27) | tag_ram |
| data_ecc | 32(每 32-bit 段) | data_ram(每 line 16 段) |
| meta_ecc | 64(L2P entry)/ 可配 | l2p_meta_cache |

> SECDED 校验位数 r 满足 `2^r ≥ DATA_W + r + 1`,再 +1 整体奇偶位 → 纠 1 检 2。

---

## 2. 端口(冻结)

| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| **编码 enc** | | | |
| `i_enc_data` | in | DATA_W | 原始数据 |
| `o_enc_code` | out | ECC_W | 校验位(随数据存) |
| **解码 dec** | | | |
| `i_dec_data` | in | DATA_W | 读回数据 |
| `i_dec_code` | in | ECC_W | 读回校验位 |
| `o_dec_data` | out | DATA_W | 纠正后数据 |
| `o_corr` | out | 1 | 发生可纠正(单 bit)错 |
| `o_uncorr` | out | 1 | 不可纠正(双 bit)错 |

> 纯组合(enc/dec 各 1 级);若时序紧可寄存。

---

## 3. 逻辑

```
enc:syndrome 生成矩阵 H → code = H·data;整体奇偶 p = ^{data,code[parity bits]}
dec:syndrome s = H·data ⊕ code
    s==0 & p_ok        → 无错
    s!=0 & p 翻转      → 单 bit 错:由 s 定位 bit → 翻转纠正,o_corr=1
    s!=0 & p 未翻转    → 双 bit 错:o_uncorr=1(不纠)
```

---

## 4. 波形(组合)

```
enc:  i_enc_data=D → o_enc_code=C(同拍)
dec(单bit错):i_dec_data=D'(1bit翻)/i_dec_code=C → o_dec_data=D(已纠) o_corr=1
dec(双bit错):o_uncorr=1,o_dec_data 不可信(上层降级/上报)
```

---

## 5. 验证

| 编号 | 场景 | 期望 |
|------|------|------|
| EC01 | 无错 | corr=0 uncorr=0,数据原样 |
| EC02 | 注入任一单 bit(data 或 code) | o_corr=1,纠正正确 |
| EC03 | 注入任一双 bit | o_uncorr=1 |
| EC04 | 各例化宽度 | 27/32/64 均通过 |

形式:任意单 bit 翻转可纠;任意双 bit 翻转可检(穷举 bit 位置)。

---

## 6. 决策清单
- [x] 端口冻结 + SECDED 算法 + 复用映射
- [ ] RTL(H 矩阵生成 + enc/dec)
- [ ] UVM/形式 EC01-EC04
