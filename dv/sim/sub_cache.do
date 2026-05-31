# sub_cache.do — Cache 子系统 TB(从 dv/sim/ 执行)
#   vsim -c -do sub_cache.do
vlib work
vlog -sv ../../rtl/zc_pkg.sv ../../rtl/tag_ram.sv ../../rtl/data_ram.sv \
        ../../rtl/cache_pipe_ctrl.sv ../uvm/tb_sub_cache.sv
vsim -c work.tb_sub_cache
run -all
quit -f
