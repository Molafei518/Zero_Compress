# Page Header 编码规范

> **目的**:把主文档 §3.2.3 的"128B Header"细化成 byte-precise 布局
> **结论**:**三方案对比 → 推荐 V2(176B)**;主文档需更新
> **ABI 等级**:本规范定义后,所有压缩页的存储布局即冻结,**修改需 rev**

---

## 1. 设计目标

| 需求 | 优先级 | 说明 |
|------|-------|------|
| 64 条 Line 的 algo / mode / size 信息 | P0 | 解压必需 |
| Line 级 CRC 错误隔离能力 | P1 | bit flip 时定位到具体 Line,可 SLVERR + 重读 |
| Page 级元信息(magic / generation / total_size) | P0 | 完整性、ABA 检测 |
| Page 级 CRC | P1 | Header 自身完整性 |
| RTL 解析简单(field 字节对齐) | P1 | 减少 byte unpacker 面积 |
| 总大小最小 | P1 | 直接占用 PPA 空间 |

---

## 2. 字段位宽分析

### 2.1 Line Info 必需字段

| 字段 | 位宽 | 说明 |
|------|------|------|
| algo | 2 bit | 4 种(BDI / Zero / ByteDelta / None) |
| mode | 3 bit | 各算法最多 8 模式;BDI 8 / ByteDelta 6 / Zero 3 |
| size | 7 bit | 1~64,实际编码 size-1 = 0~63 → 6 bit;或留 1 bit 余量 |
| crc | 0 / 4 / 8 bit | 视方案 |

> **size 为何 6 bit 不够**:Line 0 的 size 字段总是 ≥ 1 byte(不可能压到 0),所以 1~64 可编码为 0~63 → **6 bit 足够**

### 2.2 Page Header 必需字段

| 字段 | 位宽 | 说明 |
|------|------|------|
| magic | 16 bit | 0xCC55,startup self-check |
| generation | 16 bit | 每次重定位 +1,L2P/Header 不一致检测 |
| total_size | 13 bit | 0~4272(= 4096 数据 + 176 Header;对齐到 16 bit 字段) |
| reserved | 8~24 bit | 未来扩展 |
| page_crc | 32 bit | CRC32(Header sans this field) |

总:**约 80~96 bit ≈ 12 byte**(向上对齐到 16 byte)

---

## 3. 三方案对比

### V1:128 byte Header(无 Line CRC,Page CRC32 only)

```
偏移   字段                    大小
─────────────────────────────────────
0x00   magic                   2 B   = 0xCC55
0x02   reserved                2 B
0x04   generation              4 B
0x08   total_size              2 B
0x0A   reserved                2 B
0x0C   page_crc32              4 B
0x10   line_info_array         88 B  ← 11 bit × 64 = 704 bit = 88 B(打包)
0x68   reserved                24 B  ← future use
0x80                           ───
                              128 B
```

**Line Info 编码(11 bit/Line,打包后 88 byte)**:
```
[ algo(2) | mode(3) | size_minus_1(6) ]
       ↑ MSB                 LSB ↑
```

**优点**:128B 整页对齐,space efficient
**缺点**:**bit flip 只能由 Page CRC32 检测**,无法定位到具体 Line。一字节翻转 → 整页丢弃

---

### V2:176 byte Header(11 bit Info + 8 bit Line CRC)⭐ 推荐

```
偏移   字段                    大小   累计
─────────────────────────────────────────
0x00   magic                   2 B   0x02
0x02   reserved                2 B   0x04
0x04   generation              4 B   0x08
0x08   total_size              2 B   0x0A
0x0A   reserved                2 B   0x0C
0x0C   page_crc32              4 B   0x10
0x10   line_info_array         88 B  0x68  ← 11 bit × 64 = 704 bit
0x68   line_crc8_array         64 B  0xA8  ← 8 bit × 64 = 512 bit
0xA8   reserved                 8 B  0xB0  ← future ECC / version flags
0xB0                           ───
                              176 B
```

**Line CRC8 多项式**:`x^8 + x^4 + x^3 + x^2 + 1`(= 0x1D,CRC-8/SAE-J1850,与 golden model [tools/page_header_codec.py](../tools/page_header_codec.py) `CRC8_POLY=0x1D` 一致;init=0xFF)
- 覆盖范围:对应 Line 的**压缩后 byte 序列**(size 字节,不含 padding)
- 检错能力:单 bit 翻转 100%、多 bit 翻转 ≥99.6%
- 失败处理:见 §6 错误流程

**优点**:Line 级错误定位 + 重读机制,容量扩展器场景关键
**缺点**:176B 比 128B 多 48 byte,占 1M 页 → 48MB 元数据增量(+1.17% DDR 容量)

---

### V3:192 byte Header(11 bit Info + 16 bit Line CRC + Strong Page CRC32 + ECC)

```
偏移   字段                    大小
─────────────────────────────────────
0x00   magic                   2 B
0x02   version                 1 B
0x03   flags                   1 B
0x04   generation              4 B
0x08   total_size              2 B
0x0A   reserved                2 B
0x0C   page_crc32              4 B
0x10   header_ecc              4 B    ← Hamming on header[0x00..0x10]
0x14   reserved                12 B
0x20   line_info_array         88 B
0x78   line_crc16_array        128 B  ← 16 bit × 64 = 1024 bit
0xF8   reserved                8 B
0x100                          ───
                              256 B(实际 192B 利用)
```

**优点**:最强检错(CRC16 多 bit 检错率 99.997%)
**缺点**:192~256B 太大,占 6.25%~12.5% 元数据预算的过大份额

---

## 4. 推荐方案:V2(176 byte)

| 维度 | V1 (128B) | **V2 (176B)** | V3 (256B) |
|------|----------|---------------|-----------|
| Line 级错误定位 | ❌ | **✅** | ✅ |
| 检错率(单字节翻转) | 100% (Page) | 100% | 100% |
| 检错率(多字节连续翻转) | ~99% (CRC32) | ~99.6% (CRC8 + CRC32) | ~99.997% |
| 元数据开销 (1M pages) | 128 MB / 4GB = 3.13% | **176 MB / 4GB = 4.30%** | 256 MB / 4GB = 6.25% |
| 占 PPA 4KB 页比例 | 3.13% | **4.30%** | 6.25% |
| RTL 解析复杂度 | 简单 | 简单 | 中等 |
| 兼容未来扩展 | 24B reserved | 8B reserved | 充足 reserved |
| **推荐** | Phase 1 原型 | **Phase 2+ 量产** | 高可靠场景 |

---

## 5. V2 完整布局(byte-precise)

### 5.1 字节地图

```
Byte:    0    1    2    3    4    5    6    7    8    9    A    B    C    D    E    F
        +----+----+----+----+----+----+----+----+----+----+----+----+----+----+----+----+
0x00    | magic   | rsvd    | generation        | tot_sz  | rsvd    | page_crc32      |
0x10    | line_info[0..15]  packed 11 bits-per-line × 64 = 704 bit = 88 byte           |
0x20    |   ...                                                                         |
0x30    |   ...                                                                         |
0x40    |   ...                                                                         |
0x50    |   ...                                                                         |
0x60    | line_info tail (last 8 byte)         |←──── line_crc8 region begins at 0x68 ──→
0x70    | line_crc8[0..15]   (16 byte)                                                   |
0x80    | line_crc8[16..31]  (16 byte)                                                   |
0x90    | line_crc8[32..47]  (16 byte)                                                   |
0xA0    | line_crc8[48..63]  (8 byte) | reserved2[0..7]  (8 byte, must be 0)           |
0xB0    +───────────────── total 176 byte ──────────────────────────────────────────────+
```

### 5.2 字段定义(C struct)

```c
#include <stdint.h>

#define ZC_PAGE_HEADER_SIZE  176
#define ZC_LINES_PER_PAGE    64
#define ZC_PAGE_MAGIC        0xCC55

typedef struct __attribute__((packed)) {
    uint16_t magic;              /* 0x00: 0xCC55 */
    uint16_t reserved0;          /* 0x02: must be 0 */
    uint32_t generation;         /* 0x04: incremented on each reloc */
    uint16_t total_comp_size;    /* 0x08: sum of compressed line sizes (bytes) */
    uint16_t reserved1;          /* 0x0A: must be 0 */
    uint32_t page_crc32;         /* 0x0C: CRC32(IEEE 802.3) over header[0x00..0xAF] excl.
                                          this 4B field itself → 172 byte hashed
                                          (= 0x00..0x0B 拼接 0x10..0xAF) */
    uint8_t  line_info[88];      /* 0x10: 64 entries × 11 bit, packed (see §5.3) */
    uint8_t  line_crc8[64];      /* 0x68: 1 byte CRC per line */
    uint8_t  reserved2[8];       /* 0xA8: must be 0,reserve for future ECC/version */
} zc_page_header_t;

_Static_assert(sizeof(zc_page_header_t) == ZC_PAGE_HEADER_SIZE,
               "header size must be 176 byte");
```

### 5.3 Line Info 打包格式

每条 Line 11 bit,64 条共 704 bit = 88 byte,LSB-first 打包:

```
bit 位置(在整 line_info[88] 中):
  Line 0: bit 0..10
  Line 1: bit 11..21
  Line 2: bit 22..32
  ...
  Line N: bit (N*11) .. (N*11+10)

每 11 bit 内部:
  bit  0-1   : algo_id
  bit  2-4   : mode
  bit  5-10  : size_minus_1
```

**编码伪代码**(Python,reference 实现见 `tools/page_header_codec.py`):

```python
def encode_line_info(line_info_array, idx, algo, mode, size):
    """Encode (algo, mode, size) into bit-packed line_info array at index idx."""
    val = (algo & 0x3) | ((mode & 0x7) << 2) | (((size - 1) & 0x3F) << 5)  # 11 bit
    bit_offset = idx * 11
    for b in range(11):
        byte_pos = (bit_offset + b) // 8
        bit_pos  = (bit_offset + b) % 8
        bit_val  = (val >> b) & 1
        if bit_val:
            line_info_array[byte_pos] |= (1 << bit_pos)
        else:
            line_info_array[byte_pos] &= ~(1 << bit_pos)

def decode_line_info(line_info_array, idx):
    bit_offset = idx * 11
    val = 0
    for b in range(11):
        byte_pos = (bit_offset + b) // 8
        bit_pos  = (bit_offset + b) % 8
        bit_val  = (line_info_array[byte_pos] >> bit_pos) & 1
        val |= bit_val << b
    algo = val & 0x3
    mode = (val >> 2) & 0x7
    size = ((val >> 5) & 0x3F) + 1
    return algo, mode, size
```

### 5.4 RTL 实现要点

打包/解包用纯组合逻辑,不需流水:

```verilog
// Encode: 64 个 11-bit 输入 → 88 byte 输出
function automatic [703:0] encode_line_info_array (
    input [10:0] info [63:0]
);
    logic [703:0] packed_bits;
    for (int i = 0; i < 64; i++) begin
        packed_bits[i*11 +: 11] = info[i];
    end
    return packed_bits;
endfunction

// Decode: 88 byte 输入 → 11 bit 单条 line info(by index)
function automatic [10:0] decode_line_info (
    input [703:0] packed_bits,
    input [5:0]   line_idx
);
    return packed_bits[line_idx*11 +: 11];
endfunction
```

注:综合后是 64 个 11→88 的复用器,面积 ~2 KGate(可忽略)。

### 5.5 Line offset 计算

Page Header 不直接存储每 Line 的 offset。**offset 隐含**:

```
offset(Line N) = ZC_PAGE_HEADER_SIZE + sum(size(Line 0..N-1))
```

实现:
- **顺序读整页**:不需要计算 offset,跟着 size 累加
- **随机读单 Line**:必须先取 Header,然后累加前 N 个 size
- **优化**:RTL 内置 prefix-sum 流水,64 拍累加(在 Header 读完后并行启动)

> **替代方案 1**:显式存 offset(每 Line 12 bit)→ Header +96 byte → 256B
> **替代方案 2(推荐用于随机访问敏感场景)**:存**稀疏 offset 锚点** —— 每 8 行存 1 个 16bit offset(8 个锚点 = 16 byte),
> 随机读单行只需从最近锚点累加 ≤7 个 size,把 prefix-sum 的最坏 64 拍降到 ≤7 拍。
> Header 仅 +16 byte(176→192B,且 192 是 SRAM 友好对齐,见主文档 §5.5.2)。
>
> **trade-off**:
> - 顺序读:三方案等价(都是跟着 size 累加)。
> - **随机单行读**(在已超预算的 Miss 关键路径上,见主文档 §8.3.1):
>   纯 prefix-sum 最坏 +64 拍;锚点方案 ≤+7 拍;显式 offset 0 拍但 +96B。
> - 当前基线选纯 prefix-sum(面积 <1 KGate);若 Phase 0 实测随机访问占比高,
>   升级到锚点方案(reserved2 的 8B + 复用 192B 对齐槽即可容纳)。

---

## 6. 错误流程

### 6.1 读路径错误检测

```
Stage A: 读 Page Header (176B)
   |
   v
Stage B: 校验 magic == 0xCC55
   |  fail → IRQ_DECOMP_ERR + r_resp = SLVERR + 标记 LA 页坏
   v
Stage C: 校验 page_crc32(覆盖 header 除 crc 字段外的 172 byte = 0x00..0x0B + 0x10..0xAF)
   |  fail → 视为 Header 损坏,重读一次;仍 fail → 标记坏
   v
Stage D: 解 Line Info,定位 target Line 的 (algo, mode, size, offset)
   |
   v
Stage E: 读 Compressed Line (size byte from offset)
   |
   v
Stage F: 校验 line_crc8(仅覆盖压缩 byte 序列)
   |  fail → 重读一次;仍 fail → IRQ_DECOMP_ERR(单 Line 标记)
   v
Stage G: 按 algo 解压 → 64 byte 原始数据
```

### 6.2 写路径(更新 Header)

写更新一条 Line 时,需要:
1. 更新 line_info[idx] 的 size/algo/mode
2. 更新 line_crc8[idx]
3. 重新计算 page_crc32
4. 写回 Header(176 byte 完整写,因为 page_crc32 覆盖全 Header)

**优化**:Header Write Buffer
- 短时间内多次 Evict 更新同一页 Header → 合并为一次 DDR 写
- Buffer 容量 16 项(覆盖 16 个最近被改的 Header)

---

## 7. 兼容性与版本

```c
// flags byte (V3 引入,V2 reserved 区暂不使用)
#define ZC_FLAG_VERSION_MASK  0x07
#define ZC_FLAG_VERSION_V2    0x02
#define ZC_FLAG_VERSION_V3    0x03

// V2 默认 reserved2 全 0,V3 起从此区域读 flags / version
// 升级路径:RTL 优先按 V2 解析;若 reserved2[0] != 0 则按 V3 fallback
```

> 长期演进:Header 第 0xA8 之后的 8 byte reserved 用于将来加 Hamming ECC、加密 IV、tagged memory 标识。

---

## 8. 与主文档的差异

| 主文档原版 (v2.0) | 本规范 (v2.1) | 行动 |
|---|---|---|
| Header 大小 128 byte | **176 byte** | 主文档 §3.2.3 / §3.5 / 附录 B 需更新 |
| Line Info 14 bit/Line | **11 bit/Line + 8 bit CRC = 19 bit/Line(拆分两数组)** | 主文档 §3.2.3 更新 |
| size 字段 9 bit | **6 bit (size-1)** | 同上 |
| CRC 编码混在 Info 中 | **拆分 line_info[88] + line_crc8[64]** | 同上 |
| 元数据总开销 ~6.25% | **~5.4%**(高位区 44MB[L2P 主+备 24 + Bitmap 4 + FreeList 16] + Page Hdr 176MB(PPA 内)= 220MB / 4GB ≈ **5.4%**,与主文档 §3.5 一致;含 §10.7 L2P 双副本) | 主文档 §3.5 已一致 |

---

## 9. 验证向量

`tools/page_header_codec_test.py` 提供编解码自检向量(Phase 1 RTL 验证用):

| 测试场景 | 输入 | 期望输出 |
|---|---|---|
| 全零页 | 64 Line 全压到 1 byte | total_size = 64 |
| 单算法整页 | 全部 algo=Zero,mode=0 | line_info 全 `0b0000_0_000_001` |
| 混合页 | 16 Line BDI + 16 Zero + 16 BD + 16 None | 验证打包正确性 |
| Header CRC 翻转 | 强制 byte[5] += 1 | Stage C 检出 |
| Line CRC 翻转 | 强制 line_crc8[10] += 1 | Stage F 检出 line 10 |
| 8 字节连续翻转 | line_info[20..28] 全 0xFF | page_crc32 + line_crc8 都检出 |

---

## 10. 决策清单

- [x] 选择 V2(176 byte)作为基线
- [ ] V1(128B)仅在 Phase 1 早期 demo 使用,Phase 2 起切换 V2
- [ ] 主文档 §3.2.3 / §3.5 / 附录 B 更新到 V2 规范
- [ ] `tools/page_header_codec.py` 实现 + 单测
- [ ] RTL `page_header_pack.sv` / `page_header_unpack.sv` 模块化
- [ ] 验证向量纳入 UVM testbench
