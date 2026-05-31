# RTL-1 / 模块 01:req_buffer(请求缓冲与 burst 拆分)

> **角色**:上游 AXI4 的入口。解耦 Arbiter 时序,跟踪 outstanding,把跨多 Cache Line 的 burst 拆成 64B 行子请求送 addr_decode。
> **代码**:[rtl/req_buffer.sv](../../rtl/req_buffer.sv)
> **架构出处**:§4.1 / §8.7(大事务穿透)/ §9.1;接口分组 (A)。

---

## 1. 功能与边界

| 做什么 | 不做什么 |
|--------|---------|
| 接收上游 `s_axi` 的 AR / AW+W;skid 解耦 | AXI 协议合规检查(假定上游合规) |
| outstanding 跟踪(AR/AW 各 `MSHR_DEPTH` 量级) | 响应重排(resp_merge) |
| 按 64B Line 边界拆 burst → 每行一个子请求 | Hit/Miss 判定(cache_pipe_ctrl) |
| 写:对齐 W 数据到 64B,给出 `wdata[512]`+`wstrb` | 写数据与响应配对(resp_merge 用 id) |
| 透传 id/len/size/prot/cache | — |

---

## 2. 端口表(冻结)

| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `clk` / `rst_n` | in | 1 | |
| **上游 AXI(slave 侧关键信号)** | | | 见 [zc_if.sv](../../rtl/zc_if.sv) |
| `s_axi` (interface) | — | — | AR/R/AW/W/B,IP 为 slave |
| **(A) → addr_decode** | | | |
| `o_req_valid` | out | 1 | 子请求有效 |
| `i_req_ready` | in | 1 | addr_decode 反压 |
| `o_addr` | out | LA_ADDR_W | 64B 对齐的行地址 |
| `o_id` | out | AXI_ID_W | 透传 master id |
| `o_is_write` | out | 1 | |
| `o_len` | out | 8 | 原 burst len(透传,供统计) |
| `o_prot` | out | 3 | AxPROT |
| `o_cache` | out | 4 | AxCACHE |
| `o_wdata` | out | LINE_BITS | 该行写数据(读时无效) |
| `o_wstrb` | out | LINE_BYTES | 该行写字节使能 |
| `o_offset` | out | OFFSET_W | 行内首字节偏移(CWF) |
| `o_first`/`o_last` | out | 1 | burst 拆分后首/末子请求标记 |

---

## 3. 内部结构

```
  s_axi.AR ─► [AR skid] ─┐
                         ├─► [burst splitter FSM] ─► (A) o_req_* (per 64B line)
  s_axi.AW ─► [AW skid] ─┤            │
  s_axi.W  ─► [W FIFO  ] ─┘            └─ line_cnt / addr_incr
```

- **AR/AW skid**:1 深 skid buffer,打断上游组合路径。
- **W FIFO**:缓存写数据 beat(`BEATS_PER_LINE=2` 个 256b beat 拼成一个 512b line)。
- **burst splitter FSM**:`S_IDLE → S_SPLIT`。把 `[base, base+ (len+1)*beat]` 按 64B 行边界迭代:每行产生一个 `o_req_*`,`addr += LINE_BYTES`,直到覆盖完;写方向同时从 W FIFO 取够 `BEATS_PER_LINE` 个 beat 组成 `o_wdata`。
- **outstanding 计数**:AR/AW 各一个计数器,达上限即 `s_axi.arready/awready=0`。

> 拆分粒度对齐 §8.7:子请求各自独立过 Cache 流水(Hit/Miss 独立),响应顺序由 resp_merge 用 id+子序保证。

---

## 4. 波形

### 4.1 读 burst 拆分(1 个 AR 跨 2 个 64B 行 → 2 子请求)

> 例:`araddr=A`(64B 对齐),`arlen=3`(4 beat),`arsize=5`(32B/beat)→ 共 128B = 2 行。

```
cycle           T0     T1     T2     T3     T4
               ────   ────   ────   ────   ────
s_axi.arvalid   1      0      .      .      .
s_axi.arready   1      0      .      .      .      ← 收下后拆分中不再收
s_axi.araddr    A      -      -      -      -
splitter_state  IDLE   SPLIT  SPLIT  IDLE   IDLE
o_req_valid     0      1      1      0      .      ← 2 个行子请求
o_addr          -      A      A+64   -      -
o_first         -      1      0      -      -
o_last          -      0      1      -      -
i_req_ready     1      1      1      1      1
```

### 4.2 写 burst(AW + 4 beat W → 2 行,带写数据组装)

```
cycle           T0     T1     T2     T3     T4     T5
               ────   ────   ────   ────   ────   ────
s_axi.awvalid   1      0      .      .      .      .
s_axi.wvalid    1      1      1      1      0      .     ← 4 个 256b beat
s_axi.wready    1      1      1      1      0      .
s_axi.wlast     0      0      0      1      -      -
w_fifo_cnt      0→1   1→2    2→1*   1→0*   0      0     (*取走拼 line)
o_req_valid     0      0      1      0      1      0
o_addr          -      -      A      -      A+64   -
o_wdata         -      -      LN0    -      LN1    -     ← beat0+beat1 / beat2+beat3
o_wstrb         -      -      WS0    -      WS1    -
```

---

## 5. 验证要点

| 编号 | 场景 | 期望 |
|------|------|------|
| RB01 | 单行读(arlen=1,32B×2) | 1 子请求 |
| RB02 | 跨 N 行读 burst | N 子请求,地址连续 +64,first/last 正确 |
| RB03 | 写 burst 数据组装 | wdata/wstrb 按行正确对齐 |
| RB04 | outstanding 打满 | arready/awready 正确反压 |
| RB05 | 非 64B 对齐起始地址 | 首行 offset 正确,部分 wstrb |
| RB06 | addr_decode 反压 | 子请求暂停,不丢 |

---

## 6. 决策清单
- [x] 端口冻结
- [x] burst 拆分语义 + 写数据组装
- [x] **单 line 功能版实现**(AR→读请求;AW+BEATS_PER_LINE 个 W beat→写请求,组装 512b line)
- [x] **AXI 端到端验证**(Questa 0/0):`dv/sim/sub_axi.do` → `tb_sub_axi: ALL PASS`
- [ ] 多行 burst 拆分(splitter FSM)+ outstanding 跟踪(留后续)
- [ ] UVM RB01-RB06
