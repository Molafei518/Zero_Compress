# unit_pagehdr.do — Page Header 编解码对拍 golden(从 dv/sim/ 执行)
#   vsim -c -do unit_pagehdr.do
vlib work
vlog -sv ../../rtl/zc_pkg.sv ../../rtl/crc32.sv \
        ../../rtl/page_header_pack.sv ../../rtl/page_header_unpack.sv \
        ../uvm/tb_unit_pagehdr.sv
vsim -c work.tb_unit_pagehdr
run -all
quit -f
