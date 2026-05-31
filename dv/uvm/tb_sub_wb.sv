// ============================================================================
// tb_sub_wb.sv — 写读闭环:write-allocate → 写入 → evict 压缩存 DDR → read 解压读回
//   组成:cache_pipe_ctrl + tag_ram + data_ram + mshr_wb
//         + compress_top(evict) + decompress_top(fill) + 压缩 DDR/L2P 模型(TB)
//   验证容量扩展器完整收益:写入数据被压缩存 DDR,evict 后仍可读回原值。
// ============================================================================
`default_nettype none
module tb_sub_wb;
  import zc_pkg::*;

  logic clk=0, rst_n=0;
  always #0.625ns clk=~clk;

  // pipe (B)
  logic req_v, req_r; logic [LA_ADDR_W-1:0] req_a; logic req_wr; req_path_e req_p;
  logic [LINE_BITS-1:0] req_wd; logic [LINE_BYTES-1:0] req_ws; logic [OFFSET_W-1:0] req_o;
  // pipe (I)
  logic rsp_v; logic [AXI_ID_W-1:0] rsp_id; logic rsp_isw; logic [LINE_BITS-1:0] rsp_d;
  logic [OFFSET_W-1:0] rsp_off; logic [1:0] rsp_code;
  // pipe (E) → mshr
  logic m_alloc; logic [LA_ADDR_W-1:0] m_addr; logic m_isw;
  logic [WAY_W-1:0] m_vway; logic m_vvalid, m_vdirty; logic [TAG_W-1:0] m_vtag; logic [LINE_BITS-1:0] m_vdata;
  logic mshr_busy;
  // RAM
  logic t_rd; logic [IDX_W-1:0] t_idx; tag_entry_t [N_WAY-1:0] t_rd_d; logic [PLRU_W-1:0] t_plru;
  logic t_wr; logic [WAY_W-1:0] t_wr_w; logic [IDX_W-1:0] t_wr_i; tag_entry_t t_wr_d;
  logic p_we; logic [IDX_W-1:0] p_wi; logic [PLRU_W-1:0] p_up;
  logic d_rd; logic [IDX_W-1:0] d_idx; logic [N_WAY-1:0][LINE_BITS-1:0] d_rd_d;
  logic d_wr; logic [WAY_W-1:0] d_wr_w; logic [IDX_W-1:0] d_wr_i; logic [LINE_BITS-1:0] d_wr_d; logic [LINE_BYTES-1:0] d_wr_s;
  // mshr fill
  logic f_v, f_rdy; logic [IDX_W-1:0] f_i; logic [WAY_W-1:0] f_w; logic [TAG_W-1:0] f_t; logic [LINE_BITS-1:0] f_d; logic f_dty;
  // mshr ↔ compress(evict)
  logic cmp_req; logic [LINE_BITS-1:0] cmp_line; logic cmp_done;
  algo_e cmp_a; logic [2:0] cmp_m; logic [6:0] cmp_s; logic [LINE_BITS-1:0] cmp_d; logic [7:0] cmp_c;
  // mshr ↔ decompress(fill)
  logic dec_req; algo_e dec_a; logic [2:0] dec_m; logic [6:0] dec_s; logic [LINE_BITS-1:0] dec_d; logic [7:0] dec_c;
  logic dec_done; logic [LINE_BITS-1:0] dec_line; logic dec_err;
  // mshr ↔ DDR
  logic ddrw_req; logic [LA_ADDR_W-1:0] ddrw_addr; algo_e ddrw_a; logic [2:0] ddrw_m; logic [6:0] ddrw_s;
  logic [LINE_BITS-1:0] ddrw_d; logic [7:0] ddrw_c; logic ddrw_done;
  logic ddrr_req; logic [LA_ADDR_W-1:0] ddrr_addr; logic ddrr_v;
  algo_e ddrr_a; logic [2:0] ddrr_m; logic [6:0] ddrr_s; logic [LINE_BITS-1:0] ddrr_d; logic [7:0] ddrr_c;

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

  mshr_wb u_mshr (
    .clk,.rst_n,.i_alloc(m_alloc),.i_addr(m_addr),.i_is_write(m_isw),
    .i_victim_way(m_vway),.i_victim_valid(m_vvalid),.i_victim_dirty(m_vdirty),.i_victim_tag(m_vtag),.i_victim_data(m_vdata),.o_busy(mshr_busy),
    .o_cmp_req(cmp_req),.o_cmp_line(cmp_line),.i_cmp_done(cmp_done),.i_cmp_algo(cmp_a),.i_cmp_mode(cmp_m),.i_cmp_size(cmp_s),.i_cmp_data(cmp_d),.i_cmp_crc8(cmp_c),
    .o_ddrw_req(ddrw_req),.o_ddrw_addr(ddrw_addr),.o_ddrw_algo(ddrw_a),.o_ddrw_mode(ddrw_m),.o_ddrw_size(ddrw_s),.o_ddrw_data(ddrw_d),.o_ddrw_crc8(ddrw_c),.i_ddrw_done(ddrw_done),
    .o_ddrr_req(ddrr_req),.o_ddrr_addr(ddrr_addr),.i_ddrr_valid(ddrr_v),.i_ddrr_algo(ddrr_a),.i_ddrr_mode(ddrr_m),.i_ddrr_size(ddrr_s),.i_ddrr_data(ddrr_d),.i_ddrr_crc8(ddrr_c),
    .o_dec_req(dec_req),.o_dec_algo(dec_a),.o_dec_mode(dec_m),.o_dec_size(dec_s),.o_dec_data(dec_d),.o_dec_crc8(dec_c),.i_dec_done(dec_done),.i_dec_line(dec_line),.i_dec_crc_err(dec_err),
    .o_fill_valid(f_v),.o_fill_index(f_i),.o_fill_way(f_w),.o_fill_tag(f_t),.o_fill_data(f_d),.o_fill_dirty(f_dty),.i_fill_ready(f_rdy),
    .o_irq_decomp_err()
  );
  compress_top   u_cmp (.clk,.rst_n,.i_req(cmp_req),.i_line(cmp_line),.o_done(cmp_done),
    .o_algo(cmp_a),.o_mode(cmp_m),.o_size(cmp_s),.o_data(cmp_d),.o_crc8(cmp_c));
  decompress_top u_dec (.clk,.rst_n,.i_req(dec_req),.i_algo(dec_a),.i_mode(dec_m),.i_size(dec_s),
    .i_data(dec_d),.i_crc8_exp(dec_c),.o_done(dec_done),.o_line(dec_line),.o_crc_err(dec_err));

  // ---- 压缩 DDR/L2P 模型(assoc 存压缩行;未映射→零行)----
  typedef struct packed { algo_e a; logic[2:0] m; logic[6:0] s; logic[LINE_BITS-1:0] d; logic[7:0] c; } cl_t;
  cl_t store [bit[LA_ADDR_W-1:0]];
  cl_t zero_def;
  logic ddrw_busy, ddrr_busy; logic [2:0] ddrw_cnt, ddrr_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin ddrw_done<=0; ddrw_busy<=0; end
    else begin
      ddrw_done<=0;
      if (ddrw_req && !ddrw_busy) begin ddrw_busy<=1; ddrw_cnt<=3; end
      else if (ddrw_busy) begin
        if (ddrw_cnt==0) begin
          store[ddrw_addr] = '{ddrw_a, ddrw_m, ddrw_s, ddrw_d, ddrw_c}; // 存压缩行
          ddrw_done<=1; ddrw_busy<=0;
        end else ddrw_cnt<=ddrw_cnt-1;
      end
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin ddrr_v<=0; ddrr_busy<=0; end
    else begin
      ddrr_v<=0;
      if (ddrr_req && !ddrr_busy) begin ddrr_busy<=1; ddrr_cnt<=3; end
      else if (ddrr_busy) begin
        if (ddrr_cnt==0) begin
          cl_t cl; cl = store.exists(ddrr_addr) ? store[ddrr_addr] : zero_def;
          ddrr_a<=cl.a; ddrr_m<=cl.m; ddrr_s<=cl.s; ddrr_d<=cl.d; ddrr_c<=cl.c; ddrr_v<=1; ddrr_busy<=0;
        end else ddrr_cnt<=ddrr_cnt-1;
      end
    end
  end

  // ---- 辅助 ----
  function automatic logic [LA_ADDR_W-1:0] mk(input int tg); // index 0
    return {TAG_W'(tg), {IDX_W{1'b0}}, {OFFSET_W{1'b0}}};
  endfunction
  task automatic drive(input logic wr, input logic [LA_ADDR_W-1:0] a, input logic [LINE_BITS-1:0] wd);
    @(posedge clk); req_v<=1; req_wr<=wr; req_a<=a; req_p<=PATH_NORMAL; req_wd<=wd; req_ws<={LINE_BYTES{wr}}; req_o<='0;
    @(posedge clk); req_v<=0;
  endtask
  // write-miss:write-allocate(fill)→ 重发写(write-hit 置 dirty)
  task automatic wmiss(input logic [LA_ADDR_W-1:0] a, input logic [LINE_BITS-1:0] wd);
    drive(1,a,wd); wait(mshr_busy); wait(!mshr_busy); repeat(2)@(posedge clk);
    drive(1,a,wd); repeat(5)@(posedge clk);   // 重发 → write-hit
  endtask
  // read-miss:fill 后重读取数据
  task automatic rmiss(input logic [LA_ADDR_W-1:0] a, output logic [LINE_BITS-1:0] got);
    drive(0,a,'0); wait(mshr_busy); wait(!mshr_busy); repeat(2)@(posedge clk);
    drive(0,a,'0); wait(rsp_v); got=rsp_d; repeat(2)@(posedge clk);
  endtask
  // thrash read(只为制造 miss/evict,不取数据)
  task automatic tread(input logic [LA_ADDR_W-1:0] a);
    drive(0,a,'0); wait(mshr_busy); wait(!mshr_busy); repeat(2)@(posedge clk);
  endtask

  integer fails;
  logic [LINE_BITS-1:0] PX, got;
  initial begin
    fails=0; req_v=0;
    zero_def = '{ALGO_ZERO, 3'd0, 7'd1, '0, 8'hC4};   // 零行压缩(crc8(0x00)=0xC4)
    rst_n=0; repeat(5)@(posedge clk); rst_n=1; repeat(3)@(posedge clk);

    PX = {16{32'h0000_1234}};       // 写入 X(tag=50)的数据(BDI 单值可压)

    // 1) write-miss X → write-allocate → 写入(dirty)
    wmiss(mk(50), PX);

    // 2) thrash 同 set(index0)其他 tag,迫使 X 被 evict(脏→压缩写回 DDR)
    for (int j=1;j<=8;j++) tread(mk(50+j));

    // 3) 断言 X 已写回 DDR(evict-压缩 发生)
    if (!store.exists(mk(50))) begin fails++; $display("WB FAIL: X 未写回 DDR(evict 未发生)"); end

    // 4) read X(miss)→ 从压缩 DDR 取 → 解压 → 应得 PX
    rmiss(mk(50), got);
    if (got !== PX) begin fails++; $display("WB FAIL: read X got=%h exp=%h", got, PX); end

    if (fails==0) $display("tb_sub_wb: ALL PASS");
    else          $display("tb_sub_wb: %0d FAIL", fails);
    $finish;
  end
  // 监视器
  always @(posedge clk) if (rst_n && m_alloc)
    $display("[%0t] ALLOC isw=%0d tag=%0d vway=%0d vvalid=%0d vdirty=%0d vtag=%0d",
             $time, m_isw, m_addr>>(OFFSET_W+IDX_W), m_vway, m_vvalid, m_vdirty, m_vtag);
  always @(posedge clk) if (rst_n && ddrw_req && !ddrw_busy)
    $display("[%0t] EVICT-WR tag=%0d algo=%0d size=%0d", $time, ddrw_addr>>(OFFSET_W+IDX_W), ddrw_a, ddrw_s);

  initial begin #80us; $display("tb_sub_wb: TIMEOUT"); $finish; end
endmodule
`default_nettype wire
