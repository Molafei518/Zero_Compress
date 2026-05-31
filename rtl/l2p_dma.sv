// ============================================================================
// l2p_dma.sv — L2P Block DMA(64B block 读/写 DDR L2P 表)
//   设计文档:docs/rtl/08_l2p_dma.md   架构:§3.2.4 / §8.3
//   职责:地址计算(block_addr = L2P_BASE + blk_idx*64)+ block 粒度 DDR 读写转发。
//   (AXI beat 级拆分由下游/req_buffer 处理;本模块按 block 抽象。)
//   端口较骨架修订:加 block 写路径;读改 block 粒度(便于 write-through 缓存)。
// ============================================================================
`default_nettype none

module l2p_dma
  import zc_pkg::*;
#(
  parameter int unsigned BLK_IDX_W = LA_PAGE_W-3
)(
  input  wire                          clk,
  input  wire                          rst_n,

  // <-> l2p_meta_cache
  input  wire                          i_rd_req,
  input  wire [BLK_IDX_W-1:0]          i_rd_blk,
  output logic                         o_rd_valid,
  output logic [L2P_BLOCK_BYTES*8-1:0] o_rd_block,
  input  wire                          i_wr_req,
  input  wire [BLK_IDX_W-1:0]          i_wr_blk,
  input  wire [L2P_BLOCK_BYTES*8-1:0]  i_wr_block,
  output logic                         o_wr_done,
  output logic                         o_busy,

  // 配置
  input  wire [DPA_ADDR_W-1:0]         i_cfg_l2p_base,

  // 下游 DDR(block 粒度)
  output logic                         o_ddr_rd_req,
  output logic [DPA_ADDR_W-1:0]        o_ddr_rd_addr,
  input  wire                          i_ddr_rd_valid,
  input  wire [L2P_BLOCK_BYTES*8-1:0]  i_ddr_rd_block,
  output logic                         o_ddr_wr_req,
  output logic [DPA_ADDR_W-1:0]        o_ddr_wr_addr,
  output logic [L2P_BLOCK_BYTES*8-1:0] o_ddr_wr_block,
  input  wire                          i_ddr_wr_done
);
  typedef enum logic [1:0] { D_IDLE, D_RD, D_WR } st_e;
  st_e state;
  logic [BLK_IDX_W-1:0]         blk_q;
  logic [L2P_BLOCK_BYTES*8-1:0] wblk_q;

  assign o_busy = (state != D_IDLE);
  // block 字节地址 = base + blk_idx*64
  wire [DPA_ADDR_W-1:0] blk_addr = i_cfg_l2p_base +
       {{(DPA_ADDR_W-BLK_IDX_W-6){1'b0}}, blk_q, 6'b0};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin state<=D_IDLE; o_rd_valid<=0; o_wr_done<=0; end
    else begin
      o_rd_valid<=0; o_wr_done<=0;
      unique case (state)
        D_IDLE: begin
          if (i_rd_req)      begin blk_q<=i_rd_blk; state<=D_RD; end
          else if (i_wr_req) begin blk_q<=i_wr_blk; wblk_q<=i_wr_block; state<=D_WR; end
        end
        D_RD: if (i_ddr_rd_valid) begin o_rd_block<=i_ddr_rd_block; o_rd_valid<=1; state<=D_IDLE; end
        D_WR: if (i_ddr_wr_done)  begin o_wr_done<=1; state<=D_IDLE; end
        default: state<=D_IDLE;
      endcase
    end
  end

  always_comb begin
    o_ddr_rd_req   = (state==D_RD);
    o_ddr_rd_addr  = blk_addr;
    o_ddr_wr_req   = (state==D_WR);
    o_ddr_wr_addr  = blk_addr;
    o_ddr_wr_block = wblk_q;
  end
endmodule : l2p_dma

`default_nettype wire
