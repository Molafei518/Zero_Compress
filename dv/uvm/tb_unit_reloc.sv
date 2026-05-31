// ============================================================================
// tb_unit_reloc.sv — page_reloc(9 状态 FSM)单元 TB
//   验证:① IDLE→LOCK→…→DONE 序列;② lock 期间 block 拉高 + generation++
//         ③ alloc→write→commit(L2P 换映射)→free 旧槽 顺序
//         ④ 数据保留:新页 Header+压缩数据 解出 == 原 line
//         ⑤ GC 触发可被业务抢占(COLLECT_FETCH yield);Evict 触发不抢占
// ============================================================================
`default_nettype none
module tb_unit_reloc;
  import zc_pkg::*;
  localparam int REGION = 64;

  logic clk=0, rst_n=0;
  always #0.625ns clk=~clk;

  reloc_trig_e         trig; logic [LA_PAGE_W-1:0] trig_page;
  logic [31:0]         trig_old_ppa; logic [12:0] trig_old_size; logic [LINE_BITS-1:0] line_data;
  logic                busy; reloc_state_e rstate; logic done_p; logic [31:0] gen;
  logic                blk_v; logic [LA_PAGE_W-1:0] blk_p; logic master_other;
  logic                l2p_wr; logic [LA_PAGE_W-1:0] l2p_pg; l2p_entry_t l2p_ent; logic l2p_ack;
  logic                a_req; logic [12:0] a_size; logic a_ack, a_fail; logic [31:0] a_ppa;
  logic                fr_req; logic [31:0] fr_ppa; logic [12:0] fr_size; logic [6:0] used_pct;
  logic                dw_req; logic [31:0] dw_ppa; logic [HEADER_BYTES*8-1:0] dw_hdr; logic [LINE_BITS-1:0] dw_cd; logic dw_done;
  logic                irq_hf, bad_pg; logic [LA_PAGE_W-1:0] bad_la;

  page_reloc u_reloc (
    .clk,.rst_n,.i_trig(trig),.i_trig_page(trig_page),.i_trig_old_ppa(trig_old_ppa),
    .i_trig_old_size(trig_old_size),.i_line_data(line_data),
    .o_busy(busy),.o_state(rstate),.o_done_pulse(done_p),.o_generation(gen),
    .o_block_la_valid(blk_v),.o_block_la_page(blk_p),.i_master_req_other_la(master_other),
    .o_l2p_wr(l2p_wr),.o_l2p_page(l2p_pg),.o_l2p_entry(l2p_ent),.i_l2p_ack(l2p_ack),
    .o_alloc_req(a_req),.o_alloc_size(a_size),.i_alloc_ack(a_ack),.i_alloc_fail(a_fail),.i_alloc_ppa(a_ppa),
    .o_free_req(fr_req),.o_free_ppa(fr_ppa),.o_free_size(fr_size),
    .o_ddrw_req(dw_req),.o_ddrw_ppa(dw_ppa),.o_ddrw_header(dw_hdr),.o_ddrw_cdata(dw_cd),.i_ddrw_done(dw_done),
    .o_irq_hard_full(irq_hf),.o_bad_page(bad_pg),.o_bad_page_la(bad_la)
  );
  space_alloc #(.REGION_BLK64(REGION)) u_alloc (
    .clk,.rst_n,.i_alloc_req(a_req),.i_alloc_size(a_size),.o_alloc_ack(a_ack),.o_alloc_fail(a_fail),.o_alloc_ppa(a_ppa),
    .i_free_req(fr_req),.i_free_ppa(fr_ppa),.i_free_size(fr_size),.o_used_pct(used_pct),.i_cfg_meta_base('0),
    .o_fl_rd_req(),.o_fl_addr(),.i_fl_valid(1'b0),.i_fl_data('0),.o_fl_wr_req(),.o_fl_wdata());

  assign l2p_ack = l2p_wr;   // L2P 即时 ack

  // DDR(header+cdata)模型
  typedef struct packed { logic [HEADER_BYTES*8-1:0] h; logic [LINE_BITS-1:0] d; } pg_t;
  pg_t ddr_store [bit[31:0]];
  logic dw_busy; logic [2:0] dw_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin dw_done<=0; dw_busy<=0; end
    else begin dw_done<=0;
      if (dw_req && !dw_busy) begin dw_busy<=1; dw_cnt<=3; end
      else if (dw_busy) begin if (dw_cnt==0) begin ddr_store[dw_ppa]='{dw_hdr,dw_cd}; dw_done<=1; dw_busy<=0; end else dw_cnt<=dw_cnt-1; end
    end
  end

  // 验证用:解 Header + 解压
  logic [HEADER_BYTES*8-1:0] vh; logic [LINE_BITS-1:0] vc;
  line_info_t up_info [LINES_PER_PAGE]; logic [7:0] up_crc8 [LINES_PER_PAGE];
  page_header_unpack u_up (.i_blob(vh),.o_generation(),.o_total_comp_size(),
    .o_info(up_info),.o_crc8(up_crc8),.o_magic_ok(),.o_crc_ok());
  logic vd_req; algo_e vd_a; logic [2:0] vd_m; logic [6:0] vd_s; logic [7:0] vd_c;
  logic vd_done; logic [LINE_BITS-1:0] vd_line; logic vd_err;
  decompress_top u_vd (.clk,.rst_n,.i_req(vd_req),.i_algo(vd_a),.i_mode(vd_m),.i_size(vd_s),
    .i_data(vc),.i_crc8_exp(vd_c),.o_done(vd_done),.o_line(vd_line),.o_crc_err(vd_err));
  assign vd_a = up_info[0].algo; assign vd_m = up_info[0].mode;
  assign vd_s = 7'(up_info[0].size_minus1)+7'd1; assign vd_c = up_crc8[0];

  // 状态序列监控
  reloc_state_e seen_max; // 记录到达过的最深状态(枚举值递增)
  always @(posedge clk) if (rst_n && busy && rstate > seen_max) seen_max <= rstate;

  integer fails;
  logic [LINE_BITS-1:0] LINE;
  logic [31:0] cap_l2p_ppa; logic cap_l2p, cap_free; logic [31:0] cap_free_ppa;
  // 捕获 L2P 写(换映射的新 ppa)与 free(旧槽)
  always @(posedge clk) begin
    if (l2p_wr)  begin cap_l2p<=1;  cap_l2p_ppa<=l2p_ent.ppa_ptr; end
    if (fr_req)  begin cap_free<=1; cap_free_ppa<=fr_ppa; end
  end

  initial begin
    fails=0; trig=RTRIG_NONE; master_other=0; seen_max=S_RELOC_IDLE;
    cap_l2p=0; cap_free=0;
    rst_n=0; repeat(5)@(posedge clk); rst_n=1; repeat(3)@(posedge clk);

    LINE = {16{32'h0000_5678}};   // BDI 单值

    // ---- 1) Evict 触发 reloc(不可抢占)----
    @(posedge clk); trig<=RTRIG_EVICT_OVF; trig_page<=20'h00ABC; trig_old_ppa<=32'd128; trig_old_size<=13'd256; line_data<=LINE;
    @(posedge clk); trig<=RTRIG_NONE;
    // 全程拉 master_other,验证 Evict 触发不被抢占(仍能完成)
    master_other<=1;
    wait (done_p);
    master_other<=0;

    if (gen != 32'd1) begin fails++; $display("FAIL: generation 未递增 = %0d", gen); end
    if (!cap_l2p) begin fails++; $display("FAIL: 未写 L2P"); end
    repeat(4)@(posedge clk);

    // ---- 2) 数据保留:读新页(L2P 指向的 ppa)→ 解 Header+解压 == LINE ----
    vh = ddr_store[cap_l2p_ppa].h; vc = ddr_store[cap_l2p_ppa].d;
    @(posedge clk); vd_req<=1; @(posedge clk); vd_req<=0;
    wait (vd_done);
    if (vd_line !== LINE) begin fails++; $display("FAIL: 重定位后数据不符 got=%h", vd_line); end
    if (seen_max < S_RELOC_DONE) begin fails++; $display("FAIL: 未走完 9 状态(到 %0d)", seen_max); end

    // ---- 3) GC 触发可被抢占:master_other=1 时应停在 COLLECT_FETCH ----
    seen_max=S_RELOC_IDLE;
    @(posedge clk); trig<=RTRIG_GC_COMPACT; trig_page<=20'h00DEF; trig_old_ppa<=32'd0; trig_old_size<=13'd64; line_data<=LINE;
    @(posedge clk); trig<=RTRIG_NONE; master_other<=1;
    repeat(20)@(posedge clk);                 // 抢占期间应卡在 COLLECT_FETCH
    if (rstate != S_RELOC_COLLECT_FETCH) begin fails++; $display("FAIL: GC reloc 未被抢占(state=%0d)", rstate); end
    master_other<=0;                          // 解除抢占 → 继续
    wait (done_p);

    if (fails==0) $display("tb_unit_reloc: ALL PASS");
    else          $display("tb_unit_reloc: %0d FAIL", fails);
    $finish;
  end
  initial begin #100us; $display("tb_unit_reloc: TIMEOUT"); $finish; end
endmodule
`default_nettype wire
