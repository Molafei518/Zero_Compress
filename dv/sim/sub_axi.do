# sub_axi.do — AXI 端到端命中路径子系统(从 dv/sim/ 执行)
#   vsim -c -do sub_axi.do
vlib work
vlog -sv ../../rtl/zc_pkg.sv ../../rtl/tag_ram.sv ../../rtl/data_ram.sv \
        ../../rtl/cache_pipe_ctrl.sv ../../rtl/req_buffer.sv ../../rtl/addr_decode.sv \
        ../../rtl/resp_merge.sv ../uvm/tb_sub_axi.sv
vsim -c work.tb_sub_axi
run -all
quit -f
