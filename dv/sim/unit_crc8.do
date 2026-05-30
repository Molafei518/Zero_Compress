# unit_crc8.do — 编译并运行 line_crc8 单元 TB(从 dv/sim/ 执行)
#   vsim -c -do unit_crc8.do
vlib work
vlog -sv ../../rtl/zc_pkg.sv ../../rtl/line_crc8.sv ../uvm/tb_unit_crc8.sv
vsim -c work.tb_unit_crc8
run -all
quit -f
