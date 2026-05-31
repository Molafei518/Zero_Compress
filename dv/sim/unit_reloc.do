# unit_reloc.do — page_reloc(9 状态 FSM)单元 TB(从 dv/sim/ 执行)
#   vsim -c -do unit_reloc.do
vlib work
vlog -sv ../../rtl/zc_pkg.sv ../../rtl/crc32.sv \
        ../../rtl/page_header_pack.sv ../../rtl/page_header_unpack.sv ../../rtl/space_alloc.sv \
        ../../rtl/zero_compress.sv ../../rtl/bdi_compress.sv ../../rtl/bytedelta_compress.sv \
        ../../rtl/line_crc8.sv ../../rtl/compress_top.sv \
        ../../rtl/zero_decompress.sv ../../rtl/bdi_decompress.sv ../../rtl/bytedelta_decompress.sv \
        ../../rtl/crc_check.sv ../../rtl/decompress_top.sv \
        ../../rtl/page_reloc.sv ../uvm/tb_unit_reloc.sv
vsim -c work.tb_unit_reloc
run -all
quit -f
