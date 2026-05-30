// ============================================================================
// l2p_dma.sv — 元数据 DMA(取 L2P Block + Page Header,回填 Meta Cache)
//   设计文档:docs/rtl/08_l2p_dma.md   架构:§3.2.4 / §8.3 / §8.3.2
//   骨架:地址计算 + FSM 框架;下游 AXI 读事务 TODO。
// ============================================================================
`default_nettype none

module l2p_dma
  import zc_pkg::*;
(
  input  wire                        clk,
  input  wire                        rst_n,

  // <- l2p_meta_cache
  input  wire                        i_req,
  input  wire [LA_PAGE_W-1:0]        i_page,
  input  wire                        i_want_hdr,
  input  wire [31:0]                 i_ppa_ptr,
  output logic                       o_busy,

  // -> l2p_meta_cache(回填)
  output logic                       o_valid,
  output logic [L2P_BLOCK_BYTES*8-1:0] o_block,
  output logic                       o_hdr_valid,
  output logic [HEADER_BYTES*8-1:0]  o_hdr,

  // 配置
  input  wire [DPA_ADDR_W-1:0]       i_cfg_l2p_base,

  // 下游 DDR 读(经 m_axi,ID class = IDC_META)
  output logic                       o_rd_req,
  output logic [DPA_ADDR_W-1:0]      o_rd_addr,
  output logic [7:0]                 o_rd_len,
  input  wire                        i_rd_valid,
  input  wire [AXI_DATA_W-1:0]       i_rd_data,
  input  wire                        i_rd_last
);

  // ---- 地址计算 ----
  // L2P entry 字节地址 = base + page*8;Block 向 64B 对齐
  wire [DPA_ADDR_W-1:0] l2p_byte    = i_cfg_l2p_base + ({{(DPA_ADDR_W-LA_PAGE_W-3){1'b0}}, i_page, 3'b000});
  wire [DPA_ADDR_W-1:0] block_addr  = l2p_byte & ~(DPA_ADDR_W'(L2P_BLOCK_BYTES-1));
  wire [DPA_ADDR_W-1:0] hdr_addr    = ppa_to_byte(i_ppa_ptr);

  // ---- FSM ----
  typedef enum logic [2:0] {
    D_IDLE, D_RD_L2P, D_RD_HDR, D_FILL
  } dma_state_e;
  dma_state_e state, state_n;

  assign o_busy = (state != D_IDLE);

  always_comb begin
    state_n  = state;
    o_rd_req = 1'b0;
    o_rd_addr= '0;
    o_rd_len = '0;
    unique case (state)
      D_IDLE:   if (i_req) state_n = D_RD_L2P;
      D_RD_L2P: begin
        o_rd_req  = 1'b1;
        o_rd_addr = block_addr;
        o_rd_len  = 8'd1; // 64B / 32B-beat = 2 beat → len=1
        if (i_rd_valid && i_rd_last)
          state_n = i_want_hdr ? D_RD_HDR : D_FILL;
      end
      D_RD_HDR: begin
        o_rd_req  = 1'b1;
        o_rd_addr = hdr_addr;
        o_rd_len  = 8'd5; // 176B → 6 beat(向上取整)
        if (i_rd_valid && i_rd_last) state_n = D_FILL;
      end
      D_FILL:   state_n = D_IDLE;
      default:  state_n = D_IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= D_IDLE; o_valid <= 1'b0; o_hdr_valid <= 1'b0;
    end else begin
      state   <= state_n;
      o_valid <= (state_n == D_FILL);
      // TODO: 把 i_rd_data 各 beat 拼进 o_block / o_hdr;置 o_hdr_valid
      // TODO: §8.3.2 优化 —— 若 i_ppa_ptr 已知,L2P 与 Header 两笔并行发
    end
  end

endmodule : l2p_dma

`default_nettype wire
