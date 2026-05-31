# unit_roundtrip.do — 压缩往返自检(从 dv/sim/ 执行)
#   vsim -c -do unit_roundtrip.do
vlib work
vlog -sv ../../rtl/zc_pkg.sv \
        ../../rtl/zero_compress.sv ../../rtl/bdi_compress.sv \
        ../../rtl/bytedelta_compress.sv ../../rtl/line_crc8.sv ../../rtl/compress_top.sv \
        ../../rtl/zero_decompress.sv ../../rtl/bdi_decompress.sv \
        ../../rtl/bytedelta_decompress.sv ../../rtl/crc_check.sv ../../rtl/decompress_top.sv \
        ../uvm/tb_unit_roundtrip.sv
vsim -c work.tb_unit_roundtrip
run -all
quit -f
