# dv/ — 验证环境(UVM + DPI-C golden + 向量层)

> 三层结构,**越上层越能"现在就跑"**:
> 1. **黄金向量层**(纯 Python,无仿真器即可跑)—— scoreboard 的事实基准。
> 2. **DPI-C 桥**(C 镜像 + Python 镜像)—— Questa 在线对拍。
> 3. **UVM 环境**(AXI agent + ref_model + scoreboard)+ 单元 TB —— 需 SV 仿真器。

```
dv/
├── golden/
│   ├── gen_vectors.py        # 复用 tools/ 生成 crc8/compress/pagehdr 向量(.mem + .json)
│   └── vectors/              # 生成物(.mem 供 $readmemh,.json 供 DPI/cocotb)
├── dpi/
│   ├── zc_dpi.h / zc_dpi.c   # C golden(crc8/crc32/compress);Python golden 的镜像
│   └── zc_ref.py             # Python 镜像 + 向量自洽交叉校验(可直接跑)
├── uvm/
│   ├── zc_dv_pkg.sv          # UVM + DPI 导入 + 类包含
│   ├── axi/                  # axi_seq_item / driver / monitor / agent(master BFM)
│   ├── zc_ref_model.sv       # 透明内存模型 + DPI 压缩率统计
│   ├── zc_scoreboard.sv      # 端到端:读返回 == 写入(透明性)
│   ├── zc_env.sv / zc_base_test.sv / seq/seq_smoke.sv
│   ├── tb_top.sv             # 全 IP UVM 顶层(DUT = cache_compress_top)
│   ├── tb_unit_crc8.sv       # 向量驱动:line_crc8(已实现,可直接对拍)
│   └── tb_unit_compress.sv   # 向量驱动:compress_top 的 {algo,mode,size}
└── sim/
    ├── filelist.f            # 编译顺序
    ├── run_questa.do         # Questa 构建/运行(全 UVM 或 unit)
    └── Makefile              # golden / ref / unit / uvm / lint 目标
```

## 现在就能跑(本机已验证)

```bash
# 1) 生成向量
python dv/golden/gen_vectors.py --n 256
# 2) 校验向量与 golden 自洽
python dv/dpi/zc_ref.py
```

## 有 SV 仿真器(Questa/ModelSim,本机 vsim 2021.1 已验证)时

```bash
cd dv/sim
vsim -c -do unit_crc8.do        # ✅ line_crc8 vs 128 golden CRC8 → ALL PASS(已实跑)
vsim -c -do unit_compress.do    # ✅ compress_top {algo,mode,size} vs 128 golden → ALL PASS(已实跑)
vsim -c -do run_questa.do       # 全 UVM(含 DPI-C golden;DUT 实现后端到端生效)
```

> **已验证结果(Questa Sim 2021.1)**:`line_crc8.sv` 与 `compress_top.sv`(+三引擎)
> 编译 0 错 0 警,并与 Python golden 在 128 条向量上逐位一致(含 tie-break Zero>ByteDelta>BDI)。

## golden 一致性契约(三方必须一致)

| 项 | Python golden | C DPI | RTL |
|----|---------------|-------|-----|
| CRC8 | page_header_codec.crc8(poly 0x1D,init 0xFF) | zc_crc8 | line_crc8.sv |
| CRC32 | page_header_codec.crc32_ieee | zc_crc32 | (page_header pack,TODO) |
| 压缩 size/mode | compress_eval.compress_* | zc_dpi comp_* | 三引擎 .sv |
| tie-break | **Zero > ByteDelta > BDI** | 同 | compress_top.sv 同 |

> 修改任一压缩/CRC 逻辑,三处必须同步,并重跑 `gen_vectors.py` + `zc_ref.py`。

## 状态

- ✅ 黄金向量层、DPI/Python 镜像、向量自洽校验:**可运行**
- ✅ UVM 环境骨架、单元 TB、Questa 脚本:**结构就位**
- ⏳ AXI driver/monitor 的完整握手、DUT 内部实现、下游 DDR 行为模型:TODO
  (DUT 当前为端口冻结骨架;端到端 scoreboard 待 DUT 实现后生效)
