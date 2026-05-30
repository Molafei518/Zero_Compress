# filelist.f — 编译顺序(相对 dv/sim/)。+incdir 指向 uvm 类目录。
+incdir+../uvm
+incdir+../uvm/axi
+incdir+../uvm/seq

# ---- RTL:包 → 接口 → 叶子模块 → 顶层 ----
../../rtl/zc_pkg.sv
../../rtl/zc_if.sv
../../rtl/line_crc8.sv
../../rtl/crc_check.sv
../../rtl/zero_compress.sv
../../rtl/bdi_compress.sv
../../rtl/bytedelta_compress.sv
../../rtl/compress_top.sv
../../rtl/zero_decompress.sv
../../rtl/bdi_decompress.sv
../../rtl/bytedelta_decompress.sv
../../rtl/decompress_top.sv
../../rtl/ecc_secded.sv
../../rtl/tag_ram.sv
../../rtl/data_ram.sv
../../rtl/req_buffer.sv
../../rtl/addr_decode.sv
../../rtl/mshr.sv
../../rtl/l2p_meta_cache.sv
../../rtl/l2p_dma.sv
../../rtl/cache_pipe_ctrl.sv
../../rtl/space_alloc.sv
../../rtl/free_list.sv
../../rtl/gc_engine.sv
../../rtl/page_reloc.sv
../../rtl/pressure_mon.sv
../../rtl/resp_merge.sv
../../rtl/perf_counter.sv
../../rtl/apb_cfg.sv
../../rtl/cache_compress_top.sv

# ---- DPI-C golden ----
../dpi/zc_dpi.c

# ---- DV(UVM)----
../uvm/zc_dv_pkg.sv
../uvm/tb_top.sv
