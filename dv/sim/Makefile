# Makefile — DV 流程(需 make;无 make 时直接看各 target 命令手动执行)
# 从 dv/sim/ 运行。

VEC_N ?= 256
TEST  ?= zc_base_test

.PHONY: golden ref unit subsys e2e miss wb meta salloc uvm lint clean

# 1) 生成黄金向量(纯 Python,无仿真器)
golden:
	python ../golden/gen_vectors.py --n $(VEC_N)

# 2) 校验向量与 golden 自洽(纯 Python)
ref: golden
	python ../dpi/zc_ref.py

# 3) 单元 TB(Questa;向量驱动 + 压缩往返自检)
unit: golden
	vsim -c -do unit_crc8.do
	vsim -c -do unit_compress.do
	vsim -c -do unit_roundtrip.do
	vsim -c -do unit_pagehdr.do
	vsim -c -do unit_alloc.do

# 3b) 子系统 TB(Cache 命中路径:pipe + tag + data)
subsys:
	vsim -c -do sub_cache.do

# 3c) AXI 端到端命中路径(AXI→req_buffer→addr_decode→cache→resp_merge→AXI)
e2e:
	vsim -c -do sub_axi.do

# 3d) 最小 miss 链(read-miss→DDR压缩→解压→fill→重读命中)
miss:
	vsim -c -do sub_miss.do

# 3e) 写读闭环(write-alloc→写入→evict 压缩存 DDR→read 解压读回)
wb:
	vsim -c -do sub_wb.do

# 3f) 真实元数据通路(L2P entry + Page Header 编解码,无旁路)
meta:
	vsim -c -do sub_meta.do

# 3g) PPA 经 space_alloc 真实分配(evict alloc / re-evict free+realloc)
salloc:
	vsim -c -do sub_alloc.do

# 4) 全 UVM(Questa;含 DPI-C golden)
uvm: golden
	vsim -c -do run_questa.do

# 备选:verilator lint(若安装)
lint:
	verilator --lint-only -sv -Wall --top-module cache_compress_top \
	  -f filelist.f 2>&1 | tee lint.log

clean:
	rm -rf work transcript *.vcd *.wlf lint.log
