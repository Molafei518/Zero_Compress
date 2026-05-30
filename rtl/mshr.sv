// ============================================================================
// mshr.sv — Miss Status Holding Registers(8 项,每项 9 态 FSM)
//   设计文档:docs/rtl/06_mshr.md   架构:§5.4 / §5.7 / §8.2 / §8.4
//   骨架:entry 阵列 + 合并/分配逻辑 + 每项 FSM 转移占位;数据通路 TODO。
// ============================================================================
`default_nettype none

module mshr
  import zc_pkg::*;
(
  input  wire                   clk,
  input  wire                   rst_n,

  // (E) <- cache_pipe_ctrl
  input  wire                   i_alloc,
  input  wire [LA_ADDR_W-1:0]   i_addr,
  input  wire                   i_is_write,
  input  wire [WAY_W-1:0]       i_victim_way,
  input  wire                   i_victim_valid,
  input  wire                   i_victim_dirty,
  input  wire [TAG_W-1:0]       i_victim_tag,
  output logic                  o_full,
  output logic                  o_merge,

  // fill -> pipe
  output logic                  o_fill_valid,
  input  wire                   i_fill_ready,
  output logic [IDX_W-1:0]      o_fill_index,
  output logic [WAY_W-1:0]      o_fill_way,
  output logic [TAG_W-1:0]      o_fill_tag,
  output logic [LINE_BITS-1:0]  o_fill_data,
  output logic                  o_fill_dirty,

  // (F) <-> l2p_meta_cache
  output logic                  o_meta_lookup,
  output logic [LA_PAGE_W-1:0]  o_meta_page,
  input  wire                   i_meta_hit,
  input  l2p_entry_t            i_meta_entry,
  input  wire                   i_meta_hdr_valid,
  input  wire [HEADER_BYTES*8-1:0] i_meta_hdr,

  // (G) <-> compress / decompress
  output logic                  o_comp_req,
  output logic [LINE_BITS-1:0]  o_comp_in,
  input  wire                   i_comp_done,
  input  algo_e                 i_comp_algo,
  input  wire [6:0]             i_comp_size,
  input  wire [LINE_BITS-1:0]   i_comp_out,
  input  wire [7:0]             i_comp_crc8,
  output logic                  o_decomp_req,
  output algo_e                 o_decomp_algo,
  output logic [6:0]            o_decomp_size,
  output logic [LINE_BITS-1:0]  o_decomp_in,
  output logic [7:0]            o_decomp_crc8_exp,
  input  wire                   i_decomp_done,
  input  wire [LINE_BITS-1:0]   i_decomp_out,
  input  wire                   i_decomp_crc_err,

  // (H) <-> space_alloc / page_reloc
  output logic                  o_alloc_req,
  output logic [12:0]           o_alloc_size,
  input  wire                   i_alloc_ack,
  input  wire                   i_alloc_fail,
  input  wire [31:0]            i_alloc_ppa,
  output reloc_trig_e           o_reloc_trig,
  output logic [LA_PAGE_W-1:0]  o_reloc_page,
  input  wire                   i_reloc_busy,
  input  wire                   i_reloc_done,
  output logic                  o_block_la_valid,
  output logic [LA_PAGE_W-1:0]  o_block_la_page,

  // 下游 DDR 事务(经 m_axi;此处抽象成 req/done,集成时接 resp_merge/arbiter)
  output logic                  o_ddr_rd_req,
  output logic [DPA_ADDR_W-1:0] o_ddr_rd_addr,
  input  wire                   i_ddr_rd_done,
  input  wire [LINE_BITS-1:0]   i_ddr_rd_data,
  output logic                  o_ddr_wr_req,
  output logic [DPA_ADDR_W-1:0] o_ddr_wr_addr,
  output logic [LINE_BITS-1:0]  o_ddr_wr_data,
  input  wire                   i_ddr_wr_done
);

  // ==========================================================================
  // entry 阵列
  // ==========================================================================
  typedef struct packed {
    logic                  valid;
    logic [TAG_W-1:0]      tag;
    logic [IDX_W-1:0]      index;
    mshr_state_e           state;
    logic [MSHR_DEPTH-1:0] req_list;   // 同地址合并 bitmap
    logic [WAY_W-1:0]      way_alloc;
    logic                  is_write;
    logic                  victim_dirty;
    logic [TAG_W-1:0]      victim_tag;
    l2p_entry_t            l2p;
    logic [31:0]           gen_at_lookup;
  } mshr_entry_t;

  mshr_entry_t ent [MSHR_DEPTH];

  // reloc 锁(深度 1)
  logic                 block_valid;
  logic [LA_PAGE_W-1:0] block_page;
  assign o_block_la_valid = block_valid;
  assign o_block_la_page  = block_page;

  // ---- 分配 / 合并组合 ----
  wire [TAG_W-1:0] in_tag   = cache_tag(i_addr);
  wire [IDX_W-1:0] in_index = cache_index(i_addr);
  wire [LA_PAGE_W-1:0] in_page = la_page_num(i_addr);

  logic        any_free, merge_hit;
  logic [MSHR_IDX_W-1:0] free_idx, merge_idx;
  always_comb begin
    any_free = 1'b0; free_idx = '0; merge_hit = 1'b0; merge_idx = '0;
    for (int e = 0; e < MSHR_DEPTH; e++) begin
      if (!ent[e].valid) begin any_free = 1'b1; free_idx = e[MSHR_IDX_W-1:0]; end
      if (ent[e].valid && ent[e].tag==in_tag && ent[e].index==in_index) begin
        merge_hit = 1'b1; merge_idx = e[MSHR_IDX_W-1:0];
      end
    end
  end
  assign o_full  = ~any_free;
  assign o_merge = merge_hit;

  // ==========================================================================
  // per-entry FSM(骨架:仅给状态转移框架,数据通路/仲裁 TODO)
  // ==========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int e = 0; e < MSHR_DEPTH; e++) begin
        ent[e].valid <= 1'b0;
        ent[e].state <= MSHR_IDLE;
      end
      block_valid <= 1'b0;
    end else begin
      // -- 新请求:合并 or 建项 --
      if (i_alloc) begin
        if (merge_hit) begin
          // ent[merge_idx].req_list |= ...;  // TODO: 记录请求 id/offset
        end else if (any_free && !(block_valid && block_page==in_page)) begin
          ent[free_idx].valid        <= 1'b1;
          ent[free_idx].tag          <= in_tag;
          ent[free_idx].index        <= in_index;
          ent[free_idx].is_write     <= i_is_write;
          ent[free_idx].victim_dirty <= i_victim_valid & i_victim_dirty;
          ent[free_idx].victim_tag   <= i_victim_tag;
          ent[free_idx].way_alloc    <= i_victim_way;
          ent[free_idx].state        <= MSHR_L2P_LOOKUP;
        end
      end

      // -- 各 entry 推进(此处仅示意一条路径,实际需逐 e 展开 + 资源仲裁)--
      for (int e = 0; e < MSHR_DEPTH; e++) begin
        unique case (ent[e].state)
          MSHR_IDLE:        ; // 等 alloc
          MSHR_L2P_LOOKUP:  /* TODO: o_meta_lookup; i_meta_hit→存 l2p,分流 EVICT/ALLOC */ ;
          MSHR_EVICT_PEND:  /* TODO: 读 victim 数据 → COMP */ ;
          MSHR_COMP_PEND:   /* TODO: o_comp_req;原位够→DDR_WRITE,否则 o_reloc_trig */ ;
          MSHR_ALLOC_PEND:  /* TODO: o_alloc_req;i_alloc_ack→FILL_REQ;fail→停+IRQ */ ;
          MSHR_DDR_WRITE:   /* TODO: 写压缩 Line+Header(后台) */ ;
          MSHR_FILL_REQ:    /* TODO: o_ddr_rd_req 读 Header+Line */ ;
          MSHR_FILL_DECOMP: /* TODO: o_decomp_req;CRC 错→重读/上报(禁零填充) */ ;
          MSHR_DONE:        begin ent[e].valid <= 1'b0; ent[e].state <= MSHR_IDLE; end
          default: ent[e].state <= MSHR_IDLE;
        endcase
      end
    end
  end

  // ---- 输出默认(骨架)----
  always_comb begin
    o_meta_lookup = 1'b0; o_meta_page = '0;
    o_comp_req = 1'b0; o_comp_in = '0;
    o_decomp_req = 1'b0; o_decomp_algo = ALGO_BDI; o_decomp_size='0; o_decomp_in='0; o_decomp_crc8_exp='0;
    o_alloc_req = 1'b0; o_alloc_size = '0;
    o_reloc_trig = RTRIG_NONE; o_reloc_page = '0;
    o_fill_valid = 1'b0; o_fill_index='0; o_fill_way='0; o_fill_tag='0; o_fill_data='0; o_fill_dirty=1'b0;
    o_ddr_rd_req=1'b0; o_ddr_rd_addr='0; o_ddr_wr_req=1'b0; o_ddr_wr_addr='0; o_ddr_wr_data='0;
    // TODO: 由当前被仲裁选中的 entry 驱动
  end

endmodule : mshr

`default_nettype wire
