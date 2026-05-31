// ============================================================================
// space_alloc.sv — PPA Buddy 分配器(7 级:64B..4KB)
//   设计文档:docs/rtl/20_space_alloc.md   架构:§7.1
//   实现:片上每级 free-block 栈;alloc 命中级则弹出,否则从最近的高级别块逐级拆分;
//         free 归还到对应级栈。**不做 buddy 合并**(合并/碎片整理归 Defrag GC,§7.4)。
//   PPA 以 64B 为单位的块偏移表示;o_alloc_ppa = 字节偏移(块偏移<<6)。
//   REGION_BLK64 = PPA 区域的 64B 块总数(默认 64 = 一个 4KB 顶块,便于验证拆分/耗尽)。
// ============================================================================
`default_nettype none

module space_alloc
  import zc_pkg::*;
#(
  parameter int REGION_BLK64 = 64           // 64B 块总数(=区域字节/64)
)(
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

  // free_list (DDR bitmap) 抽象口(片上栈溢出时 spill;本版未用)
  output logic                  o_fl_rd_req,
  output logic [DPA_ADDR_W-1:0] o_fl_addr,
  input  wire                   i_fl_valid,
  input  wire [AXI_DATA_W-1:0]  i_fl_data,
  output logic                  o_fl_wr_req,
  output logic [AXI_DATA_W-1:0] o_fl_wdata
);
  localparam int N_LVL = 7;                       // 64..4096
  localparam int OFFW  = $clog2(REGION_BLK64);    // 块偏移位宽
  localparam int CNTW  = $clog2(REGION_BLK64+1);
  localparam int N_TOP = REGION_BLK64 >> 6;       // 顶级(4KB)块数

  // size → buddy level(ceil)
  function automatic logic [2:0] level_of(input logic [12:0] sz);
    if (sz <= 13'd64)   return 3'd0;
    if (sz <= 13'd128)  return 3'd1;
    if (sz <= 13'd256)  return 3'd2;
    if (sz <= 13'd512)  return 3'd3;
    if (sz <= 13'd1024) return 3'd4;
    if (sz <= 13'd2048) return 3'd5;
    return 3'd6;
  endfunction

  // 每级 free-block 栈
  logic [OFFW-1:0] fl  [N_LVL][REGION_BLK64];
  logic [CNTW-1:0] cnt [N_LVL];
  logic [CNTW:0]   used_blk;                        // 已分配 64B 块数

  typedef enum logic [1:0] { A_IDLE, A_SCAN, A_SPLIT } st_e;
  st_e state;
  logic [2:0]      req_lvl;
  logic [2:0]      cur_lvl;
  logic [OFFW-1:0] cur_base;

  // 在 [req_lvl..6] 找最小的非空级
  logic [2:0] scan_h; logic scan_found;
  always_comb begin
    scan_found = 1'b0; scan_h = req_lvl;
    for (int h = N_LVL-1; h >= 0; h--)
      if ((h >= req_lvl) && (cnt[h] != 0)) begin scan_h = h[2:0]; scan_found = 1'b1; end
  end

  integer i;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= A_IDLE; o_alloc_ack <= 1'b0; o_alloc_fail <= 1'b0; o_alloc_ppa <= '0;
      used_blk <= '0;
      for (int l = 0; l < N_LVL; l++) cnt[l] <= '0;
      for (i = 0; i < N_TOP; i++) fl[6][i] <= OFFW'(i << 6);   // 顶级块偏移 i*64
      cnt[6] <= CNTW'(N_TOP);
    end else begin
      o_alloc_ack  <= 1'b0;
      o_alloc_fail <= 1'b0;
      unique case (state)
        A_IDLE: begin
          if (i_alloc_req) begin
            req_lvl <= level_of(i_alloc_size);
            state   <= A_SCAN;
          end else if (i_free_req) begin
            // 归还到对应级栈(无合并)
            logic [2:0] fl_lvl; fl_lvl = level_of(i_free_size);
            fl[fl_lvl][cnt[fl_lvl]] <= OFFW'(i_free_ppa >> 6);
            cnt[fl_lvl] <= cnt[fl_lvl] + 1'b1;
            if (used_blk >= (1 << fl_lvl)) used_blk <= used_blk - (1 << fl_lvl);
          end
        end
        A_SCAN: begin
          if (!scan_found) begin
            o_alloc_fail <= 1'b1; state <= A_IDLE;          // 耗尽
          end else if (scan_h == req_lvl) begin
            // 命中:弹出
            o_alloc_ppa  <= {fl[req_lvl][cnt[req_lvl]-1], 6'b0};
            cnt[req_lvl] <= cnt[req_lvl] - 1'b1;
            used_blk     <= used_blk + (1 << req_lvl);
            o_alloc_ack  <= 1'b1; state <= A_IDLE;
          end else begin
            // 取高级别块,准备逐级拆分
            cur_base     <= fl[scan_h][cnt[scan_h]-1];
            cnt[scan_h]  <= cnt[scan_h] - 1'b1;
            cur_lvl      <= scan_h;
            state        <= A_SPLIT;
          end
        end
        A_SPLIT: begin
          // 把 cur_lvl 块拆成两个 (cur_lvl-1) 块:保留下半 cur_base,上半入栈
          fl[cur_lvl-1][cnt[cur_lvl-1]] <= cur_base + OFFW'(1 << (cur_lvl-1));
          cnt[cur_lvl-1] <= cnt[cur_lvl-1] + 1'b1;
          cur_lvl <= cur_lvl - 1'b1;
          if ((cur_lvl-1) == req_lvl) begin
            o_alloc_ppa <= {cur_base, 6'b0};
            used_blk    <= used_blk + (1 << req_lvl);
            o_alloc_ack <= 1'b1; state <= A_IDLE;
          end
        end
        default: state <= A_IDLE;
      endcase
    end
  end

  always_comb begin
    o_used_pct  = 7'((used_blk * 100) / REGION_BLK64);
    o_fl_rd_req = 1'b0; o_fl_addr = '0; o_fl_wr_req = 1'b0; o_fl_wdata = '0;
  end
endmodule : space_alloc

`default_nettype wire
