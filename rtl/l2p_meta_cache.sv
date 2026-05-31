// ============================================================================
// l2p_meta_cache.sv — L2P Block + Page Header 共池缓存(2-way)
//   设计文档:docs/rtl/07_l2p_meta_cache.md   架构:§5.5 / §8.2 / §8.3.1
//   骨架:共池 SRAM 行为级 + 查询/命中 + miss 触发 dma;预取/ECC TODO。
// ============================================================================
`default_nettype none

module l2p_meta_cache
  import zc_pkg::*;
#(
  parameter int unsigned N_BLOCK = (META_BYTES/2) / L2P_BLOCK_BYTES, // L2P 区 Block 数
  parameter int unsigned N_HDR   = (META_BYTES/2) / 192               // Header 槽(192B 对齐)
) (
  input  wire                       clk,
  input  wire                       rst_n,

  // (F) <- mshr / reloc
  input  wire                       i_lookup,
  input  wire [LA_PAGE_W-1:0]       i_page,
  input  wire                       i_want_hdr,
  output logic                      o_hit,
  output l2p_entry_t                o_entry,
  output logic                      o_hdr_valid,
  output logic [HEADER_BYTES*8-1:0] o_hdr,

  // <-> l2p_dma
  output logic                      o_dma_req,
  output logic [LA_PAGE_W-1:0]      o_dma_page,
  output logic                      o_dma_want_hdr,
  output logic [31:0]               o_dma_ppa,
  input  wire                       i_dma_valid,
  input  wire [L2P_BLOCK_BYTES*8-1:0] i_dma_block,
  input  wire                       i_dma_hdr_valid,
  input  wire [HEADER_BYTES*8-1:0]  i_dma_hdr,

  // L2P 写(reloc/evict 更新映射)
  input  wire                       i_wr_en,
  input  wire [LA_PAGE_W-1:0]       i_wr_page,
  input  wire l2p_entry_t           i_wr_entry,

  // 配置 / 采样
  input  wire [DPA_ADDR_W-1:0]      i_cfg_l2p_base,
  output logic                      o_perf_hit,
  output logic                      o_perf_miss,
  output logic                      o_perf_hdr_miss
);

  // 一个 Block = 8 个 L2P entry(64B)
  localparam int unsigned ENTRY_PER_BLOCK = L2P_BLOCK_BYTES*8 / $bits(l2p_entry_t); // 8

  // ---- 共池存储(行为级)----
  logic [L2P_BLOCK_BYTES*8-1:0] block_mem [N_BLOCK];
  logic [LA_PAGE_W-1:0]         block_tag [N_BLOCK];   // 简化:直接存页号高位作 tag
  logic                         block_vld [N_BLOCK];
  logic [HEADER_BYTES*8-1:0]    hdr_mem   [N_HDR];
  logic [LA_PAGE_W-1:0]         hdr_tag   [N_HDR];
  logic                         hdr_vld   [N_HDR];

  // 索引拆分(2-way 略,这里直映射占位)
  wire [LA_PAGE_W-4:0] block_id  = i_page[LA_PAGE_W-1:3];      // page>>3
  wire [2:0]           entry_sel = i_page[2:0];
  // TODO: 2-way set 索引 + tag 比较;此处用 block_id 低位直映射占位
  wire [$clog2(N_BLOCK)-1:0] bidx = block_id[$clog2(N_BLOCK)-1:0];

  // ---- 查询(1 拍同步读 → 命中判定)----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      o_hit <= 1'b0; o_hdr_valid <= 1'b0;
    end else if (i_lookup) begin
      o_hit       <= block_vld[bidx] && (block_tag[bidx]==i_page[LA_PAGE_W-1:3]);
      // 选 entry(8 选 1)
      o_entry     <= block_mem[bidx][entry_sel*$bits(l2p_entry_t) +: $bits(l2p_entry_t)];
      // Header 共池(独立 tag;TODO:真 tag 比较)
      o_hdr_valid <= i_want_hdr & hdr_vld[0] & (hdr_tag[0]==i_page); // 占位
      o_hdr       <= hdr_mem[0];
    end
  end

  // ---- miss → 触发 dma ----
  always_comb begin
    o_dma_req      = i_lookup & ~(block_vld[bidx] && (block_tag[bidx]==i_page[LA_PAGE_W-1:3]));
    o_dma_page     = i_page;
    o_dma_want_hdr = i_want_hdr;
    o_dma_ppa      = o_entry.ppa_ptr; // 取 Header 用(命中 entry 后才有效;TODO 时序)
    o_perf_hit     = o_hit;
    o_perf_miss    = o_dma_req;
    o_perf_hdr_miss= i_want_hdr & ~o_hdr_valid;
  end

  // ---- dma 回填 + L2P 写 ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int b = 0; b < N_BLOCK; b++) block_vld[b] <= 1'b0;
      for (int h = 0; h < N_HDR;  h++) hdr_vld[h]   <= 1'b0;
    end else begin
      if (i_dma_valid) begin
        block_mem[bidx] <= i_dma_block;
        block_tag[bidx] <= i_page[LA_PAGE_W-1:3];
        block_vld[bidx] <= 1'b1;
        if (i_dma_hdr_valid) begin
          hdr_mem[0] <= i_dma_hdr; hdr_tag[0] <= i_page; hdr_vld[0] <= 1'b1; // 占位槽
        end
      end
      if (i_wr_en) begin
        // 更新某页 entry(命中则改 block_mem;TODO: 命中查找 + write-through 到 DDR)
        block_mem[i_wr_page[LA_PAGE_W-1:3][$clog2(N_BLOCK)-1:0]]
                 [i_wr_page[2:0]*$bits(l2p_entry_t) +: $bits(l2p_entry_t)] <= i_wr_entry;
      end
    end
  end

  // TODO: 2-way LRU、顺序预取(page,page+1 → 预取 page+3)、Meta SECDED

endmodule : l2p_meta_cache

`default_nettype wire
