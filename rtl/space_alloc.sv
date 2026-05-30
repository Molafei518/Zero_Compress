// ============================================================================
// space_alloc.sv — PPA Buddy(7级)+ Slab 分配器
//   设计文档:docs/rtl/20_space_alloc.md   架构:§7.1
//   骨架:level 译码 + Allocator Cache 框架;buddy split/merge 与 DDR bitmap TODO。
// ============================================================================
`default_nettype none

module space_alloc
  import zc_pkg::*;
(
  input  wire                   clk,
  input  wire                   rst_n,

  input  wire                   i_alloc_req,
  input  wire [12:0]            i_alloc_size,
  output logic                  o_alloc_ack,
  output logic                  o_alloc_fail,
  output logic [31:0]           o_alloc_ppa,

  input  wire                   i_free_req,
  input  wire [31:0]            i_free_ppa,
  input  wire [12:0]            i_free_size,

  output logic [6:0]            o_used_pct,
  input  wire [DPA_ADDR_W-1:0]  i_cfg_meta_base,

  // free_list (DDR bitmap) 抽象口
  output logic                  o_fl_rd_req,
  output logic [DPA_ADDR_W-1:0] o_fl_addr,
  input  wire                   i_fl_valid,
  input  wire [AXI_DATA_W-1:0]  i_fl_data,
  output logic                  o_fl_wr_req,
  output logic [AXI_DATA_W-1:0] o_fl_wdata
);
  localparam int N_LVL = 7; // 64..4096

  // size → buddy level(ceil)
  function automatic logic [2:0] level_of(input logic [12:0] sz);
    if (sz <= 13'd64)   return 3'd0;
    if (sz <= 13'd128)  return 3'd1;
    if (sz <= 13'd256)  return 3'd2;
    if (sz <= 13'd512)  return 3'd3;
    if (sz <= 13'd1024) return 3'd4;
    if (sz <= 13'd2048) return 3'd5;
    return 3'd6; // 4096(>4096 退化由调用方按 UNCOMP_SLOT 处理)
  endfunction

  // 片上 Allocator Cache:每级一个浅 free-index 栈(深度 256;此处占位计数)
  logic [8:0] cache_cnt [N_LVL];   // 每级缓存的 free 块数
  // logic [31:0] cache_idx [N_LVL][256];  // 实际 free 块索引(TODO)

  wire [2:0] lvl = level_of(i_alloc_size);

  // ---- 分配(骨架)----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      o_alloc_ack <= 1'b0; o_alloc_fail <= 1'b0; o_alloc_ppa <= '0;
      for (int l = 0; l < N_LVL; l++) cache_cnt[l] <= '0;
    end else begin
      o_alloc_ack  <= 1'b0;
      o_alloc_fail <= 1'b0;
      if (i_alloc_req) begin
        if (cache_cnt[lvl] != 0) begin
          // 命中 Allocator Cache:弹出一个(1 cyc)
          cache_cnt[lvl] <= cache_cnt[lvl] - 1'b1;
          o_alloc_ack    <= 1'b1;
          o_alloc_ppa    <= '0; // TODO: 弹出 cache_idx[lvl]
        end else begin
          // miss:TODO —— buddy split / DDR bitmap 取段;暂置 fail 占位
          o_alloc_fail <= 1'b1;
        end
      end
      // TODO: free + buddy 合并 + 回填 cache;o_used_pct 统计
    end
  end

  always_comb begin
    o_used_pct  = 7'd0;  // TODO: 已分配/总容量
    o_fl_rd_req = 1'b0; o_fl_addr = '0; o_fl_wr_req = 1'b0; o_fl_wdata = '0;
  end
endmodule : space_alloc

`default_nettype wire
