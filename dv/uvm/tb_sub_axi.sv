// ============================================================================
// tb_sub_axi.sv — AXI 端到端命中路径子系统
//   AXI master(BFM) → req_buffer → addr_decode → cache_pipe_ctrl → tag/data
//                   → resp_merge → AXI(R/B)
//   backdoor fill 预热 cache,验证:AXI read-hit 取回正确数据;AXI write-hit 读回更新。
//   单 line 事务(BEATS_PER_LINE=2 beat);miss/MSHR 链留后续。
// ============================================================================
`default_nettype none
module tb_sub_axi;
  import zc_pkg::*;

  logic clk=0, rst_n=0;
  always #0.625ns clk=~clk;

  // ---- 上游 AXI(TB master 驱动 req_buffer slave 输入)----
  logic                  arvalid, arready; logic [LA_ADDR_W-1:0] araddr; logic [AXI_ID_W-1:0] arid;
  logic                  awvalid, awready; logic [LA_ADDR_W-1:0] awaddr; logic [AXI_ID_W-1:0] awid;
  logic                  wvalid,  wready;  logic [AXI_DATA_W-1:0] wdata;  logic [AXI_DATA_W/8-1:0] wstrb; logic wlast;
  logic                  rvalid,  rready;  logic [AXI_DATA_W-1:0] rdata;  logic [1:0] rresp; logic rlast; logic [AXI_ID_W-1:0] rid;
  logic                  bvalid,  bready;  logic [1:0] bresp; logic [AXI_ID_W-1:0] bid;

  // ---- req_buffer → addr_decode → pipe 链 ----
  logic                  rb_v, rb_r; logic [LA_ADDR_W-1:0] rb_addr; logic [AXI_ID_W-1:0] rb_id;
  logic                  rb_wr; logic [7:0] rb_len; logic [2:0] rb_prot; logic [3:0] rb_cache;
  logic [LINE_BITS-1:0]  rb_wdata; logic [LINE_BYTES-1:0] rb_wstrb; logic [OFFSET_W-1:0] rb_off;

  logic                  ad_v, ad_r; logic [LA_ADDR_W-1:0] ad_addr; logic [AXI_ID_W-1:0] ad_id;
  logic                  ad_wr; req_path_e ad_path;
  logic [LINE_BITS-1:0]  ad_wdata; logic [LINE_BYTES-1:0] ad_wstrb; logic [OFFSET_W-1:0] ad_off;

  // pipe ↔ RAM
  logic t_rd; logic [IDX_W-1:0] t_idx; tag_entry_t [N_WAY-1:0] t_rd_d; logic [PLRU_W-1:0] t_plru;
  logic t_wr; logic [WAY_W-1:0] t_wr_w; logic [IDX_W-1:0] t_wr_i; tag_entry_t t_wr_d;
  logic p_we; logic [IDX_W-1:0] p_wi; logic [PLRU_W-1:0] p_up;
  logic d_rd; logic [IDX_W-1:0] d_idx; logic [N_WAY-1:0][LINE_BITS-1:0] d_rd_d;
  logic d_wr; logic [WAY_W-1:0] d_wr_w; logic [IDX_W-1:0] d_wr_i; logic [LINE_BITS-1:0] d_wr_d; logic [LINE_BYTES-1:0] d_wr_s;

  // pipe → resp_merge
  logic rsp_v, rsp_r; logic [AXI_ID_W-1:0] rsp_id; logic rsp_isw; logic [LINE_BITS-1:0] rsp_d;
  logic [OFFSET_W-1:0] rsp_off; logic [1:0] rsp_code;

  // backdoor fill
  logic fill_v, fill_rdy; logic [IDX_W-1:0] fill_i; logic [WAY_W-1:0] fill_w;
  logic [TAG_W-1:0] fill_t; logic [LINE_BITS-1:0] fill_d; logic fill_dty;

  // bypass 配置(全 0 → 无 bypass);nca_mode=2(正常)
  logic [LA_ADDR_W-1:0] bp_s [N_BYPASS_REGION]; logic [LA_ADDR_W-1:0] bp_e [N_BYPASS_REGION];

  req_buffer u_rb (
    .clk, .rst_n,
    .s_arvalid(arvalid), .s_arready(arready), .s_arid(arid), .s_araddr(araddr),
    .s_arlen(8'd1), .s_arsize(3'd5), .s_arburst(2'b01), .s_arcache(4'b0011), .s_arprot(3'b010),
    .s_awvalid(awvalid), .s_awready(awready), .s_awid(awid), .s_awaddr(awaddr),
    .s_awlen(8'd1), .s_awsize(3'd5), .s_awcache(4'b0011), .s_awprot(3'b010),
    .s_wvalid(wvalid), .s_wready(wready), .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(wlast),
    .o_req_valid(rb_v), .i_req_ready(rb_r), .o_addr(rb_addr), .o_id(rb_id), .o_is_write(rb_wr),
    .o_len(rb_len), .o_prot(rb_prot), .o_cache(rb_cache), .o_wdata(rb_wdata), .o_wstrb(rb_wstrb),
    .o_offset(rb_off), .o_first(), .o_last()
  );

  addr_decode u_ad (
    .clk, .rst_n,
    .i_req_valid(rb_v), .o_req_ready(rb_r), .i_addr(rb_addr), .i_id(rb_id), .i_is_write(rb_wr),
    .i_prot(rb_prot), .i_cache(rb_cache), .i_wdata(rb_wdata), .i_wstrb(rb_wstrb), .i_offset(rb_off),
    .i_cfg_bypass_start(bp_s), .i_cfg_bypass_end(bp_e), .i_cfg_nca_mode(2'd2),
    .o_req_valid(ad_v), .i_req_ready(ad_r), .o_addr(ad_addr), .o_id(ad_id), .o_is_write(ad_wr),
    .o_wdata(ad_wdata), .o_wstrb(ad_wstrb), .o_offset(ad_off), .o_path(ad_path)
  );

  cache_pipe_ctrl u_pipe (
    .clk, .rst_n,
    .i_req_valid(ad_v), .o_req_ready(ad_r), .i_addr(ad_addr), .i_id(ad_id), .i_is_write(ad_wr),
    .i_path(ad_path), .i_wdata(ad_wdata), .i_wstrb(ad_wstrb), .i_offset(ad_off),
    .o_tag_rd_en(t_rd), .o_tag_index(t_idx), .i_tag_rdata(t_rd_d), .i_tag_plru(t_plru),
    .o_tag_wr_en(t_wr), .o_tag_wr_way(t_wr_w), .o_tag_wr_index(t_wr_i), .o_tag_wdata(t_wr_d),
    .o_plru_we(p_we), .o_plru_wr_index(p_wi), .o_plru_upd(p_up),
    .o_data_rd_en(d_rd), .o_data_index(d_idx), .i_data_rdata(d_rd_d),
    .o_data_wr_en(d_wr), .o_data_wr_way(d_wr_w), .o_data_wr_index(d_wr_i), .o_data_wdata(d_wr_d), .o_data_wstrb(d_wr_s),
    .o_mshr_alloc(), .o_mshr_addr(), .o_mshr_is_write(), .o_mshr_victim_way(),
    .o_mshr_victim_valid(), .o_mshr_victim_dirty(), .o_mshr_victim_tag(),
    .i_mshr_full(1'b0), .i_mshr_merge(1'b0), .i_block_valid(1'b0), .i_block_page('0),
    .i_fill_valid(fill_v), .i_fill_index(fill_i), .i_fill_way(fill_w), .i_fill_tag(fill_t),
    .i_fill_data(fill_d), .i_fill_dirty(fill_dty), .o_fill_ready(fill_rdy),
    .o_resp_valid(rsp_v), .o_resp_id(rsp_id), .o_resp_is_write(rsp_isw), .o_resp_data(rsp_d),
    .o_resp_offset(rsp_off), .o_resp_code(rsp_code), .i_resp_ready(rsp_r),
    .i_cache_en(1'b1), .o_perf_hit(), .o_perf_miss(), .o_perf_wr_hit(), .o_perf_wr_miss()
  );

  tag_ram u_tag (.clk,.rst_n,.i_rd_en(t_rd),.i_index(t_idx),.o_rdata(t_rd_d),.o_plru(t_plru),
    .o_ecc_corr(),.o_ecc_uncorr(),.i_wr_en(t_wr),.i_wr_way(t_wr_w),.i_wr_index(t_wr_i),.i_wdata(t_wr_d),
    .i_plru_we(p_we),.i_plru_wr_index(p_wi),.i_plru_upd(p_up),.i_inval_all(1'b0));
  data_ram u_data (.clk,.rst_n,.i_rd_en(d_rd),.i_index(d_idx),.o_rdata(d_rd_d),
    .o_ecc_corr(),.o_ecc_uncorr(),.i_wr_en(d_wr),.i_wr_way(d_wr_w),.i_wr_index(d_wr_i),
    .i_wdata(d_wr_d),.i_wstrb(d_wr_s));

  resp_merge u_rm (
    .clk, .rst_n,
    .i_resp_valid(rsp_v), .o_resp_ready(rsp_r), .i_resp_id(rsp_id), .i_resp_is_write(rsp_isw),
    .i_resp_data(rsp_d), .i_resp_offset(rsp_off), .i_resp_code(rsp_code),
    .i_ctx_push(1'b0), .i_ctx_id('0), .i_ctx_len('0), .i_ctx_size('0), .i_ctx_first(1'b0), .i_ctx_last(1'b0),
    .i_oom_tripped(1'b0),
    .o_rvalid(rvalid), .i_rready(rready), .o_rid(rid), .o_rdata(rdata), .o_rresp(rresp), .o_rlast(rlast),
    .o_bvalid(bvalid), .i_bready(bready), .o_bid(bid), .o_bresp(bresp)
  );

  // ---- AXI master BFM ----
  function automatic logic [LA_ADDR_W-1:0] mk_addr(input logic [TAG_W-1:0] tg);
    return {tg, {IDX_W{1'b0}}, {OFFSET_W{1'b0}}};   // index 0
  endfunction

  task automatic bd_fill(input logic [WAY_W-1:0] wy, input logic [TAG_W-1:0] tg,
                         input logic [LINE_BITS-1:0] dat);
    @(posedge clk); fill_v<=1; fill_i<='0; fill_w<=wy; fill_t<=tg; fill_d<=dat; fill_dty<=0;
    @(posedge clk); fill_v<=0;
    repeat(2) @(posedge clk);
  endtask

  task automatic axi_read(input logic [LA_ADDR_W-1:0] a, output logic [LINE_BITS-1:0] line);
    int b;
    @(posedge clk); arvalid<=1; araddr<=a; arid<=0;
    do @(posedge clk); while(!arready); arvalid<=0;
    b=0; rready<=1;
    while (b < BEATS_PER_LINE) begin
      @(posedge clk);
      if (rvalid) begin line[b*AXI_DATA_W +: AXI_DATA_W] = rdata; b++; end
    end
    rready<=0;
  endtask

  task automatic axi_write(input logic [LA_ADDR_W-1:0] a, input logic [LINE_BITS-1:0] line);
    int b;
    @(posedge clk); awvalid<=1; awaddr<=a; awid<=0;
    do @(posedge clk); while(!awready); awvalid<=0;
    b=0;
    while (b < BEATS_PER_LINE) begin
      wvalid<=1; wdata<=line[b*AXI_DATA_W +: AXI_DATA_W]; wstrb<='1; wlast<=(b==BEATS_PER_LINE-1);
      @(posedge clk);
      if (wready) b++;
    end
    wvalid<=0; wlast<=0;
    bready<=1; do @(posedge clk); while(!bvalid); bready<=0;
  endtask

  integer fails;
  logic [LINE_BITS-1:0] D[4], rl, nw;
  initial begin
    fails=0; arvalid=0; awvalid=0; wvalid=0; rready=0; bready=0; fill_v=0;
    for (int i=0;i<N_BYPASS_REGION;i++) begin bp_s[i]='0; bp_e[i]='0; end
    rst_n=0; repeat(5) @(posedge clk); rst_n=1; repeat(3) @(posedge clk);

    for (int w=0; w<4; w++) D[w] = {16{32'hC0DE_0000 + w}};
    // 预热 4 路(tag=30+w)
    for (int w=0; w<4; w++) bd_fill(w[WAY_W-1:0], TAG_W'(30+w), D[w]);

    // AXI read-hit 每路
    for (int w=0; w<4; w++) begin
      axi_read(mk_addr(TAG_W'(30+w)), rl);
      if (rl !== D[w]) begin fails++; $display("AXI READ-HIT FAIL w%0d: got=%h exp=%h", w, rl, D[w]); end
      repeat(2) @(posedge clk);
    end

    // AXI write-hit(tag31)→ 读回
    nw = {16{32'hBEEF_0000 + 32'd7}};
    axi_write(mk_addr(TAG_W'(31)), nw);
    repeat(3) @(posedge clk);
    axi_read(mk_addr(TAG_W'(31)), rl);
    if (rl !== nw) begin fails++; $display("AXI WRITE-HIT FAIL: got=%h exp=%h", rl, nw); end

    if (fails==0) $display("tb_sub_axi: ALL PASS");
    else          $display("tb_sub_axi: %0d FAIL", fails);
    $finish;
  end

  initial begin #80us; $display("tb_sub_axi: TIMEOUT"); $finish; end
endmodule
`default_nettype wire
