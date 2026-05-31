// ============================================================================
// l2p_meta_cache.sv — L2P Block 片上缓存(写穿直映射)
//   设计文档:docs/rtl/07_l2p_meta_cache.md   架构:§5.5 / §8.2 / §8.3.1
//   一个 Block = 8 个 L2P entry(64B)。lookup:命中即返回;miss → l2p_dma 取块回填。
//   写:更新块内 entry + write-through 到 DDR(写 miss 先 fetch 块再改)。
//   接口对齐 miss 引擎(rd/valid/entry + wr/done),可作 L2P 模型 drop-in。
//   简化(留后续,§5.5):2-way LRU / 顺序预取 / Page Header 共池 / Meta SECDED。
//   端口较骨架修订:lookup 改 rd/o_valid/o_entry 多周期握手(原 registered hit 有竞争)。
// ============================================================================
`default_nettype none

module l2p_meta_cache
  import zc_pkg::*;
#(
  parameter int unsigned N_BLOCK = 256   // L2P block 缓存条数(默认 §5.5 的 256)
)(
  input  wire                   clk,
  input  wire                   rst_n,

  // L2P 读:rd 脉冲 → 多周期后 o_rd_valid + o_rd_entry
  input  wire                   i_rd,
  input  wire [LA_PAGE_W-1:0]   i_rd_page,
  output logic                  o_rd_valid,
  output l2p_entry_t            o_rd_entry,

  // L2P 写(更新映射):wr 脉冲 → o_wr_done
  input  wire                   i_wr,
  input  wire [LA_PAGE_W-1:0]   i_wr_page,
  input  wire l2p_entry_t       i_wr_entry,
  output logic                  o_wr_done,

  // <-> l2p_dma
  output logic                  o_dma_rd_req,
  output logic [LA_PAGE_W-4:0]  o_dma_rd_blk,
  input  wire                   i_dma_rd_valid,
  input  wire [L2P_BLOCK_BYTES*8-1:0] i_dma_rd_block,
  output logic                  o_dma_wr_req,
  output logic [LA_PAGE_W-4:0]  o_dma_wr_blk,
  output logic [L2P_BLOCK_BYTES*8-1:0] o_dma_wr_block,
  input  wire                   i_dma_wr_done,

  output logic                  o_perf_hit,
  output logic                  o_perf_miss
);
  localparam int unsigned EW    = $bits(l2p_entry_t);          // 64
  localparam int unsigned IDXW  = $clog2(N_BLOCK);
  localparam int unsigned BIDW  = LA_PAGE_W-3;                 // block_id 位宽
  localparam int unsigned TAGW  = BIDW - IDXW;

  logic [L2P_BLOCK_BYTES*8-1:0] cmem [N_BLOCK];
  logic [TAGW-1:0]              ctag [N_BLOCK];
  logic                         cvld [N_BLOCK];

  logic [LA_PAGE_W-1:0] page_q; logic [EW-1:0] went_q;
  wire [BIDW-1:0] bid  = page_q[LA_PAGE_W-1:3];
  wire [IDXW-1:0] cidx = bid[IDXW-1:0];
  wire [TAGW-1:0] ptag = bid[BIDW-1:IDXW];
  wire [2:0]      esel = page_q[2:0];
  wire            hit  = cvld[cidx] && (ctag[cidx]==ptag);

  // entry 替换掩码(把 block 中 esel 位置的 64bit 换成 went_q)
  function automatic logic [L2P_BLOCK_BYTES*8-1:0] merge_entry(
      input logic [L2P_BLOCK_BYTES*8-1:0] blk, input logic [2:0] sel, input logic [EW-1:0] e);
    logic [L2P_BLOCK_BYTES*8-1:0] mask, ins;
    mask = {{(L2P_BLOCK_BYTES*8-EW){1'b0}}, {EW{1'b1}}} << (sel*EW);
    ins  = {{(L2P_BLOCK_BYTES*8-EW){1'b0}}, e}          << (sel*EW);
    return (blk & ~mask) | ins;
  endfunction

  typedef enum logic [2:0] { C_IDLE, C_RD_CHK, C_RD_MISS, C_WR_CHK, C_WR_FETCH, C_WR_WT } st_e;
  st_e state;
  logic [L2P_BLOCK_BYTES*8-1:0] wblk;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state<=C_IDLE; o_rd_valid<=0; o_wr_done<=0;
      for (int b=0;b<N_BLOCK;b++) cvld[b]<=1'b0;
    end else begin
      o_rd_valid<=0; o_wr_done<=0;
      unique case (state)
        C_IDLE: begin
          if (i_rd)      begin page_q<=i_rd_page;  state<=C_RD_CHK; end
          else if (i_wr) begin page_q<=i_wr_page; went_q<=i_wr_entry; state<=C_WR_CHK; end
        end
        C_RD_CHK: begin
          if (hit) begin o_rd_entry<=cmem[cidx][esel*EW +: EW]; o_rd_valid<=1; state<=C_IDLE; end
          else state<=C_RD_MISS;
        end
        C_RD_MISS: if (i_dma_rd_valid) begin
          cmem[cidx]<=i_dma_rd_block; ctag[cidx]<=ptag; cvld[cidx]<=1'b1;
          o_rd_entry<=i_dma_rd_block[esel*EW +: EW]; o_rd_valid<=1; state<=C_IDLE;
        end
        C_WR_CHK: begin
          if (hit) begin
            wblk<=merge_entry(cmem[cidx], esel, went_q);
            cmem[cidx]<=merge_entry(cmem[cidx], esel, went_q);
            state<=C_WR_WT;
          end else state<=C_WR_FETCH;
        end
        C_WR_FETCH: if (i_dma_rd_valid) begin
          cmem[cidx]<=merge_entry(i_dma_rd_block, esel, went_q);
          ctag[cidx]<=ptag; cvld[cidx]<=1'b1;
          wblk<=merge_entry(i_dma_rd_block, esel, went_q);
          state<=C_WR_WT;
        end
        C_WR_WT: if (i_dma_wr_done) begin o_wr_done<=1; state<=C_IDLE; end
        default: state<=C_IDLE;
      endcase
    end
  end

  always_comb begin
    o_dma_rd_req = (state==C_RD_MISS) || (state==C_WR_FETCH);
    o_dma_rd_blk = bid;
    o_dma_wr_req = (state==C_WR_WT);
    o_dma_wr_blk = bid;
    o_dma_wr_block = wblk;
    o_perf_hit  = (state==C_RD_CHK) & hit;
    o_perf_miss = (state==C_RD_CHK) & ~hit;
  end
endmodule : l2p_meta_cache

`default_nettype wire
