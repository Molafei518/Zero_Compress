// ============================================================================
// page_reloc.sv — 整页重定位 9 状态 FSM
//   设计文档:docs/rtl/22_page_reloc.md + docs/03_page_reloc_fsm.md(FSM/抢占/异常)
//   架构:§7.3 / §8.4。骨架:FSM 框架 + 触发仲裁;数据通路/抢占/异常回滚 TODO。
// ============================================================================
`default_nettype none

module page_reloc
  import zc_pkg::*;
(
  input  wire                   clk,
  input  wire                   rst_n,

  // 触发
  input  reloc_trig_e           i_trig,
  input  wire [LA_PAGE_W-1:0]   i_trig_page,
  output logic                  o_busy,
  output reloc_state_e          o_state,
  output logic                  o_done_pulse,

  // MSHR 阻塞 + 抢占
  output logic                  o_block_la_valid,
  output logic [LA_PAGE_W-1:0]  o_block_la_page,
  input  wire                   i_master_req_other_la,

  // L2P 写
  output logic                  o_l2p_wr,
  output logic [LA_PAGE_W-1:0]  o_l2p_page,
  output l2p_entry_t            o_l2p_entry,
  input  wire                   i_l2p_ack,

  // compress / decompress(借用)
  output logic                  o_comp_req,
  output logic [LINE_BITS-1:0]  o_comp_in,
  input  wire                   i_comp_done,
  input  algo_e                 i_comp_algo,
  input  wire [6:0]             i_comp_size,
  output logic                  o_decomp_req,
  input  wire                   i_decomp_done,
  input  wire [LINE_BITS-1:0]   i_decomp_out,
  input  wire                   i_decomp_crc_err,

  // space_alloc
  output logic                  o_alloc_req,
  output logic [12:0]           o_alloc_size,
  input  wire                   i_alloc_ack,
  input  wire                   i_alloc_fail,
  input  wire [31:0]            i_alloc_ppa,
  output logic                  o_free_req,
  output logic [31:0]           o_free_ppa,

  // 下游 DDR
  output logic                  o_ddr_rd_req,
  output logic [DPA_ADDR_W-1:0] o_ddr_rd_addr,
  input  wire                   i_ddr_rd_done,
  input  wire [LINE_BITS-1:0]   i_ddr_rd_data,
  output logic                  o_ddr_wr_req,
  output logic [DPA_ADDR_W-1:0] o_ddr_wr_addr,
  output logic [LINE_BITS-1:0]  o_ddr_wr_data,
  input  wire                   i_ddr_wr_done,

  // 异常
  output logic                  o_irq_decomp_err,
  output logic                  o_irq_hard_full,
  output logic                  o_bad_page,
  output logic [LA_PAGE_W-1:0]  o_bad_page_la
);
  reloc_state_e state, state_n;
  logic [LA_PAGE_W-1:0] cur_page;
  reloc_trig_e          cur_trig;
  logic [31:0]          generation;

  assign o_state = state;
  assign o_busy  = (state != S_RELOC_IDLE);
  assign o_block_la_valid = o_busy;
  assign o_block_la_page  = cur_page;

  // 仅 GC 触发可被业务抢占(文档 03 §5.3)
  wire is_gc_trig   = (cur_trig == RTRIG_GC_COMPACT) || (cur_trig == RTRIG_GC_DEFRAG);
  wire preempt_here = is_gc_trig & i_master_req_other_la;

  // 4KB scratch(解压后整页);reloc_pending_fifo;block 表 —— TODO 实例化
  // logic [LINE_BITS-1:0] scratch [LINES_PER_PAGE];

  always_comb begin
    state_n = state;
    unique case (state)
      S_RELOC_IDLE:          if (i_trig != RTRIG_NONE) state_n = S_RELOC_LOCK;
      S_RELOC_LOCK:          state_n = S_RELOC_COLLECT_PLAN;        // 原子,不可抢占
      S_RELOC_COLLECT_PLAN:  state_n = S_RELOC_COLLECT_FETCH;
      S_RELOC_COLLECT_FETCH: if (/*all fetched*/1'b1 && !preempt_here) state_n = S_RELOC_RECOMP;
      S_RELOC_RECOMP:        if (/*all 64 compressed*/1'b1) state_n = S_RELOC_ALLOC;
      S_RELOC_ALLOC:         if (i_alloc_ack) state_n = S_RELOC_WRITE_NEW;   // fail→停此+IRQ
                             // 不可抢占
      S_RELOC_WRITE_NEW:     if (i_ddr_wr_done) state_n = S_RELOC_COMMIT;    // 已开写不可抢占
      S_RELOC_COMMIT:        if (i_l2p_ack) state_n = S_RELOC_DONE;          // 原子
      S_RELOC_DONE:          state_n = S_RELOC_IDLE;
      default:               state_n = S_RELOC_IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_RELOC_IDLE; generation <= '0;
    end else begin
      state <= state_n;
      if (state == S_RELOC_IDLE && i_trig != RTRIG_NONE) begin
        cur_page <= i_trig_page; cur_trig <= i_trig;
      end
      if (state == S_RELOC_LOCK) generation <= generation + 1'b1; // ABA 检测
      // TODO: 各状态数据通路;异常(decomp_crc_err/alloc_fail/ddr_err/l2p_err)回滚(03 §8)
    end
  end

  // ---- 输出默认(骨架)----
  always_comb begin
    o_done_pulse = (state == S_RELOC_DONE);
    o_l2p_wr=1'b0; o_l2p_page=cur_page; o_l2p_entry='0;
    o_comp_req=1'b0; o_comp_in='0; o_decomp_req=1'b0;
    o_alloc_req=(state==S_RELOC_ALLOC); o_alloc_size='0;
    o_free_req=1'b0; o_free_ppa='0;
    o_ddr_rd_req=1'b0; o_ddr_rd_addr='0; o_ddr_wr_req=1'b0; o_ddr_wr_addr='0; o_ddr_wr_data='0;
    o_irq_decomp_err = i_decomp_crc_err;     // §10.7 禁静默零填充
    o_irq_hard_full  = (state==S_RELOC_ALLOC) & i_alloc_fail;
    o_bad_page=1'b0; o_bad_page_la=cur_page;
    // TODO: 各状态精确驱动
  end
endmodule : page_reloc

`default_nettype wire
