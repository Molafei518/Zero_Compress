# RTL-1 / 模块 03:cache_pipe_ctrl(Cache 主流水控制器)

> **角色**:Cache 4 级流水的主控,Hit 路径的全部逻辑都在这里;Miss/Evict 旁路到 MSHR。
> **代码**:[rtl/cache_pipe_ctrl.sv](../../rtl/cache_pipe_ctrl.sv)
> **架构出处**:主文档 §5.3 / §5.6 / §5.7 / §8.1 / §8.5;参数见 [zc_pkg](../../rtl/zc_pkg.sv)。
> **接口分组**:对应 [00_top](00_top_and_interfaces.md) 的 (B)(C)(D)(E)(I)。

---

## 1. 功能与边界

| 做什么 | 不做什么(交给谁) |
|--------|------------------|
| 接收 addr_decode 的请求,跑 REQ/TAG/DATA/RESP 4 级流水 | Bypass/NCA 判定(addr_decode 已定 `path`) |
| Tag 比较 + Hit/Miss 判定 + 4-way 并行数据读 + way-mux | Tag/Data SRAM 本体 + ECC(tag_ram/data_ram) |
| Read Hit 返回 / Write Hit 写回 + 置 Dirty | 同地址合并、Evict 压缩、Fill 解压(mshr + compress/decompress) |
| Miss 时分配 MSHR、选 victim(pLRU)、给出 evict 载荷 | L2P 查询、DDR 访问(mshr/l2p_meta_cache/l2p_dma) |
| pLRU 维护 | 响应重排与 AXI 成帧(resp_merge) |
| RAM 写端口仲裁(写命中 / MSHR fill 回填) | — |
| 冒险检测与 stall(MSHR 满 / reloc 锁 / 同 set 串行 / 同 line RAW) | — |

**边界原则**:Tag/Data SRAM 的**读写端口唯一属主是本模块**。MSHR 的 fill 回填不直接写 RAM,而是经本模块的 `fill_*` 接口仲裁,避免双属主竞争。

---

## 2. 端口表(冻结)

> 类型来自 `zc_pkg`。`i_`/`o_` = 模块输入/输出。握手 = valid/ready。

### 2.1 时钟/复位
| 端口 | 方向 | 类型 | 说明 |
|------|------|------|------|
| `clk` / `rst_n` | in | wire | 核心域 800MHz / 低有效 |

### 2.2 (B) 来自 addr_decode
| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `i_req_valid` | in | 1 | 请求有效 |
| `o_req_ready` | out | 1 | 流水可收(= 反压) |
| `i_addr` | in | LA_ADDR_W | LA 地址 |
| `i_id` | in | AXI_ID_W | Master AXI id |
| `i_is_write` | in | 1 | 1=写 0=读 |
| `i_path` | in | req_path_e | NORMAL/BYPASS/NCA |
| `i_wdata` | in | LINE_BITS | 写数据(整 line,sub-line 用 wstrb) |
| `i_wstrb` | in | LINE_BYTES | 写字节使能 |
| `i_offset` | in | OFFSET_W | 请求字节偏移(读 CWF / 子 line) |

### 2.3 (C) ↔ tag_ram
| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `o_tag_rd_en` | out | 1 | 读使能(S1 发) |
| `o_tag_index` | out | IDX_W | set 索引 |
| `i_tag_rdata` | in | tag_entry_t × N_WAY | 4 路 tag 并行读出(S2 到) |
| `i_tag_plru` | in | PLRU_W | 该 set 当前 pLRU |
| `o_tag_wr_en` | out | 1 | 写使能(置 dirty / fill / invalidate) |
| `o_tag_wr_way` | out | WAY_W | 写哪一路 |
| `o_tag_wdata` | out | tag_entry_t | 新 tag entry |
| `o_plru_we` | out | 1 | pLRU 更新使能 |
| `o_plru_upd` | out | PLRU_W | pLRU 新值 |

### 2.4 (D) ↔ data_ram(4-way 并行读 + 单路写)
| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `o_data_rd_en` | out | 1 | 读使能(S1 发,读全部 N_WAY) |
| `o_data_index` | out | IDX_W | set 索引 |
| `i_data_rdata` | in | LINE_BITS × N_WAY | 4 路并行读出(S2 到) |
| `o_data_wr_en` | out | 1 | 写使能 |
| `o_data_wr_way` | out | WAY_W | 写哪一路 |
| `o_data_wr_index` | out | IDX_W | 写 set |
| `o_data_wdata` | out | LINE_BITS | 写数据 |
| `o_data_wstrb` | out | LINE_BYTES | 写字节使能 |

### 2.5 (E) ↔ mshr
| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `o_mshr_alloc` | out | 1 | Miss 时申请 MSHR 项 |
| `o_mshr_addr` | out | LA_ADDR_W | Miss 地址 |
| `o_mshr_is_write` | out | 1 | Write-Allocate 标记 |
| `o_mshr_victim_way` | out | WAY_W | 选中替换路 |
| `o_mshr_victim_valid` | out | 1 | victim 是否 valid |
| `o_mshr_victim_dirty` | out | 1 | victim 是否需 Evict |
| `o_mshr_victim_tag` | out | TAG_W | victim 的 tag(还原 LA 页用) |
| `i_mshr_full` | in | 1 | MSHR 无空位 → stall |
| `i_mshr_merge` | in | 1 | 同地址已在 MSHR(合并,不重复取) |
| `i_block_valid` | in | 1 | reloc 锁定了某 LA 页 |
| `i_block_page` | in | LA_PAGE_W | 被锁页号 |
| **fill 回填(MSHR→pipe,经本模块写 RAM)** | | | |
| `i_fill_valid` | in | 1 | MSHR 取回+解压完成,请求回填 |
| `i_fill_index` | in | IDX_W | 回填 set |
| `i_fill_way` | in | WAY_W | 回填路 |
| `i_fill_tag` | in | TAG_W | 回填 tag |
| `i_fill_data` | in | LINE_BITS | 解压后整 line |
| `i_fill_dirty` | in | 1 | Write-Allocate 回填后即 dirty |
| `o_fill_ready` | out | 1 | 本模块接受回填(端口仲裁通过) |

### 2.6 (I) → resp_merge
| 端口 | 方向 | 宽度 | 说明 |
|------|------|------|------|
| `o_resp_valid` | out | 1 | 响应有效 |
| `o_resp_id` | out | AXI_ID_W | 透传 master id |
| `o_resp_is_write` | out | 1 | 1=写响应(B) 0=读(R) |
| `o_resp_data` | out | LINE_BITS | 读命中整 line(resp_merge 按 offset/len 成帧) |
| `o_resp_offset` | out | OFFSET_W | 请求字节偏移 |
| `o_resp_code` | out | 2 | OKAY / SLVERR |
| `i_resp_ready` | in | 1 | resp_merge 反压 |

### 2.7 配置/采样
| 端口 | 方向 | 说明 |
|------|------|------|
| `i_cache_en` | in | `cfg_cache_en`;0 时全部走 MSHR/bypass |
| `o_perf_hit` / `o_perf_miss` / `o_perf_wr_hit` / `o_perf_wr_miss` | out | 给 perf_counter 的单拍脉冲 |

---

## 3. 流水线结构(4 级)

```
 S1 REQ            S2 TAG            S3 DATA            S4 RESP
 ┌───────┐  reg   ┌───────┐  reg   ┌───────┐  reg     ┌───────┐
 │decode │ ─────► │tag cmp│ ─────► │way mux│ ─────►    │ drive │
 │issue  │        │→hit   │        │R:fwd  │           │ resp  │
 │RAM rd │        │→way   │        │W:write│           │ merge │
 │       │        │pLRU rd│        │M:MSHR │           │       │
 └───────┘        └───────┘        └───────┘           └───────┘
   发 tag_rd        SRAM 输出回      比较结果选路        读命中数据
   + data_rd(全路)  (registered)     (compare 在 S2 末    返回 master
                    tag/data 同到     →S3 用)            (4 cycle)
```

各级动作:

- **S1 REQ**:握手收请求;`addr` 分解(`cache_index/cache_tag/la_line_idx`,见 zc_pkg 函数);若 `i_cache_en && path==NORMAL` → 拉 `o_tag_rd_en` + `o_data_rd_en`(4 路全读,index 相同),载荷入 S1/S2 流水寄存器。`path==BYPASS` → 不查 Cache,直接造一条 MSHR/直通请求。`path==NCA` → 跳 Cache 命中但仍走压缩通路(经 MSHR)。
- **S2 TAG**:SRAM 输出 `i_tag_rdata[N_WAY]` 与 `i_data_rdata[N_WAY]` 同拍到达。组合算:
  - `way_hit[w] = i_tag_rdata[w].valid && (i_tag_rdata[w].tag == tag_s2)`
  - `hit = |way_hit`;`hit_way = onehot2bin(way_hit)`
  - 读 `i_tag_plru` 算 `plru_next`。结果寄存到 S3。
- **S3 DATA**:按 `hit/is_write` 分流(见 §4)。way-mux:`line = i_data_rdata[hit_way]`。写命中 → 发 `o_data_wr_*` + `o_tag_wr_*`(置 dirty)。Miss → 发 `o_mshr_alloc` + victim 载荷。
- **S4 RESP**:读命中把 `line/offset/id/OKAY` 推 resp_merge(总 4 cycle);写命中可在 S3 即给写响应(3 cycle,见 §6)。

> **时序关键点(对齐 §5.3)**:tag 比较(25-bit × 4 + valid)与 way-mux 放在 **S2 末→S3** 的组合路径,**数据 4 路在 S2 已并行读出**,compare 结果只做 mux 选择,不串到 SRAM 读地址上。这是 Hit 4-cycle 收敛的关键(避免 tag→data 串行)。代价:每次访问读 4 路数据,功耗略高(可接受;省下的是关键路径)。

---

## 4. Hit/Miss/Write 判定与动作

```
S3 决策表:
┌──────────┬─────────┬────────────────────────────────────────────────┐
│ is_write │  hit    │ 动作                                            │
├──────────┼─────────┼────────────────────────────────────────────────┤
│   0 (R)  │  1      │ way-mux 取 line → S4 返回(CWF:按 offset 先发) │
│   0 (R)  │  0      │ MSHR alloc(读填);victim 由 pLRU 选;dirty→evict│
│   1 (W)  │  1      │ data_ram 写(wdata/wstrb)+ tag 置 dirty;S3 写响应│
│   1 (W)  │  0      │ MSHR alloc(Write-Allocate);victim 处理同上     │
└──────────┴─────────┴────────────────────────────────────────────────┘

victim 选择:way_victim = plru_victim(i_tag_plru)
  - victim.valid && victim.dirty → o_mshr_victim_dirty=1(MSHR 走 Evict:读数据→压缩→写 DDR)
  - 否则直接占用该 way 等 fill
```

**Fill 回填**(MSHR 取回+解压后):MSHR 拉 `i_fill_valid`,本模块在 RAM 端口空闲拍接受(`o_fill_ready`),写 `i_fill_data` 到 `data_ram[index][way]`、写 `i_fill_tag` 到 `tag_ram`、更新 pLRU。回填与流水写命中竞争 RAM 写端口,优先级见 §5。

---

## 5. 冒险与 stall(冻结的仲裁规则)

| 冒险 | 条件 | 处理 |
|------|------|------|
| **MSHR 满** | `i_mshr_full` 且当前需 alloc | `o_req_ready=0`,S1 反压上游 |
| **Reloc 锁** | `i_block_valid && i_block_page==la_page(req)` | 停该页请求至 reloc `done`;异页不受影响 |
| **同 set 串行** | victim 正被 Evict(同 index 已有 in-flight miss) | 第二个 miss 在 S3 stall,等前一个 MSHR 进展(防重复 Evict) |
| **同 line RAW** | S3 写命中 line == 后续请求 S2 读同 line | 旁路转发 S3 写数据,或 1 拍 stall(基线:stall,简单) |
| **RAM 写端口争用** | fill 回填 与 流水写命中 同拍写 data_ram | 优先级:**fill > 写命中**(fill 在关键 miss 链上);写命中 stall 1 拍 |
| **resp 反压** | `i_resp_ready=0` | S4 hold,回压 S3/S2/S1 |
| **Cache 关闭** | `i_cache_en=0` | 全部请求当 miss/bypass 处理,不查 tag |

stall 采用**整级冻结**:任一级 stall 时其上游级一并冻结(标准 valid/ready 流水)。

---

## 6. 关键时序

| 路径 | 周期 | 依据 |
|------|------|------|
| Read Hit | 4 cycle(REQ→TAG→DATA→RESP) | §8.1 |
| Write Hit | 3 cycle(S3 写 + 写响应) | §8.5 |
| Miss | S1-S3 后转 MSHR,延迟由 MSHR 链决定 | §8.2/§8.3 |
| 关键组合路径 | S2 末:`tag==` 比较(25b×4)→ way one-hot → S3 data mux | §5.3 |

> Hit 4-cycle 是 P0 硬约束。综合若不收敛:先切 S2→S3 的 compare/mux 寄存器边界,或降 N_WAY,或对 tag 比较做低位预译码。

---

## 7. 内部状态(非 FSM,流水寄存器为主)

本模块**无大型 FSM**(Miss 后的多周期序列归 MSHR);只有:
- 3 组流水级寄存器(S1→S2→S3→S4 的 payload:addr/id/is_write/path/wdata/wstrb/offset)。
- 同 set in-flight 记分牌(防重复 Evict;可用 MSHR 的 set busy 位代替)。
- RAM 写端口仲裁的组合优先级逻辑。

---

## 8. 验证要点(给 UVM)

| 编号 | 场景 | 期望 |
|------|------|------|
| PV01 | 连续 Read Hit 背靠背 | 每拍出一个结果,4-cycle 延迟,吞吐 1/cyc |
| PV02 | Write Hit | 3 cycle,data_ram 被写,dirty 置位 |
| PV03 | Read Miss(victim clean) | MSHR alloc,无 evict,fill 后命中 |
| PV04 | Read Miss(victim dirty) | evict 载荷正确(way/tag/dirty),fill 正确 |
| PV05 | 同 line 写后读 | 数据一致(转发或 stall 后正确) |
| PV06 | 同 set 连续 miss | 串行,无重复 Evict |
| PV07 | MSHR 满 | 上游正确反压,不丢请求 |
| PV08 | reloc 锁中访问同页 | stall 至 done 后返回新数据;异页 Hit 仍 4 cycle |
| PV09 | fill 与写命中同拍争 RAM | fill 优先,写命中延 1 拍,二者最终都正确 |
| PV10 | Cache 关闭(cfg_cache_en=0) | 全 miss/bypass,不误命中 |
| PV11 | pLRU 正确性 | 4-way 访问序列后 victim 符合 tree-pLRU |

形式(JasperGold):流水不死锁;valid/ready 无组合环;`hit` one-hot(不会两路同时命中)。

---

## 9. 决策清单
- [x] 端口冻结(本文 §2)
- [x] 4 级流水语义 + 并行读-后-mux 时序策略
- [x] 冒险/仲裁规则
- [ ] RTL 内部逻辑实现(当前 .sv 为骨架)
- [ ] UVM 序列 PV01-PV11
