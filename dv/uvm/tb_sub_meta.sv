// ============================================================================
// tb_sub_meta.sv — 真实元数据通路写读闭环
//   相比 tb_sub_wb:去掉 {algo,mode,size,crc8} 旁路。
//     evict:压缩 → page_header_pack 打包真实 Header → 写 DDR + 写 L2P(l2p_entry_t)
//     fetch:查 L2P → 读 DDR Header → page_header_unpack 解析 → 解压
//   验证:write→evict(压缩+真实Header+L2P)→read(查L2P→解Header→解压)读回原值。
// ============================================================================
`default_nettype none
module tb_sub_meta;
  import zc_pkg::*;

  logic clk=0, rst_n=0;
  always #0.625ns clk=~clk;

  // pipe (B)/(I)
  logic req_v, req_r; logic [LA_ADDR_W-1:0] req_a; logic req_wr; req_path_e req_p;
  logic [LINE_BITS-1:0] req_wd; logic [LINE_BYTES-1:0] req_ws; logic [OFFSET_W-1:0] req_o;
  logic rsp_v; logic [AXI_ID_W-1:0] rsp_id; logic rsp_isw; logic [LINE_BITS-1:0] rsp_d;
  logic [OFFSET_W-1:0] rsp_off; logic [1:0] rsp_code;
  // pipe (E)
  logic m_alloc; logic [LA_ADDR_W-1:0] m_addr; logic m_isw;
  logic [WAY_W-1:0] m_vway; logic m_vvalid, m_vdirty; logic [TAG_W-1:0] m_vtag; logic [LINE_BITS-1:0] m_vdata;
  logic mshr_busy;
  // RAM
  logic t_rd; logic [IDX_W-1:0] t_idx; tag_entry_t [N_WAY-1:0] t_rd_d; logic [PLRU_W-1:0] t_plru;
  logic t_wr; logic [WAY_W-1:0] t_wr_w; logic [IDX_W-1:0] t_wr_i; tag_entry_t t_wr_d;
  logic p_we; logic [IDX_W-1:0] p_wi; logic [PLRU_W-1:0] p_up;
  logic d_rd; logic [IDX_W-1:0] d_idx; logic [N_WAY-1:0][LINE_BITS-1:0] d_rd_d;
  logic d_wr; logic [WAY_W-1:0] d_wr_w; logic [IDX_W-1:0] d_wr_i; logic [LINE_BITS-1:0] d_wr_d; logic [LINE_BYTES-1:0] d_wr_s;
  // fill
  logic f_v, f_rdy; logic [IDX_W-1:0] f_i; logic [WAY_W-1:0] f_w; logic [TAG_W-1:0] f_t; logic [LINE_BITS-1:0] f_d; logic f_dty;
  // mshr ↔ compress/decompress
  logic cmp_req; logic [LINE_BITS-1:0] cmp_line; logic cmp_done;
  algo_e cmp_a; logic [2:0] cmp_m; logic [6:0] cmp_s; logic [LINE_BITS-1:0] cmp_d; logic [7:0] cmp_c;
  logic dec_req; algo_e dec_a; logic [2:0] dec_m; logic [6:0] dec_s; logic [LINE_BITS-1:0] dec_d; logic [7:0] dec_c;
  logic dec_done; logic [LINE_BITS-1:0] dec_line; logic dec_err;
  // mshr ↔ L2P
  logic l2p_rd; logic [LA_PAGE_W-1:0] l2p_page; logic l2p_v; l2p_entry_t l2p_ent;
  logic l2p_wr; logic [LA_PAGE_W-1:0] l2p_wp; l2p_entry_t l2p_we_ent;
  // mshr ↔ DDR(header+cdata)
  logic ddrw_req; logic [31:0] ddrw_ppa; logic [HEADER_BYTES*8-1:0] ddrw_hdr; logic [LINE_BITS-1:0] ddrw_cd; logic ddrw_done;
  logic ddrr_req; logic [31:0] ddrr_ppa; logic ddrr_v; logic [HEADER_BYTES*8-1:0] ddrr_hdr; logic [LINE_BITS-1:0] ddrr_cd;

  cache_pipe_ctrl u_pipe (
    .clk,.rst_n,
    .i_req_valid(req_v),.o_req_ready(req_r),.i_addr(req_a),.i_id('0),.i_is_write(req_wr),
    .i_path(req_p),.i_wdata(req_wd),.i_wstrb(req_ws),.i_offset(req_o),
    .o_tag_rd_en(t_rd),.o_tag_index(t_idx),.i_tag_rdata(t_rd_d),.i_tag_plru(t_plru),
    .o_tag_wr_en(t_wr),.o_tag_wr_way(t_wr_w),.o_tag_wr_index(t_wr_i),.o_tag_wdata(t_wr_d),
    .o_plru_we(p_we),.o_plru_wr_index(p_wi),.o_plru_upd(p_up),
    .o_data_rd_en(d_rd),.o_data_index(d_idx),.i_data_rdata(d_rd_d),
    .o_data_wr_en(d_wr),.o_data_wr_way(d_wr_w),.o_data_wr_index(d_wr_i),.o_data_wdata(d_wr_d),.o_data_wstrb(d_wr_s),
    .o_mshr_alloc(m_alloc),.o_mshr_addr(m_addr),.o_mshr_is_write(m_isw),
    .o_mshr_victim_way(m_vway),.o_mshr_victim_valid(m_vvalid),.o_mshr_victim_dirty(m_vdirty),
    .o_mshr_victim_tag(m_vtag),.o_mshr_victim_data(m_vdata),
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

  mshr_meta u_mshr (
    .clk,.rst_n,.i_alloc(m_alloc),.i_addr(m_addr),.i_is_write(m_isw),
    .i_victim_way(m_vway),.i_victim_valid(m_vvalid),.i_victim_dirty(m_vdirty),.i_victim_tag(m_vtag),.i_victim_data(m_vdata),.o_busy(mshr_busy),
    .o_cmp_req(cmp_req),.o_cmp_line(cmp_line),.i_cmp_done(cmp_done),.i_cmp_algo(cmp_a),.i_cmp_mode(cmp_m),.i_cmp_size(cmp_s),.i_cmp_data(cmp_d),.i_cmp_crc8(cmp_c),
    .o_dec_req(dec_req),.o_dec_algo(dec_a),.o_dec_mode(dec_m),.o_dec_size(dec_s),.o_dec_data(dec_d),.o_dec_crc8(dec_c),.i_dec_done(dec_done),.i_dec_line(dec_line),.i_dec_crc_err(dec_err),
    .o_l2p_rd(l2p_rd),.o_l2p_page(l2p_page),.i_l2p_valid(l2p_v),.i_l2p_entry(l2p_ent),
    .o_l2p_wr(l2p_wr),.o_l2p_wr_page(l2p_wp),.o_l2p_wr_entry(l2p_we_ent),
    .o_ddrw_req(ddrw_req),.o_ddrw_ppa(ddrw_ppa),.o_ddrw_header(ddrw_hdr),.o_ddrw_cdata(ddrw_cd),.i_ddrw_done(ddrw_done),
    .o_ddrr_req(ddrr_req),.o_ddrr_ppa(ddrr_ppa),.i_ddrr_valid(ddrr_v),.i_ddrr_header(ddrr_hdr),.i_ddrr_cdata(ddrr_cd),
    .o_fill_valid(f_v),.o_fill_index(f_i),.o_fill_way(f_w),.o_fill_tag(f_t),.o_fill_data(f_d),.o_fill_dirty(f_dty),.i_fill_ready(f_rdy),
    .o_irq_decomp_err()
  );
  compress_top   u_cmp (.clk,.rst_n,.i_req(cmp_req),.i_line(cmp_line),.o_done(cmp_done),
    .o_algo(cmp_a),.o_mode(cmp_m),.o_size(cmp_s),.o_data(cmp_d),.o_crc8(cmp_c));
  decompress_top u_dec (.clk,.rst_n,.i_req(dec_req),.i_algo(dec_a),.i_mode(dec_m),.i_size(dec_s),
    .i_data(dec_d),.i_crc8_exp(dec_c),.o_done(dec_done),.o_line(dec_line),.o_crc_err(dec_err));

  // ---- L2P 模型(assoc l2p_entry_t)----
  l2p_entry_t l2p_store [bit[LA_PAGE_W-1:0]];
  logic l2p_busy; logic [1:0] l2p_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin l2p_v<=0; l2p_busy<=0; end
    else begin
      l2p_v<=0;
      if (l2p_wr) l2p_store[l2p_wp] = l2p_we_ent;          // 写 L2P
      if (l2p_rd && !l2p_busy) begin l2p_busy<=1; l2p_cnt<=1; end
      else if (l2p_busy) begin
        if (l2p_cnt==0) begin
          l2p_ent <= l2p_store.exists(l2p_page) ? l2p_store[l2p_page] : '0;
          l2p_v<=1; l2p_busy<=0;
        end else l2p_cnt<=l2p_cnt-1;
      end
    end
  end

  // ---- DDR 模型(按 ppa 存 Header + 压缩数据)----
  typedef struct packed { logic [HEADER_BYTES*8-1:0] h; logic [LINE_BITS-1:0] d; } pg_t;
  pg_t ddr_store [bit[31:0]];
  logic dw_busy, dr_busy; logic [2:0] dw_cnt, dr_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin ddrw_done<=0; dw_busy<=0; end
    else begin
      ddrw_done<=0;
      if (ddrw_req && !dw_busy) begin dw_busy<=1; dw_cnt<=3; end
      else if (dw_busy) begin
        if (dw_cnt==0) begin ddr_store[ddrw_ppa] = '{ddrw_hdr, ddrw_cd}; ddrw_done<=1; dw_busy<=0; end
        else dw_cnt<=dw_cnt-1;
      end
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin ddrr_v<=0; dr_busy<=0; end
    else begin
      ddrr_v<=0;
      if (ddrr_req && !dr_busy) begin dr_busy<=1; dr_cnt<=3; end
      else if (dr_busy) begin
        if (dr_cnt==0) begin
          pg_t pg; pg = ddr_store.exists(ddrr_ppa) ? ddr_store[ddrr_ppa] : '0;
          ddrr_hdr<=pg.h; ddrr_cd<=pg.d; ddrr_v<=1; dr_busy<=0;
        end else dr_cnt<=dr_cnt-1;
      end
    end
  end

  // ---- 辅助 ----
  function automatic logic [LA_ADDR_W-1:0] mk(input int tg);
    return {TAG_W'(tg), {IDX_W{1'b0}}, {OFFSET_W{1'b0}}};
  endfunction
  function automatic logic [LA_PAGE_W-1:0] pg_of(input int tg);
    return mk(tg) >> PAGE_OFFSET_W;   // = la_page_num(mk(tg)),与引擎一致
  endfunction
  task automatic drive(input logic wr, input logic [LA_ADDR_W-1:0] a, input logic [LINE_BITS-1:0] wd);
    @(posedge clk); req_v<=1; req_wr<=wr; req_a<=a; req_p<=PATH_NORMAL; req_wd<=wd; req_ws<={LINE_BYTES{wr}}; req_o<='0;
    @(posedge clk); req_v<=0;
  endtask
  task automatic wmiss(input logic [LA_ADDR_W-1:0] a, input logic [LINE_BITS-1:0] wd);
    drive(1,a,wd); wait(mshr_busy); wait(!mshr_busy); repeat(2)@(posedge clk);
    drive(1,a,wd); repeat(5)@(posedge clk);
  endtask
  task automatic rmiss(input logic [LA_ADDR_W-1:0] a, output logic [LINE_BITS-1:0] got);
    drive(0,a,'0); wait(mshr_busy); wait(!mshr_busy); repeat(2)@(posedge clk);
    drive(0,a,'0); wait(rsp_v); got=rsp_d; repeat(2)@(posedge clk);
  endtask
  task automatic tread(input logic [LA_ADDR_W-1:0] a);
    drive(0,a,'0); wait(mshr_busy); wait(!mshr_busy); repeat(2)@(posedge clk);
  endtask

  integer fails;
  logic [LINE_BITS-1:0] PX, got;
  initial begin
    fails=0; req_v=0;
    rst_n=0; repeat(5)@(posedge clk); rst_n=1; repeat(3)@(posedge clk);

    PX = {16{32'h0000_1234}};
    wmiss(mk(50), PX);
    for (int j=1;j<=8;j++) tread(mk(50+j));
    // L2P 应已记录 X 页映射(evict 写 L2P + 真实 Header)
    if (!l2p_store.exists(pg_of(50)) || !l2p_store[pg_of(50)].valid)
      begin fails++; $display("META FAIL: L2P 未记录 X(evict 未发生)"); end
    rmiss(mk(50), got);
    if (got !== PX) begin fails++; $display("META FAIL: read X got=%h exp=%h", got, PX); end

    if (fails==0) $display("tb_sub_meta: ALL PASS");
    else          $display("tb_sub_meta: %0d FAIL", fails);
    $finish;
  end
  initial begin #100us; $display("tb_sub_meta: TIMEOUT"); $finish; end
endmodule
`default_nettype wire
