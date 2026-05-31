# sub_l2p.do — l2p_meta_cache + l2p_dma 子系统(从 dv/sim/ 执行)
#   vsim -c -do sub_l2p.do
vlib work
vlog -sv ../../rtl/zc_pkg.sv ../../rtl/l2p_dma.sv ../../rtl/l2p_meta_cache.sv ../uvm/tb_sub_l2p.sv
vsim -c work.tb_sub_l2p
run -all
quit -f
