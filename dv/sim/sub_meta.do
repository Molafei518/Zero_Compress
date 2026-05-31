# sub_meta.do — 真实元数据通路写读闭环(从 dv/sim/ 执行)
#   vsim -c -do sub_meta.do
vlib work
vlog -sv ../../rtl/zc_pkg.sv ../../rtl/tag_ram.sv ../../rtl/data_ram.sv \
        ../../rtl/cache_pipe_ctrl.sv ../../rtl/crc32.sv \
        ../../rtl/page_header_pack.sv ../../rtl/page_header_unpack.sv ../../rtl/mshr_meta.sv \
        ../../rtl/zero_compress.sv ../../rtl/bdi_compress.sv ../../rtl/bytedelta_compress.sv \
        ../../rtl/line_crc8.sv ../../rtl/compress_top.sv \
        ../../rtl/zero_decompress.sv ../../rtl/bdi_decompress.sv ../../rtl/bytedelta_decompress.sv \
        ../../rtl/crc_check.sv ../../rtl/decompress_top.sv \
        ../uvm/tb_sub_meta.sv
vsim -c work.tb_sub_meta
run -all
quit -f
