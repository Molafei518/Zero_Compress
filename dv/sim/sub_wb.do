# sub_wb.do — 写读闭环(Evict 压缩写回 + write-allocate)(从 dv/sim/ 执行)
#   vsim -c -do sub_wb.do
vlib work
vlog -sv ../../rtl/zc_pkg.sv ../../rtl/tag_ram.sv ../../rtl/data_ram.sv \
        ../../rtl/cache_pipe_ctrl.sv ../../rtl/mshr_wb.sv \
        ../../rtl/zero_compress.sv ../../rtl/bdi_compress.sv ../../rtl/bytedelta_compress.sv \
        ../../rtl/line_crc8.sv ../../rtl/compress_top.sv \
        ../../rtl/zero_decompress.sv ../../rtl/bdi_decompress.sv ../../rtl/bytedelta_decompress.sv \
        ../../rtl/crc_check.sv ../../rtl/decompress_top.sv \
        ../uvm/tb_sub_wb.sv
vsim -c work.tb_sub_wb
run -all
quit -f
