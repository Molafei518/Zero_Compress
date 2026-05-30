# ============================================================================
# run_questa.do — 全 UVM 构建与运行(从 dv/sim/ 执行)
#   vsim -c -do run_questa.do
#   单元 TB 用独立脚本(避免 -do 参数传递问题):
#     vsim -c -do unit_crc8.do
#     vsim -c -do unit_compress.do
#   依赖:Questa 自带 DPI C 编译;UVM 库(QUESTA_HOME/verilog_src/uvm-1.2)。
# ============================================================================
vlib work
vmap work work

# 编译 RTL + DPI(.c)+ DV(UVM)
vlog -sv +incdir+../uvm+../uvm/axi+../uvm/seq -f filelist.f

# 运行(UVM testbench 顶层 + 默认测试)
vsim -c -sv_seed random +UVM_TESTNAME=zc_base_test work.tb_top
run -all
quit -f
