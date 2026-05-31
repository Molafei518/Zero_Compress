// ============================================================================
// tb_sub_cache.sv — Cache 子系统 TB:cache_pipe_ctrl + tag_ram + data_ram
//   验证命中路径(不含 miss/MSHR/DDR 链):
//     1) fill 预热 4 路 → read-hit 取回正确数据(way-mux + tag 比较)
//     2) write-hit → 读回更新数据(写通路 + dirty)
//     3) pLRU:读某路后,miss 的 victim != 最近访问路(tree-pLRU 必要条件)
//   全 IP 端到端(req_buffer/addr_decode/mshr/resp_merge + AXI)留后续批次。
// ============================================================================
`default_nettype none
module tb_sub_cache;
  import zc_pkg::*;

  logic clk = 0, rst_n = 0;
  always #0.625ns clk = ~clk;

  // ---- (B) 请求 ----
  logic                 req_valid; logic req_ready;
  logic [LA_ADDR_W-1:0] req_addr;  logic [AXI_ID_W-1:0] req_id;
  logic                 req_wr;    req_path_e req_path;
  logic [LINE_BITS-1:0] req_wdata; logic [LINE_BYTES-1:0] req_wstrb;
  logic [OFFSET_W-1:0]  req_off;
  // ---- (E) fill ----
  logic                 fill_valid; logic fill_ready;
  logic [IDX_W-1:0]     fill_index; logic [WAY_W-1:0] fill_way;
  logic [TAG_W-1:0]     fill_tag;   logic [LINE_BITS-1:0] fill_data; logic fill_dirty;
  // ---- (I) resp ----
  logic                 resp_valid; logic [AXI_ID_W-1:0] resp_id;
  logic                 resp_isw;   logic [LINE_BITS-1:0] resp_data;
  logic [OFFSET_W-1:0]  resp_off;   logic [1:0] resp_code;
  // ---- mshr 接口(victim 观测)----
  logic                 mshr_alloc; logic [WAY_W-1:0] victim_way;
  logic                 victim_valid, victim_dirty; logic [TAG_W-1:0] victim_tag;

  // ---- (C) pipe<->tag_ram ----
  logic                 t_rd_en; logic [IDX_W-1:0] t_index;
  tag_entry_t [N_WAY-1:0] t_rdata; logic [PLRU_W-1:0] t_plru;
  logic                 t_wr_en; logic [WAY_W-1:0] t_wr_way; logic [IDX_W-1:0] t_wr_index;
  tag_entry_t           t_wdata;
  logic                 p_we; logic [IDX_W-1:0] p_wr_index; logic [PLRU_W-1:0] p_upd;
  // ---- (D) pipe<->data_ram ----
  logic                 d_rd_en; logic [IDX_W-1:0] d_index;
  logic [N_WAY-1:0][LINE_BITS-1:0] d_rdata;
  logic                 d_wr_en; logic [WAY_W-1:0] d_wr_way; logic [IDX_W-1:0] d_wr_index;
  logic [LINE_BITS-1:0] d_wdata; logic [LINE_BYTES-1:0] d_wstrb;

  cache_pipe_ctrl u_pipe (
    .clk, .rst_n,
    .i_req_valid(req_valid), .o_req_ready(req_ready), .i_addr(req_addr), .i_id(req_id),
    .i_is_write(req_wr), .i_path(req_path), .i_wdata(req_wdata), .i_wstrb(req_wstrb), .i_offset(req_off),
    .o_tag_rd_en(t_rd_en), .o_tag_index(t_index), .i_tag_rdata(t_rdata), .i_tag_plru(t_plru),
    .o_tag_wr_en(t_wr_en), .o_tag_wr_way(t_wr_way), .o_tag_wr_index(t_wr_index), .o_tag_wdata(t_wdata),
    .o_plru_we(p_we), .o_plru_wr_index(p_wr_index), .o_plru_upd(p_upd),
    .o_data_rd_en(d_rd_en), .o_data_index(d_index), .i_data_rdata(d_rdata),
    .o_data_wr_en(d_wr_en), .o_data_wr_way(d_wr_way), .o_data_wr_index(d_wr_index),
    .o_data_wdata(d_wdata), .o_data_wstrb(d_wstrb),
    .o_mshr_alloc(mshr_alloc), .o_mshr_addr(), .o_mshr_is_write(),
    .o_mshr_victim_way(victim_way), .o_mshr_victim_valid(victim_valid),
    .o_mshr_victim_dirty(victim_dirty), .o_mshr_victim_tag(victim_tag),
    .i_mshr_full(1'b0), .i_mshr_merge(1'b0), .i_block_valid(1'b0), .i_block_page('0),
    .i_fill_valid(fill_valid), .i_fill_index(fill_index), .i_fill_way(fill_way),
    .i_fill_tag(fill_tag), .i_fill_data(fill_data), .i_fill_dirty(fill_dirty), .o_fill_ready(fill_ready),
    .o_resp_valid(resp_valid), .o_resp_id(resp_id), .o_resp_is_write(resp_isw),
    .o_resp_data(resp_data), .o_resp_offset(resp_off), .o_resp_code(resp_code), .i_resp_ready(1'b1),
    .i_cache_en(1'b1), .o_perf_hit(), .o_perf_miss(), .o_perf_wr_hit(), .o_perf_wr_miss()
  );

  tag_ram u_tag (
    .clk, .rst_n, .i_rd_en(t_rd_en), .i_index(t_index), .o_rdata(t_rdata), .o_plru(t_plru),
    .o_ecc_corr(), .o_ecc_uncorr(),
    .i_wr_en(t_wr_en), .i_wr_way(t_wr_way), .i_wr_index(t_wr_index), .i_wdata(t_wdata),
    .i_plru_we(p_we), .i_plru_wr_index(p_wr_index), .i_plru_upd(p_upd), .i_inval_all(1'b0)
  );

  data_ram u_data (
    .clk, .rst_n, .i_rd_en(d_rd_en), .i_index(d_index), .o_rdata(d_rdata),
    .o_ecc_corr(), .o_ecc_uncorr(),
    .i_wr_en(d_wr_en), .i_wr_way(d_wr_way), .i_wr_index(d_wr_index),
    .i_wdata(d_wdata), .i_wstrb(d_wstrb)
  );

  // ---- 辅助 ----
  function automatic logic [LA_ADDR_W-1:0] mk_addr(input logic [TAG_W-1:0] tg,
                                                   input logic [IDX_W-1:0] ix);
    return {tg, ix, {OFFSET_W{1'b0}}};
  endfunction

  task automatic do_fill(input logic [IDX_W-1:0] ix, input logic [WAY_W-1:0] wy,
                         input logic [TAG_W-1:0] tg, input logic [LINE_BITS-1:0] dat);
    @(posedge clk); fill_valid<=1; fill_index<=ix; fill_way<=wy; fill_tag<=tg;
                    fill_data<=dat; fill_dirty<=0;
    @(posedge clk); fill_valid<=0;
    repeat (2) @(posedge clk);          // 写落地 + 间隔
  endtask

  task automatic do_req(input logic wr, input logic [LA_ADDR_W-1:0] a,
                        input logic [LINE_BITS-1:0] wd);
    @(posedge clk); req_valid<=1; req_wr<=wr; req_addr<=a; req_path<=PATH_NORMAL;
                    req_wdata<=wd; req_wstrb<='1; req_id<=0; req_off<=0;
    @(posedge clk); req_valid<=0;
  endtask

  integer fails;
  logic [LINE_BITS-1:0] D [4];
  logic [LINE_BITS-1:0] NW;
  logic [WAY_W-1:0]     last_way;
  initial begin
    fails=0; req_valid=0; fill_valid=0;
    rst_n=0; repeat(4) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);

    // 数据 pattern
    for (int w=0; w<4; w++) D[w] = {16{32'h1000_0000 + w}};

    // 1) fill 预热 set0 的 4 路:tag=20+w
    for (int w=0; w<4; w++) do_fill(0, w[WAY_W-1:0], TAG_W'(20+w), D[w]);

    // 2) read-hit:逐 tag 读,验证数据
    for (int w=0; w<4; w++) begin
      do_req(0, mk_addr(TAG_W'(20+w), '0), '0);
      @(negedge resp_valid or posedge resp_valid);
      wait (resp_valid);
      if (resp_data !== D[w]) begin fails++; $display("READ-HIT FAIL way%0d: got=%h exp=%h", w, resp_data, D[w]); end
      @(posedge clk); repeat(2) @(posedge clk);
    end

    // 3) write-hit way1(tag21):写新数据,再读回
    begin
      NW = {16{32'hDEAD_0000 + 32'd1}};
      do_req(1, mk_addr(TAG_W'(21), '0), NW);
      repeat(4) @(posedge clk);
      do_req(0, mk_addr(TAG_W'(21), '0), '0);
      wait (resp_valid);
      if (resp_data !== NW) begin fails++; $display("WRITE-HIT FAIL: got=%h exp=%h", resp_data, NW); end
      @(posedge clk); repeat(2) @(posedge clk);
    end

    // 4) pLRU:刚读过 tag21(way1) → 对 set0 发 miss(新 tag99),victim 不应为 way1
    begin
      last_way = 2'd1;
      do_req(0, mk_addr(TAG_W'(21), '0), '0); // 访问 way1,使其为 MRU
      repeat(4) @(posedge clk);
      do_req(0, mk_addr(TAG_W'(99), '0), '0); // miss(set0 无 tag99)
      // 等该请求进入 S3(mshr_alloc 拉高)
      fork begin : wait_alloc
        int g; g=0;
        while (!mshr_alloc && g<20) begin @(posedge clk); g++; end
      end join
      if (!mshr_alloc) begin fails++; $display("PLRU FAIL: no miss alloc"); end
      else if (victim_way === last_way) begin
        fails++; $display("PLRU FAIL: victim=%0d == MRU way%0d", victim_way, last_way);
      end
      @(posedge clk);
    end

    if (fails==0) $display("tb_sub_cache: ALL PASS");
    else          $display("tb_sub_cache: %0d FAIL", fails);
    $finish;
  end

  initial begin #50us; $display("tb_sub_cache: TIMEOUT"); $finish; end
endmodule
`default_nettype wire
