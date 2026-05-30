# RTL-1 / 模块 02:addr_decode(路径判定:NORMAL / BYPASS / NCA)

> **角色**:对每个行子请求判定走哪条路:正常压缩缓存 / Bypass 区间 / NCA(Device)。
> **代码**:[rtl/addr_decode.sv](../../rtl/addr_decode.sv)
> **架构出处**:§2.4 / §10.3;接口分组 (A)→(B)。

---

## 1. 功能与边界

| 做什么 | 不做什么 |
|--------|---------|
| 比对 `N_BYPASS_REGION` 个 [start,end) 区间 → BYPASS | 区间寄存器的 APB 写(apb_cfg) |
| 按 `AxPROT[1]`(Secure)+ `AxCACHE` 判 NCA/Device | Cache 命中(cache_pipe_ctrl) |
| 透传 payload,附加 `path` 字段 | 压缩(compress) |
| 1 拍寄存(打断组合路径) | — |

> Bypass 语义:no-compress + no-cache,直通 DDR(地址线性)。NCA:跳 Cache,**仍过压缩通路**(对 Master 透明,§2.4)。

---

## 2. 端口表(冻结)

| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `clk`/`rst_n` | in | 1 | |
| **(A) ← req_buffer** | | | |
| `i_req_valid`/`o_req_ready` | in/out | 1 | 握手 |
| `i_addr`/`i_id`/`i_is_write` | in | — | |
| `i_prot` | in | 3 | AxPROT(bit1=Secure n) |
| `i_cache` | in | 4 | AxCACHE |
| `i_wdata`/`i_wstrb`/`i_offset` | in | — | 透传 |
| **配置(← apb_cfg)** | | | |
| `i_cfg_bypass_start[N]` | in | LA_ADDR_W | N 个区间起 |
| `i_cfg_bypass_end[N]` | in | LA_ADDR_W | N 个区间止 |
| `i_cfg_nca_mode` | in | 2 | Secure 事务策略:0=全 bypass / 1=cache 不压 / 2=正常 |
| **(B) → cache_pipe_ctrl** | | | |
| `o_req_valid`/`i_req_ready` | out/in | 1 | |
| `o_addr`/`o_id`/`o_is_write`/`o_wdata`/`o_wstrb`/`o_offset` | out | — | 透传 |
| `o_path` | out | req_path_e | NORMAL/BYPASS/NCA |

---

## 3. 判定逻辑(组合)

```
in_bypass = OR_k ( i_addr >= start[k] && i_addr < end[k] )      // N 比较器并行
is_secure = ~i_prot[1]                                          // AxPROT[1]: 0=Secure
is_device = (i_cache[1] == 0)  // 非 Modifiable ≈ Device/Strong-Order(简化)

path = in_bypass                         ? PATH_BYPASS :
       (is_secure && nca_mode==0)        ? PATH_BYPASS :
       (is_device || (is_secure && nca_mode==1)) ? PATH_NCA :
                                            PATH_NORMAL;
```

> N 个区间比较是 2N 个 40-bit 比较器并行(面积小,纯组合);结果与 payload 一同寄一拍到 (B)。

---

## 4. 波形

### 4.1 命中 bypass 区间 → PATH_BYPASS

```
cycle           T0     T1
               ────   ────
i_req_valid     1      0
i_addr          A∈R2   -          ← A 落在 bypass 区间 2
in_bypass(comb) 1      -
o_req_valid     0      1          ← 寄一拍
o_addr          -      A
o_path          -      BYPASS
```

### 4.2 Secure 事务(nca_mode=1)→ PATH_NCA

```
cycle           T0     T1
               ────   ────
i_req_valid     1      0
i_prot[1]       0      -          ← Secure
i_cfg_nca_mode  1      1
o_req_valid     0      1
o_path          -      NCA        ← 走 cache 但不压;或按 mode 全 bypass
```

---

## 5. 验证要点

| 编号 | 场景 | 期望 |
|------|------|------|
| AD01 | 地址在某 bypass 区间 | path=BYPASS |
| AD02 | 地址在区间边界(start/end-1/end) | 半开区间正确([start,end)) |
| AD03 | Secure + nca_mode 三档 | 分别 BYPASS / NCA / NORMAL |
| AD04 | Device(AxCACHE) | path=NCA |
| AD05 | 普通可压地址 | path=NORMAL |
| AD06 | 区间重叠 | 命中即 BYPASS(OR 语义) |

---

## 6. 决策清单
- [x] 端口冻结 + 判定真值
- [ ] RTL 实现(N 比较器 + 1 拍寄存)
- [ ] UVM AD01-AD06
