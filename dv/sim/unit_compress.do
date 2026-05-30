# unit_compress.do — 编译并运行 compress_top 单元 TB(从 dv/sim/ 执行)
#   vsim -c -do unit_compress.do
vlib work
vlog -sv ../../rtl/zc_pkg.sv \
        ../../rtl/zero_compress.sv ../../rtl/bdi_compress.sv \
        ../../rtl/bytedelta_compress.sv ../../rtl/line_crc8.sv \
        ../../rtl/compress_top.sv ../uvm/tb_unit_compress.sv
vsim -c work.tb_unit_compress
run -all
quit -f
