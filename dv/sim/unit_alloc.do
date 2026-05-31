# unit_alloc.do — space_alloc(buddy)单元 TB(从 dv/sim/ 执行)
#   vsim -c -do unit_alloc.do
vlib work
vlog -sv ../../rtl/zc_pkg.sv ../../rtl/space_alloc.sv ../uvm/tb_unit_alloc.sv
vsim -c work.tb_unit_alloc
run -all
quit -f
