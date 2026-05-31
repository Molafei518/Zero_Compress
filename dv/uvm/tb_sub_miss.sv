// ============================================================================
// tb_sub_miss.sv — 最小 miss 链端到端:read-miss → DDR(压缩) → 解压 → fill → 重读命中
//   组成:cache_pipe_ctrl + tag_ram + data_ram + mshr_min + decompress_top
//         + 压缩页 DDR 行为模型(TB) + setup 用 compress_top
//   验证容量扩展器核心读路径:数据以压缩态存 DDR,miss 时透明解压回填,重读得原始数据。
//   evict/write-alloc/L2P-in-DDR/alloc 留后续。
// ============================================================================
`default_nettype none
module tb_sub_miss;
  import zc_pkg::*;

  localparam int NT = 6;             // 测试行数
  logic clk=0, rst_n=0;
  always #0.625ns clk=~clk;

  // ---- pipe (B) 请求 ----
  logic req_v, req_r; logic [LA_ADDR_W-1:0] req_a; logic req_wr; req_path_e req_p;
  logic [LINE_BITS-1:0] req_wd; logic [LINE_BYTES-1:0] req_ws; logic [OFFSET_W-1:0] req_o;
  // ---- pipe (I) resp ----
  logic rsp_v; logic [AXI_ID_W-1:0] rsp_id; logic rsp_isw; logic [LINE_BITS-1:0] rsp_d;
  logic [OFFSET_W-1:0] rsp_off; logic [1:0] rsp_code;
  // ---- pipe (E) miss → mshr ----
  logic m_alloc; logic [LA_ADDR_W-1:0] m_addr; logic [WAY_W-1:0] m_vway; logic m_vvalid;
  logic mshr_busy;
  // ---- pipe ↔ RAM ----
  logic t_rd; logic [IDX_W-1:0] t_idx; tag_entry_t [N_WAY-1:0] t_rd_d; logic [PLRU_W-1:0] t_plru;
  logic t_wr; logic [WAY_W-1:0] t_wr_w; logic [IDX_W-1:0] t_wr_i; tag_entry_t t_wr_d;
  logic p_we; logic [IDX_W-1:0] p_wi; logic [PLRU_W-1:0] p_up;
  logic d_rd; logic [IDX_W-1:0] d_idx; logic [N_WAY-1:0][LINE_BITS-1:0] d_rd_d;
  logic d_wr; logic [WAY_W-1:0] d_wr_w; logic [IDX_W-1:0] d_wr_i; logic [LINE_BITS-1:0] d_wr_d; logic [LINE_BYTES-1:0] d_wr_s;
  // ---- mshr ↔ fill ----
  logic f_v, f_rdy; logic [IDX_W-1:0] f_i; logic [WAY_W-1:0] f_w; logic [TAG_W-1:0] f_t;
  logic [LINE_BITS-1:0] f_d; logic f_dty;
  // ---- mshr ↔ DDR 模型 ----
  logic ddr_req; logic [LA_ADDR_W-1:0] ddr_addr;
  logic ddr_v; algo_e ddr_algo; logic [2:0] ddr_mode; logic [6:0] ddr_size;
  logic [LINE_BITS-1:0] ddr_data; logic [7:0] ddr_crc8;
  // ---- mshr ↔ decompress ----
  logic dec_req; algo_e dec_algo; logic [2:0] dec_mode; logic [6:0] dec_size;
  logic [LINE_BITS-1:0] dec_data; logic [7:0] dec_crc8;
  logic dec_done; logic [LINE_BITS-1:0] dec_line; logic dec_err;
  // ---- setup compress ----
  logic sc_req; logic [LINE_BITS-1:0] sc_line; logic sc_done;
  algo_e sc_algo; logic [2:0] sc_mode; logic [6:0] sc_size; logic [LINE_BITS-1:0] sc_data; logic [7:0] sc_crc8;

  cache_pipe_ctrl u_pipe (
    .clk,.rst_n,
    .i_req_valid(req_v),.o_req_ready(req_r),.i_addr(req_a),.i_id('0),.i_is_write(req_wr),
    .i_path(req_p),.i_wdata(req_wd),.i_wstrb(req_ws),.i_offset(req_o),
    .o_tag_rd_en(t_rd),.o_tag_index(t_idx),.i_tag_rdata(t_rd_d),.i_tag_plru(t_plru),
    .o_tag_wr_en(t_wr),.o_tag_wr_way(t_wr_w),.o_tag_wr_index(t_wr_i),.o_tag_wdata(t_wr_d),
    .o_plru_we(p_we),.o_plru_wr_index(p_wi),.o_plru_upd(p_up),
    .o_data_rd_en(d_rd),.o_data_index(d_idx),.i_data_rdata(d_rd_d),
    .o_data_wr_en(d_wr),.o_data_wr_way(d_wr_w),.o_data_wr_index(d_wr_i),.o_data_wdata(d_wr_d),.o_data_wstrb(d_wr_s),
    .o_mshr_alloc(m_alloc),.o_mshr_addr(m_addr),.o_mshr_is_write(),
    .o_mshr_victim_way(m_vway),.o_mshr_victim_valid(m_vvalid),.o_mshr_victim_dirty(),.o_mshr_victim_tag(),
    .i_mshr_full(mshr_busy),.i_mshr_merge(1'b0),.i_block_valid(1'b0),.i_block_page('0),
    .i_fill_valid(f_v),.i_fill_index(f_i),.i_fill_way(f_w),.i_fill_tag(f_t),.i_fill_data(f_d),.i_fill_dirty(f_dty),.o_fill_ready(f_rdy),
    .o_resp_valid(rsp_v),.o_resp_id(rsp_id),.o_resp_is_write(rsp_isw),.o_resp_data(rsp_d),
    .o_resp_offset(rsp_off),.o_resp_code(rsp_code),.i_resp_ready(1'b1),
    .i_cache_en(1'b1),.o_perf_hit(),.o_perf_miss(),.o_perf_wr_hit(),.o_perf_wr_miss()
  );
  tag_ram u_tag (.clk,.rst_n,.i_rd_en(t_rd),.i_index(t_idx),.o_rdata(t_rd_d),.o_plru(t_plru),
    .o_ecc_corr(),.o_ecc_uncorr(),.i_wr_en(t_wr),.i_wr_way(t_wr_w),.i_wr_index(t_wr_i),.i_wdata(t_wr_d),
    .i_plru_we(p_we),.i_plru_wr_index(p_wi),.i_plru_upd(p_up),.i_inval_all(1'b0));
  data_ram u_data (.clk,.rst_n,.i_rd_en(d_rd),.i_index(d_idx),.o_rdata(d_rd_d),
    .o_ecc_corr(),.o_ecc_uncorr(),.i_wr_en(d_wr),.i_wr_way(d_wr_w),.i_wr_index(d_wr_i),.i_wdata(d_wr_d),.i_wstrb(d_wr_s));

  mshr_min u_mshr (
    .clk,.rst_n,.i_alloc(m_alloc),.i_addr(m_addr),.i_victim_way(m_vway),.i_victim_valid(m_vvalid),.o_busy(mshr_busy),
    .o_ddr_req(ddr_req),.o_ddr_addr(ddr_addr),.i_ddr_valid(ddr_v),.i_ddr_algo(ddr_algo),
    .i_ddr_mode(ddr_mode),.i_ddr_size(ddr_size),.i_ddr_data(ddr_data),.i_ddr_crc8(ddr_crc8),
    .o_dec_req(dec_req),.o_dec_algo(dec_algo),.o_dec_mode(dec_mode),.o_dec_size(dec_size),
    .o_dec_data(dec_data),.o_dec_crc8(dec_crc8),.i_dec_done(dec_done),.i_dec_line(dec_line),.i_dec_crc_err(dec_err),
    .o_fill_valid(f_v),.o_fill_index(f_i),.o_fill_way(f_w),.o_fill_tag(f_t),.o_fill_data(f_d),.o_fill_dirty(f_dty),.i_fill_ready(f_rdy),
    .o_irq_decomp_err()
  );
  decompress_top u_dec (
    .clk,.rst_n,.i_req(dec_req),.i_algo(dec_algo),.i_mode(dec_mode),.i_size(dec_size),
    .i_data(dec_data),.i_crc8_exp(dec_crc8),.o_done(dec_done),.o_line(dec_line),.o_crc_err(dec_err)
  );
  compress_top u_setup_comp (
    .clk,.rst_n,.i_req(sc_req),.i_line(sc_line),.o_done(sc_done),
    .o_algo(sc_algo),.o_mode(sc_mode),.o_size(sc_size),.o_data(sc_data),.o_crc8(sc_crc8)
  );

  // ---- 压缩页 DDR 行为模型(按 tag 存压缩行)----
  algo_e                ddr_a [NT]; logic [2:0] ddr_m [NT]; logic [6:0] ddr_s [NT];
  logic [LINE_BITS-1:0] ddr_cd[NT]; logic [7:0] ddr_c8[NT];
  logic [3:0] ddr_cnt; logic ddr_busy;
  function automatic int key(input logic [LA_ADDR_W-1:0] a); return (a >> (OFFSET_W+IDX_W)) - 40; endfunction
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin ddr_v<=0; ddr_busy<=0; ddr_cnt<=0; end
    else begin
      ddr_v <= 0;
      if (ddr_req && !ddr_busy) begin ddr_busy<=1; ddr_cnt<=4; end          // 模拟 DDR 延迟
      else if (ddr_busy) begin
        if (ddr_cnt==0) begin
          int k; k = key(ddr_addr);
          ddr_v<=1; ddr_algo<=ddr_a[k]; ddr_mode<=ddr_m[k]; ddr_size<=ddr_s[k];
          ddr_data<=ddr_cd[k]; ddr_crc8<=ddr_c8[k]; ddr_busy<=0;
        end else ddr_cnt<=ddr_cnt-1;
      end
    end
  end

  // ---- 辅助 ----
  function automatic logic [LA_ADDR_W-1:0] mk_addr(input int k); // tag=40+k, index 0
    return {TAG_W'(40+k), {IDX_W{1'b0}}, {OFFSET_W{1'b0}}};
  endfunction

  task automatic setup_compress(input logic [LINE_BITS-1:0] ln, input int k);
    @(posedge clk); sc_line<=ln; sc_req<=1;
    @(posedge clk); sc_req<=0;
    wait (sc_done);
    ddr_a[k]=sc_algo; ddr_m[k]=sc_mode; ddr_s[k]=sc_size; ddr_cd[k]=sc_data; ddr_c8[k]=sc_crc8;
    @(posedge clk);
  endtask

  task automatic miss_read(input int k, output logic [LINE_BITS-1:0] got);
    // 1) 触发 miss(读未缓存地址)
    @(posedge clk); req_v<=1; req_wr<=0; req_a<=mk_addr(k); req_p<=PATH_NORMAL; req_wd<='0; req_ws<='0; req_o<='0;
    @(posedge clk); req_v<=0;
    $display("[%0t] miss_read k=%0d: req issued", $time, k);
    // 2) 等 mshr 完成 miss 链(fetch→decomp→fill)
    wait (mshr_busy); $display("[%0t]   mshr busy", $time);
    wait (!mshr_busy); $display("[%0t]   mshr done", $time);
    repeat(2) @(posedge clk);
    // 3) 重读(命中)→ 取数据
    @(posedge clk); req_v<=1; req_wr<=0; req_a<=mk_addr(k);
    @(posedge clk); req_v<=0;
    wait (rsp_v); got = rsp_d; $display("[%0t]   retry hit data=%h", $time, rsp_d);
    repeat(2) @(posedge clk);
  endtask

  integer fails;
  logic [LINE_BITS-1:0] L [NT], rl;
  initial begin
    fails=0; req_v=0; sc_req=0;
    rst_n=0; repeat(5) @(posedge clk); rst_n=1; repeat(3) @(posedge clk);

    // 代表性测试行(覆盖不同算法)
    L[0]='0;                                   // 全零
    L[1]={16{32'h0000_0457}};                  // 单值(BDI)
    for(int i=0;i<16;i++) L[2][i*32+:32]=32'd1000+i;     // 小整数(BDI)
    L[3]={64{8'h7A}};                          // 单 byte(ByteDelta)
    L[4]='0; L[4][31:0]=32'hDEAD_BEEF;         // 稀疏(Zero)
    for(int i=0;i<64;i++) L[5][i*8+:8]=8'(100+($signed(i)%4)-2); // YUV-ish(ByteDelta)

    // setup:压缩各行存入 DDR 模型
    for (int k=0;k<NT;k++) setup_compress(L[k], k);
    $display("[%0t] setup done", $time);

    // miss 链:逐行 read-miss → fill → 重读命中,比对原始
    for (int k=0;k<NT;k++) begin
      miss_read(k, rl);
      if (rl !== L[k]) begin fails++; $display("MISS-CHAIN FAIL[%0d]: got=%h exp=%h", k, rl, L[k]); end
    end

    if (fails==0) $display("tb_sub_miss: ALL PASS");
    else          $display("tb_sub_miss: %0d FAIL", fails);
    $finish;
  end
  // 监视器
  always @(posedge clk) if (rst_n && m_alloc)
    $display("[%0t] ALLOC addr=%h vway=%0d vvalid=%0d", $time, m_addr, m_vway, m_vvalid);
  always @(posedge clk) if (rst_n && f_v && f_rdy)
    $display("[%0t] FILL idx=%0d way=%0d tag=%0d data=%h", $time, f_i, f_w, f_t, f_d);
  always @(posedge clk) if (rst_n && rsp_v)
    $display("[%0t] RESP data=%h", $time, rsp_d);

  initial begin #100us; $display("tb_sub_miss: TIMEOUT"); $finish; end
endmodule
`default_nettype wire
