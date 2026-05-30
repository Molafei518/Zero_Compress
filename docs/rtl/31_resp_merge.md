# RTL-4 / 模块 31:resp_merge(响应合并 + 重排 + AXI 成帧)

> **角色**:汇集 pipe(Hit)/ mshr(Fill)/ reloc 的整 line 响应,按原 burst 成帧 AXI R/B,保序返回上游。
> **代码**:[resp_merge.sv](../../rtl/resp_merge.sv)
> **架构出处**:§4.1 / §8.7;接口分组 (I)。

---

## 1. 功能

| 做什么 | 不做什么 |
|--------|---------|
| 持有每个 outstanding 事务的 burst 上下文(id/len/size/offset) | 命中判定 |
| 整 line → 按 offset/size 抽取 → 拆 AXI R beat(CWF 可先发请求字) | 数据存储 |
| 子请求(req_buffer 拆出的多行)按子序重组,保 burst 顺序 | — |
| 写响应 B(来自写命中/Fill) | — |
| SLVERR 注入(CRC 错 / 压力 / OOM tripped) | 中断本体(pressure_mon) |

---

## 2. 端口(冻结)

| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `clk`/`rst_n` | in | 1 | |
| **← cache_pipe_ctrl / mshr / page_reloc** | | | |
| `i_resp_valid`/`o_resp_ready` | in/out | 1 | 上游响应入 |
| `i_resp_id` | in | AXI_ID_W | |
| `i_resp_is_write` | in | 1 | |
| `i_resp_data` | in | LINE_BITS | 整 line |
| `i_resp_offset` | in | OFFSET_W | |
| `i_resp_code` | in | 2 | OKAY/SLVERR |
| **burst 上下文(← req_buffer 登记)** | | | |
| `i_ctx_push`/`i_ctx_id`/`i_ctx_len`/`i_ctx_size`/`i_ctx_first`/`i_ctx_last` | in | — | 拆分时登记 |
| **全局错误注入** | | | |
| `i_oom_tripped` | in | 1 | 受影响写 → SLVERR |
| **→ 上游 AXI(R/B)** | | | |
| `o_rvalid`/`i_rready`/`o_rid`/`o_rdata`/`o_rresp`/`o_rlast` | — | — | 读数据通道 |
| `o_bvalid`/`i_bready`/`o_bid`/`o_bresp` | — | — | 写响应通道 |

---

## 3. 内部:Reorder Buffer

```
ROB:按 id + 子序 索引;每项 {valid, beats_done, ctx}
入:i_resp 到 → 找 ctx → 抽取 offset/size → 入 ROB
出:按 burst 顺序(子请求 first..last)依次发 R beat,末拍 rlast;
   写:收齐该 id 的 W 后发 B
SLVERR:i_resp_code==SLVERR 或 (is_write & i_oom_tripped) → rresp/bresp=SLVERR
```

---

## 4. 波形

### 4.1 读 burst 成帧(2 行 → 多 R beat,保序)

```
cycle        T0      T1      T2      T3
i_resp_valid 1       1                       ← 行0、行1 响应到(可能乱序到达)
i_resp_id    ID/sub0 ID/sub1
o_rvalid     0       1       1       1        ← 按子序 0→1 发 beat
o_rid        -       ID      ID      ID
o_rdata      -       B0a     B0b     B1a...
o_rlast      -       0       ...     1(末beat)
i_rready     1       1       1       1
```

### 4.2 SLVERR(CRC 错 / OOM)

```
i_resp_code=SLVERR → o_rresp=SLVERR(读);
is_write & i_oom_tripped → o_bresp=SLVERR(写)→ master 可见错误(§3.3.4)
```

---

## 5. 验证要点

| 编号 | 场景 | 期望 |
|------|------|------|
| RM01 | 单行读响应 | 正确 R beat + rlast |
| RM02 | 多行乱序到达 | 按 burst 顺序输出 |
| RM03 | 写响应 B | 收齐后正确 bid/bresp |
| RM04 | CRC 错 SLVERR | rresp=SLVERR |
| RM05 | OOM 写 SLVERR | bresp=SLVERR |
| RM06 | CWF | 请求字优先返回 |

---

## 6. 决策清单
- [x] 端口冻结 + ROB + 成帧/SLVERR
- [ ] RTL
- [ ] UVM RM01-RM06
