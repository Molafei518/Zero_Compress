# Makefile — DV 流程(需 make;无 make 时直接看各 target 命令手动执行)
# 从 dv/sim/ 运行。

VEC_N ?= 256
TEST  ?= zc_base_test

.PHONY: golden ref unit uvm clean

# 1) 生成黄金向量(纯 Python,无仿真器)
golden:
	python ../golden/gen_vectors.py --n $(VEC_N)

# 2) 校验向量与 golden 自洽(纯 Python)
ref: golden
	python ../dpi/zc_ref.py

# 3) 单元 TB(Questa;向量驱动 line_crc8 / compress_top)
unit: golden
	vsim -c -do unit_crc8.do
	vsim -c -do unit_compress.do

# 4) 全 UVM(Questa;含 DPI-C golden)
uvm: golden
	vsim -c -do run_questa.do

# 备选:verilator lint(若安装)
lint:
	verilator --lint-only -sv -Wall --top-module cache_compress_top \
	  -f filelist.f 2>&1 | tee lint.log

clean:
	rm -rf work transcript *.vcd *.wlf lint.log
