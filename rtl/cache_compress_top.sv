// ============================================================================
// cache_compress_top.sv — DDR Cache+Compress IP 顶层(接口/参数冻结骨架)
//
//   对应架构文档 §4.1 顶层框图 / §9 接口。
//   本文件冻结:顶层端口、时钟复位、子模块层次与模块间互联网。
//   各子模块内部实现见 RTL-1..4 的设计文档 + 模块骨架。
//
//   注:本骨架不含子模块实现,故"例化区"以块注释保留连线意图,
//       使 zc_pkg + zc_if + 本文件可独立编译通过(lint 级)。
//       各模块端口在其设计文档冻结后,解开注释并补 .sv 即可。
// ============================================================================
`default_nettype none

module cache_compress_top
  import zc_pkg::*;
#(
  // 允许例化时覆盖(默认 = zc_pkg 冻结值)
  parameter int unsigned LA_ADDR_W_P = zc_pkg::LA_ADDR_W,
  parameter int unsigned AXI_DATA_W_P= zc_pkg::AXI_DATA_W,
  parameter int unsigned AXI_ID_W_P  = zc_pkg::AXI_ID_W
) (
  // -- 时钟与复位 --
  input  wire                       clk,        // 核心时钟(默认 800MHz)
  input  wire                       rst_n,      // 异步复位,同步释放
  input  wire                       pclk,       // APB 时钟
  input  wire                       presetn,

  // -- 启动 strap(BootROM 之前由 pin 决定)--
  input  wire [1:0]                 strap_cap_ratio, // 00=1.25 01=1.5 10=1.75 11=2.0

  // -- 上游 AXI4(来自 Arbiter):IP 为 slave --
  zc_axi_if.slave                   s_axi,

  // -- 下游 AXI(到 Scheduler/DDR):IP 为 master,ID 宽 = DS_ID_W --
  zc_axi_if.master                  m_axi,

  // -- APB 配置:IP 为 slave --
  zc_apb_if.slave                   apb,

  // -- 中断(4 条,文档 04 §3)--
  output wire [N_IRQ-1:0]           irq,

  // -- Mailbox 共享 SRAM(4KB,双向 ring;此处暴露 IP 侧读写口)--
  output wire                       mbox_req,
  output wire                       mbox_we,
  output wire [11:0]                mbox_addr,   // 4KB
  output wire [31:0]                mbox_wdata,
  input  wire [31:0]                mbox_rdata,
  input  wire                       mbox_ack
);

  // ==========================================================================
  // 0. 顶层断言:参数与 zc_pkg 一致(防止覆盖出不一致几何)
  // ==========================================================================
  // synthesis translate_off
  initial begin
    assert (AXI_DATA_W_P == zc_pkg::AXI_DATA_W)
      else $error("AXI_DATA_W mismatch with zc_pkg");
  end
  // synthesis translate_on

  // ==========================================================================
  // 1. 模块间互联网(inter-module nets)—— 按数据流分组冻结
  //    命名约定:<src>_<dst>_<signal>;valid/ready 握手成对。
  // ==========================================================================

  // ---- (A) req_buffer → addr_decode ----
  logic                     rb_ad_valid;
  logic                     rb_ad_ready;
  logic [LA_ADDR_W-1:0]     rb_ad_addr;
  logic [AXI_ID_W-1:0]      rb_ad_id;
  logic                     rb_ad_is_write;
  logic [7:0]               rb_ad_len;
  logic [2:0]               rb_ad_prot;
  logic [3:0]               rb_ad_cache;

  // ---- (B) addr_decode → cache_pipe_ctrl ----
  logic                     ad_pipe_valid;
  logic                     ad_pipe_ready;
  logic [LA_ADDR_W-1:0]     ad_pipe_addr;
  logic [AXI_ID_W-1:0]      ad_pipe_id;
  logic                     ad_pipe_is_write;
  req_path_e                ad_pipe_path;     // NORMAL / BYPASS / NCA

  // ---- (C) cache_pipe_ctrl ↔ tag_ram ----
  logic                     pipe_tag_rd_en;
  logic [IDX_W-1:0]         pipe_tag_index;
  tag_entry_t [N_WAY-1:0]   tag_pipe_rdata;   // 4-way 并行读出
  logic                     pipe_tag_wr_en;
  logic [WAY_W-1:0]         pipe_tag_wr_way;
  tag_entry_t               pipe_tag_wdata;
  logic [PLRU_W-1:0]        tag_pipe_plru;
  logic [PLRU_W-1:0]        pipe_tag_plru_upd;

  // ---- (D) cache_pipe_ctrl ↔ data_ram ----
  logic                     pipe_data_rd_en;
  logic [IDX_W-1:0]         pipe_data_index;
  logic [WAY_W-1:0]         pipe_data_way;
  logic [LINE_BITS-1:0]     data_pipe_rdata;
  logic                     pipe_data_wr_en;
  logic [LINE_BITS-1:0]     pipe_data_wdata;
  logic [LINE_BYTES-1:0]    pipe_data_wstrb;

  // ---- (E) cache_pipe_ctrl ↔ mshr ----
  logic                     pipe_mshr_alloc;
  logic [LA_ADDR_W-1:0]     pipe_mshr_addr;
  logic                     mshr_full;
  logic                     mshr_hit_existing; // 同地址合并
  mshr_state_e [MSHR_DEPTH-1:0] mshr_state;

  // ---- (F) mshr ↔ l2p_meta_cache / l2p_dma ----
  logic                     meta_lookup_req;
  logic [LA_PAGE_W-1:0]     meta_lookup_page;
  logic                     meta_lookup_hit;
  l2p_entry_t               meta_lookup_entry;
  logic                     meta_hdr_valid;
  logic [HEADER_BYTES*8-1:0] meta_hdr_data;
  logic                     l2p_dma_req;       // meta miss → DDR 取
  logic                     l2p_dma_done;

  // ---- (G) compress / decompress ----
  logic                     comp_req;
  logic [LINE_BITS-1:0]     comp_in;
  logic                     comp_done;
  algo_e                    comp_algo;
  logic [2:0]               comp_mode;
  logic [6:0]               comp_size;         // 1..64
  logic [LINE_BITS-1:0]     comp_out;          // 压缩 byte 序列(左对齐)
  logic [7:0]               comp_crc8;

  logic                     decomp_req;
  algo_e                    decomp_algo;
  logic [2:0]               decomp_mode;
  logic [6:0]               decomp_size;
  logic [LINE_BITS-1:0]     decomp_in;
  logic [7:0]               decomp_crc8_exp;
  logic                     decomp_done;
  logic [LINE_BITS-1:0]     decomp_out;
  logic                     decomp_crc_err;

  // ---- (H) space_alloc / gc / reloc ----
  logic                     alloc_req;
  logic [12:0]              alloc_size;        // 需要的字节(含 header)
  logic                     alloc_ack;
  logic                     alloc_fail;        // → IRQ_HARD_FULL
  logic [31:0]              alloc_ppa_ptr;
  logic                     free_req;
  logic [31:0]              free_ppa_ptr;
  logic [12:0]              free_size;

  reloc_trig_e              reloc_trig;
  logic [LA_PAGE_W-1:0]     reloc_trig_page;
  reloc_state_e             reloc_state;
  logic                     reloc_busy;
  logic                     reloc_done_pulse;
  logic                     mshr_block_la_valid; // reloc 阻塞同 LA
  logic [LA_PAGE_W-1:0]     mshr_block_la_page;

  // ---- (I) resp_merge → s_axi(读/写响应) ----
  logic                     rm_resp_valid;
  logic [AXI_ID_W-1:0]      rm_resp_id;
  logic [LINE_BITS-1:0]     rm_resp_data;
  logic [1:0]               rm_resp_code;      // OKAY/SLVERR

  // ---- (J) pressure_mon / 配置 / 中断 ----
  waterlevel_e              cur_waterlevel;
  logic [6:0]               cur_cap_usage_pct;
  logic [N_IRQ-1:0]         irq_set;           // 各源置位
  logic                     cfg_cache_en;
  logic                     cfg_compress_en;
  logic                     cfg_gc_en;
  logic [7:0]               cfg_cap_ratio_x100;
  logic [31:0]              cfg_l2p_base_lo, cfg_l2p_base_hi;
  logic [31:0]              cfg_meta_base_lo, cfg_meta_base_hi;
  // bypass 区间(N_BYPASS_REGION 组 start/end)
  logic [LA_ADDR_W-1:0]     cfg_bypass_start [N_BYPASS_REGION];
  logic [LA_ADDR_W-1:0]     cfg_bypass_end   [N_BYPASS_REGION];

  // ---- (K) perf_counter ----
  logic [N_PERF_CNT-1:0]    perf_inc;          // 各计数器 +1 脉冲(示意)

  // ==========================================================================
  // 2. 子模块例化骨架(待各模块设计文档冻结端口后启用)
  //    层次对应架构 §4.2。Phase 划分见 §13:
  //      Phase 1: req_buffer/addr_decode/cache_pipe_ctrl/tag_ram/data_ram/
  //               mshr/l2p_meta_cache/l2p_dma/resp_merge/apb_cfg/perf_counter
  //      Phase 2: compress_top/decompress_top/page_reloc
  //      Phase 3: space_alloc/free_list/gc_engine/pressure_mon + ecc
  // ==========================================================================
  /* ------------------------------------------------------------------------
  req_buffer u_req_buffer (
    .clk, .rst_n,
    .s_axi              (s_axi),          // 接收上游 AR/AW/W
    .o_valid (rb_ad_valid), .o_ready (rb_ad_ready),
    .o_addr  (rb_ad_addr),  .o_id    (rb_ad_id),
    .o_is_write(rb_ad_is_write), .o_len(rb_ad_len),
    .o_prot  (rb_ad_prot),  .o_cache (rb_ad_cache)
  );

  addr_decode u_addr_decode (
    .clk, .rst_n,
    .i_valid (rb_ad_valid), .i_ready (rb_ad_ready),
    .i_addr  (rb_ad_addr),  .i_id    (rb_ad_id),
    .i_is_write(rb_ad_is_write), .i_prot(rb_ad_prot), .i_cache(rb_ad_cache),
    .cfg_bypass_start(cfg_bypass_start), .cfg_bypass_end(cfg_bypass_end),
    .o_valid (ad_pipe_valid), .o_ready (ad_pipe_ready),
    .o_addr  (ad_pipe_addr),  .o_id    (ad_pipe_id),
    .o_is_write(ad_pipe_is_write), .o_path(ad_pipe_path)
  );

  cache_pipe_ctrl u_cache_pipe_ctrl (
    .clk, .rst_n,
    .i_valid(ad_pipe_valid), .i_ready(ad_pipe_ready),
    .i_addr (ad_pipe_addr),  .i_id(ad_pipe_id),
    .i_is_write(ad_pipe_is_write), .i_path(ad_pipe_path),
    .tag_rd_en(pipe_tag_rd_en), .tag_index(pipe_tag_index), .tag_rdata(tag_pipe_rdata),
    .tag_wr_en(pipe_tag_wr_en), .tag_wr_way(pipe_tag_wr_way), .tag_wdata(pipe_tag_wdata),
    .data_rd_en(pipe_data_rd_en), .data_index(pipe_data_index), .data_way(pipe_data_way),
    .data_rdata(data_pipe_rdata),
    .data_wr_en(pipe_data_wr_en), .data_wdata(pipe_data_wdata), .data_wstrb(pipe_data_wstrb),
    .mshr_alloc(pipe_mshr_alloc), .mshr_addr(pipe_mshr_addr),
    .mshr_full(mshr_full), .mshr_block_valid(mshr_block_la_valid),
    .resp_valid(rm_resp_valid), .resp_id(rm_resp_id),
    .resp_data(rm_resp_data),   .resp_code(rm_resp_code)
  );

  tag_ram        u_tag_ram (...);
  data_ram       u_data_ram (...);
  mshr           u_mshr (...);
  l2p_meta_cache u_l2p_meta_cache (...);
  l2p_dma        u_l2p_dma (...);
  compress_top   u_compress_top (...);
  decompress_top u_decompress_top (...);
  space_alloc    u_space_alloc (...);   // 内含 free_list / gc_engine
  page_reloc     u_page_reloc (...);
  pressure_mon   u_pressure_mon (...);
  resp_merge     u_resp_merge (...);
  perf_counter   u_perf_counter (...);
  apb_cfg        u_apb_cfg (...);
  ------------------------------------------------------------------------ */

  // ==========================================================================
  // 3. 骨架期安全 tie-off(子模块就绪后移除)
  // ==========================================================================
  assign irq        = '0;
  assign mbox_req   = 1'b0;
  assign mbox_we    = 1'b0;
  assign mbox_addr  = '0;
  assign mbox_wdata = '0;

endmodule : cache_compress_top

`default_nettype wire
