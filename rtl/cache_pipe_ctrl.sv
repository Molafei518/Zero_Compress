// ============================================================================
// cache_pipe_ctrl.sv — Cache 主流水控制器(4 级:REQ/TAG/DATA/RESP)
//
//   设计文档:docs/rtl/03_cache_pipe_ctrl.md
//   架构出处:§5.3 / §5.6 / §5.7 / §8.1 / §8.5
//
//   本文件为【端口冻结 + 骨架】:流水寄存器、握手、命中判定(组合)已给出,
//   写回/MSHR 载荷/端口仲裁的完整数据通路以 TODO 标记,待实现。
// ============================================================================
`default_nettype none

module cache_pipe_ctrl
  import zc_pkg::*;
(
  input  wire                       clk,
  input  wire                       rst_n,

  // ---- (B) from addr_decode ----
  input  wire                       i_req_valid,
  output wire                       o_req_ready,
  input  wire [LA_ADDR_W-1:0]       i_addr,
  input  wire [AXI_ID_W-1:0]        i_id,
  input  wire                       i_is_write,
  input  wire req_path_e            i_path,
  input  wire [LINE_BITS-1:0]       i_wdata,
  input  wire [LINE_BYTES-1:0]      i_wstrb,
  input  wire [OFFSET_W-1:0]        i_offset,

  // ---- (C) <-> tag_ram ----
  output wire                       o_tag_rd_en,
  output wire [IDX_W-1:0]           o_tag_index,
  input  wire tag_entry_t [N_WAY-1:0] i_tag_rdata,
  input  wire [PLRU_W-1:0]          i_tag_plru,
  output logic                      o_tag_wr_en,
  output logic [WAY_W-1:0]          o_tag_wr_way,
  output logic [IDX_W-1:0]          o_tag_wr_index,
  output tag_entry_t                o_tag_wdata,
  output logic                      o_plru_we,
  output logic [IDX_W-1:0]          o_plru_wr_index,
  output logic [PLRU_W-1:0]         o_plru_upd,

  // ---- (D) <-> data_ram(4-way 并行读 + 单路写)----
  output wire                       o_data_rd_en,
  output wire [IDX_W-1:0]           o_data_index,
  input  wire [N_WAY-1:0][LINE_BITS-1:0] i_data_rdata,
  output logic                      o_data_wr_en,
  output logic [WAY_W-1:0]          o_data_wr_way,
  output logic [IDX_W-1:0]          o_data_wr_index,
  output logic [LINE_BITS-1:0]      o_data_wdata,
  output logic [LINE_BYTES-1:0]     o_data_wstrb,

  // ---- (E) <-> mshr ----
  output logic                      o_mshr_alloc,
  output logic [LA_ADDR_W-1:0]      o_mshr_addr,
  output logic                      o_mshr_is_write,
  output logic [WAY_W-1:0]          o_mshr_victim_way,
  output logic                      o_mshr_victim_valid,
  output logic                      o_mshr_victim_dirty,
  output logic [TAG_W-1:0]          o_mshr_victim_tag,
  output logic [LINE_BITS-1:0]      o_mshr_victim_data,  // 脏行 evict 用
  input  wire                       i_mshr_full,
  input  wire                       i_mshr_merge,
  input  wire                       i_block_valid,
  input  wire [LA_PAGE_W-1:0]       i_block_page,
  // fill 回填(MSHR -> pipe)
  input  wire                       i_fill_valid,
  input  wire [IDX_W-1:0]           i_fill_index,
  input  wire [WAY_W-1:0]           i_fill_way,
  input  wire [TAG_W-1:0]           i_fill_tag,
  input  wire [LINE_BITS-1:0]       i_fill_data,
  input  wire                       i_fill_dirty,
  output logic                      o_fill_ready,

  // ---- (I) -> resp_merge ----
  output logic                      o_resp_valid,
  output logic [AXI_ID_W-1:0]       o_resp_id,
  output logic                      o_resp_is_write,
  output logic [LINE_BITS-1:0]      o_resp_data,
  output logic [OFFSET_W-1:0]       o_resp_offset,
  output logic [1:0]                o_resp_code,
  input  wire                       i_resp_ready,

  // ---- 配置 / 性能采样 ----
  input  wire                       i_cache_en,
  output logic                      o_perf_hit,
  output logic                      o_perf_miss,
  output logic                      o_perf_wr_hit,
  output logic                      o_perf_wr_miss
);

  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;

  // ==========================================================================
  // 流水寄存器 payload
  // ==========================================================================
  typedef struct packed {
    logic                 valid;
    logic [LA_ADDR_W-1:0] addr;
    logic [AXI_ID_W-1:0]  id;
    logic                 is_write;
    req_path_e            path;
    logic [LINE_BITS-1:0] wdata;
    logic [LINE_BYTES-1:0] wstrb;
    logic [OFFSET_W-1:0]  offset;
  } pipe_payload_t;

  pipe_payload_t s1, s2, s3; // S1=REQ锁存, S2=TAG, S3=DATA

  // S2 命中判定结果(寄到 S3)
  logic                 s2_hit;
  logic [WAY_W-1:0]     s2_hit_way;
  logic                 s3_hit_q;
  logic [WAY_W-1:0]     s3_hit_way_q;
  logic [LINE_BITS-1:0] s3_line_q;   // S2 选出的命中数据(way-mux)
  logic [PLRU_W-1:0]    s3_plru_q;   // s3 对应 set 的 pLRU(S2 读出后捕获)
  tag_entry_t [N_WAY-1:0] s3_tag_q;  // s3 set 的 4 路 tag(victim 判定用)
  logic [N_WAY-1:0][LINE_BITS-1:0] s3_data_q; // s3 set 的 4 路数据(victim evict 用)

  // ==========================================================================
  // tree-pLRU(4-way,3 bit):bit0=顶层(0→替左{0,1} / 1→替右{2,3})
  //   bit1=左半(0→way0 /1→way1);bit2=右半(0→way2 /1→way3)
  // ==========================================================================
  function automatic logic [WAY_W-1:0] plru_victim(input logic [PLRU_W-1:0] p);
    return p[0] ? (p[2] ? 2'd3 : 2'd2) : (p[1] ? 2'd1 : 2'd0);
  endfunction
  function automatic logic [PLRU_W-1:0] plru_update(input logic [PLRU_W-1:0] p,
                                                    input logic [WAY_W-1:0] way);
    logic [PLRU_W-1:0] n; n = p;
    if (way[1] == 1'b0) begin n[0] = 1'b1; n[1] = ~way[0]; end // 访问 0/1 → 替右半
    else                begin n[0] = 1'b0; n[2] = ~way[0]; end // 访问 2/3 → 替左半
    return n;
  endfunction

  // ==========================================================================
  // stall 链(整级冻结)—— TODO: 补全 §5 的全部冒险
  // ==========================================================================
  wire stall_mshr_full = i_mshr_full;                       // 简化:需 alloc 时才算
  wire la_page_match   = (la_page_num(s2.addr) == i_block_page);
  wire stall_reloc     = i_block_valid && la_page_match;
  wire stall_resp      = o_resp_valid && ~i_resp_ready;
  wire pipe_stall      = stall_mshr_full | stall_reloc | stall_resp; // TODO: 同set/同line/端口争用

  assign o_req_ready = ~pipe_stall;

  // ==========================================================================
  // S1 REQ:握手 + 发 RAM 读(NORMAL 路径)
  // ==========================================================================
  wire s1_fire = i_req_valid & o_req_ready;
  wire normal_lookup = i_cache_en & (i_path == PATH_NORMAL);

  assign o_tag_rd_en  = s1_fire & normal_lookup;
  assign o_data_rd_en = s1_fire & normal_lookup;
  assign o_tag_index  = cache_index(i_addr);
  assign o_data_index = cache_index(i_addr);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) s1.valid <= 1'b0;
    else if (!pipe_stall) begin
      s1.valid    <= s1_fire;
      s1.addr     <= i_addr;
      s1.id       <= i_id;
      s1.is_write <= i_is_write;
      s1.path     <= i_path;
      s1.wdata    <= i_wdata;
      s1.wstrb    <= i_wstrb;
      s1.offset   <= i_offset;
    end
  end

  // S1 -> S2
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) s2.valid <= 1'b0;
    else if (!pipe_stall) s2 <= s1;
  end

  // ==========================================================================
  // S2 TAG:4-way 比较 + way one-hot + pLRU 计算(组合,关键路径)
  // ==========================================================================
  logic [N_WAY-1:0] way_hit;
  always_comb begin
    for (int w = 0; w < N_WAY; w++)
      way_hit[w] = i_tag_rdata[w].valid &&
                   (i_tag_rdata[w].tag == cache_tag(s2.addr));
  end

  always_comb begin
    s2_hit     = |way_hit;
    s2_hit_way = '0;
    for (int w = 0; w < N_WAY; w++)
      if (way_hit[w]) s2_hit_way = w[WAY_W-1:0];
  end

  // way-mux:命中数据(S2 数据已并行读出)
  wire [LINE_BITS-1:0] s2_hit_line = i_data_rdata[s2_hit_way];

  // S2 -> S3(捕获命中/数据/pLRU/tag)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) s3.valid <= 1'b0;
    else if (!pipe_stall) begin
      s3           <= s2;
      s3_hit_q     <= s2_hit;
      s3_hit_way_q <= s2_hit_way;
      s3_line_q    <= s2_hit_line;
      s3_plru_q    <= i_tag_plru;   // s2 读出的该 set pLRU
      s3_tag_q     <= i_tag_rdata;  // s2 读出的 4 路 tag(victim 判定)
      s3_data_q    <= i_data_rdata; // s2 读出的 4 路数据(victim evict)
    end
  end

  // ==========================================================================
  // S3 DATA:命中决策(§4)+ RAM 写端口仲裁(fill 优先于 write-hit,§5)
  // ==========================================================================
  wire [WAY_W-1:0] s3_victim_way = plru_victim(s3_plru_q);

  always_comb begin
    // 默认
    o_data_wr_en       = 1'b0;
    o_data_wr_way      = '0;
    o_data_wr_index    = cache_index(s3.addr);
    o_data_wdata       = s3.wdata;
    o_data_wstrb       = s3.wstrb;
    o_tag_wr_en        = 1'b0;
    o_tag_wr_way       = '0;
    o_tag_wr_index     = cache_index(s3.addr);
    o_tag_wdata        = '0;
    o_plru_we          = 1'b0;
    o_plru_wr_index    = cache_index(s3.addr);
    o_plru_upd         = '0;
    o_mshr_alloc       = 1'b0;
    o_mshr_addr        = s3.addr;
    o_mshr_is_write    = s3.is_write;
    o_mshr_victim_way  = s3_victim_way;
    o_mshr_victim_valid= s3_tag_q[s3_victim_way].valid;
    o_mshr_victim_dirty= s3_tag_q[s3_victim_way].valid & s3_tag_q[s3_victim_way].dirty;
    o_mshr_victim_tag  = s3_tag_q[s3_victim_way].tag;
    o_mshr_victim_data = s3_data_q[s3_victim_way];
    o_fill_ready       = 1'b0;

    if (i_fill_valid) begin
      // ---- Fill 回填(最高优先,占用 RAM 写端口)----
      o_fill_ready    = 1'b1;
      o_data_wr_en    = 1'b1;
      o_data_wr_way   = i_fill_way;
      o_data_wr_index = i_fill_index;
      o_data_wdata    = i_fill_data;
      o_data_wstrb    = '1;                       // 整 line 写
      o_tag_wr_en     = 1'b1;
      o_tag_wr_way    = i_fill_way;
      o_tag_wr_index  = i_fill_index;
      o_tag_wdata     = '{tag:i_fill_tag, dirty:i_fill_dirty, valid:1'b1};
    end else if (s3.valid && s3_hit_q && s3.is_write) begin
      // ---- Write Hit:写 data_ram + 置 dirty + pLRU 更新 ----
      o_data_wr_en  = 1'b1;
      o_data_wr_way = s3_hit_way_q;
      o_tag_wr_en   = 1'b1;
      o_tag_wr_way  = s3_hit_way_q;
      o_tag_wdata   = '{tag:cache_tag(s3.addr), dirty:1'b1, valid:1'b1};
      o_plru_we     = 1'b1;
      o_plru_upd    = plru_update(s3_plru_q, s3_hit_way_q);
    end else if (s3.valid && s3_hit_q && !s3.is_write) begin
      // ---- Read Hit:仅更新 pLRU(数据在 S4 返回)----
      o_plru_we  = 1'b1;
      o_plru_upd = plru_update(s3_plru_q, s3_hit_way_q);
    end else if (s3.valid && !s3_hit_q && s3.path != PATH_BYPASS) begin
      // ---- Miss:申请 MSHR(victim 载荷已在默认段给出)----
      o_mshr_alloc = ~i_mshr_merge;
      // 选定的 victim 即将被 fill → 该 way 将成为 MRU。在此更新 pLRU,
      // 否则连续 miss 会反复选同一 victim(fill 路径不读改 pLRU)。
      o_plru_we  = 1'b1;
      o_plru_upd = plru_update(s3_plru_q, s3_victim_way);
    end
  end

  // ==========================================================================
  // S4 RESP:命中返回 —— 读命中带数据(4 cycle),写命中给写响应(B)
  // ==========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      o_resp_valid <= 1'b0;
    end else if (!stall_resp) begin
      o_resp_valid    <= s3.valid && s3_hit_q;      // 读命中 + 写命中都回执
      o_resp_id       <= s3.id;
      o_resp_is_write <= s3.is_write;
      o_resp_data     <= s3_line_q;
      o_resp_offset   <= s3.offset;
      o_resp_code     <= RESP_OKAY;
    end
  end

  // ==========================================================================
  // 性能采样脉冲
  // ==========================================================================
  always_comb begin
    o_perf_hit    = s2.valid &  s2_hit & ~s2.is_write;
    o_perf_miss   = s2.valid & ~s2_hit & ~s2.is_write;
    o_perf_wr_hit = s2.valid &  s2_hit &  s2.is_write;
    o_perf_wr_miss= s2.valid & ~s2_hit &  s2.is_write;
  end

endmodule : cache_pipe_ctrl

`default_nettype wire
