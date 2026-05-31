// ============================================================================
// page_reloc.sv — 整页重定位 9 状态 FSM(自包含:内含 compress_top + page_header_pack)
//   设计文档:docs/rtl/22_page_reloc.md + docs/03_page_reloc_fsm.md;架构 §7.3 / §8.4
//   触发场景(§3.4 Case B):写覆盖后压缩 size 超出当前 PPA 槽 → 整页搬到新槽。
//   流程(doc 03):IDLE→LOCK(锁页+generation++)→COLLECT_PLAN→COLLECT_FETCH
//                 →RECOMP(重压缩)→ALLOC(新槽)→WRITE_NEW(写新页)→COMMIT(原子换 L2P)
//                 →DONE(解锁+释放旧槽)
//   抢占:仅 GC 触发可被业务请求抢占(在可抢占状态 yield);Evict/Write/Repair 不抢占。
//   简化:单行/页(line 数据由触发方提供 —— 已在 Cache 解压态,§S_COLLECT);
//         64 行版把 RECOMP/WRITE_NEW 扩为循环 + 4KB scratch(留后续)。
//   端口较骨架修订:加 old_ppa/old_size/line_data,DDR 写改 Header+cdata 宽口,
//                   compress/decompress 改为内部例化(自包含)。
// ============================================================================
`default_nettype none

module page_reloc
  import zc_pkg::*;
(
  input  wire                   clk,
  input  wire                   rst_n,

  // 触发(trig 源提供旧位置 + 已在 Cache 的解压 line 数据)
  input  wire reloc_trig_e      i_trig,
  input  wire [LA_PAGE_W-1:0]   i_trig_page,
  input  wire [31:0]            i_trig_old_ppa,
  input  wire [12:0]            i_trig_old_size,
  input  wire [LINE_BITS-1:0]   i_line_data,
  output logic                  o_busy,
  output reloc_state_e          o_state,
  output logic                  o_done_pulse,
  output logic [31:0]           o_generation,

  // MSHR 阻塞 + 抢占
  output logic                  o_block_la_valid,
  output logic [LA_PAGE_W-1:0]  o_block_la_page,
  input  wire                   i_master_req_other_la,

  // L2P 写(原子换映射)
  output logic                  o_l2p_wr,
  output logic [LA_PAGE_W-1:0]  o_l2p_page,
  output l2p_entry_t            o_l2p_entry,
  input  wire                   i_l2p_ack,

  // space_alloc
  output logic                  o_alloc_req,
  output logic [12:0]           o_alloc_size,
  input  wire                   i_alloc_ack,
  input  wire                   i_alloc_fail,
  input  wire [31:0]            i_alloc_ppa,
  output logic                  o_free_req,
  output logic [31:0]           o_free_ppa,
  output logic [12:0]           o_free_size,

  // DDR 写(新页:Header + 压缩数据)
  output logic                  o_ddrw_req,
  output logic [31:0]           o_ddrw_ppa,
  output logic [HEADER_BYTES*8-1:0] o_ddrw_header,
  output logic [LINE_BITS-1:0]  o_ddrw_cdata,
  input  wire                   i_ddrw_done,

  // 异常
  output logic                  o_irq_hard_full,
  output logic                  o_bad_page,
  output logic [LA_PAGE_W-1:0]  o_bad_page_la
);
  reloc_state_e state;
  logic [LA_PAGE_W-1:0] cur_page;
  reloc_trig_e          cur_trig;
  logic [31:0]          generation;
  logic [31:0]          old_ppa_q; logic [12:0] old_size_q;
  logic [LINE_BITS-1:0] line_q;
  logic [31:0]          new_ppa_q;
  // 重压缩结果
  algo_e                rca_q; logic [2:0] rcm_q; logic [6:0] rcs_q;
  logic [LINE_BITS-1:0] rcd_q; logic [7:0] rcc_q;

  wire [12:0] footprint = 13'(HEADER_BYTES) + 13'(rcs_q);

  // 内部 compress(RECOMP)
  logic                 cmp_req; logic cmp_done;
  algo_e cmp_a; logic [2:0] cmp_m; logic [6:0] cmp_s; logic [LINE_BITS-1:0] cmp_d; logic [7:0] cmp_c;
  compress_top u_cmp (.clk,.rst_n,.i_req(cmp_req),.i_line(line_q),.o_done(cmp_done),
    .o_algo(cmp_a),.o_mode(cmp_m),.o_size(cmp_s),.o_data(cmp_d),.o_crc8(cmp_c));

  // 内部 Page Header 打包
  line_info_t pk_info [LINES_PER_PAGE]; logic [7:0] pk_crc8 [LINES_PER_PAGE];
  always_comb begin
    for (int i=0;i<LINES_PER_PAGE;i++) begin
      pk_info[i]='{size_minus1:6'd0,mode:3'd0,algo:ALGO_ZERO}; pk_crc8[i]=8'd0;
    end
    pk_info[0]='{size_minus1:6'(rcs_q-7'd1),mode:rcm_q,algo:rca_q}; pk_crc8[0]=rcc_q;
  end
  logic [HEADER_BYTES*8-1:0] new_header;
  page_header_pack u_pack (.i_generation(generation), .i_total_comp_size(16'(rcs_q)),
                           .i_info(pk_info), .i_crc8(pk_crc8), .o_blob(new_header));

  assign o_state          = state;
  assign o_busy           = (state != S_RELOC_IDLE);
  assign o_block_la_valid = o_busy;
  assign o_block_la_page  = cur_page;
  assign o_generation     = generation;

  // 仅 GC 触发可被业务抢占(doc 03 §5.3)
  wire is_gc_trig   = (cur_trig == RTRIG_GC_COMPACT) || (cur_trig == RTRIG_GC_DEFRAG);
  wire preempt_here = is_gc_trig & i_master_req_other_la;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_RELOC_IDLE; generation <= '0;
    end else begin
      unique case (state)
        S_RELOC_IDLE: if (i_trig != RTRIG_NONE) begin
          cur_page<=i_trig_page; cur_trig<=i_trig;
          old_ppa_q<=i_trig_old_ppa; old_size_q<=i_trig_old_size; line_q<=i_line_data;
          state<=S_RELOC_LOCK;
        end
        S_RELOC_LOCK:         begin generation<=generation+1'b1; state<=S_RELOC_COLLECT_PLAN; end // 原子,不可抢占
        S_RELOC_COLLECT_PLAN: state<=S_RELOC_COLLECT_FETCH;
        S_RELOC_COLLECT_FETCH:if (!preempt_here) state<=S_RELOC_RECOMP;   // 单行:数据已就位;GC 可抢占→yield
        S_RELOC_RECOMP:       if (cmp_done) begin
                                rca_q<=cmp_a; rcm_q<=cmp_m; rcs_q<=cmp_s; rcd_q<=cmp_d; rcc_q<=cmp_c;
                                state<=S_RELOC_ALLOC;
                              end
        S_RELOC_ALLOC:        if (i_alloc_ack) begin new_ppa_q<=i_alloc_ppa; state<=S_RELOC_WRITE_NEW; end
                              // i_alloc_fail → IRQ_HARD_FULL(组合输出),停在本态等空间
        S_RELOC_WRITE_NEW:    if (i_ddrw_done) state<=S_RELOC_COMMIT;     // 已开写不可抢占
        S_RELOC_COMMIT:       if (i_l2p_ack) state<=S_RELOC_DONE;          // 原子换映射
        S_RELOC_DONE:         state<=S_RELOC_IDLE;                          // free 旧槽(组合,1 拍)+ 解锁
        default:              state<=S_RELOC_IDLE;
      endcase
    end
  end

  always_comb begin
    o_done_pulse = (state == S_RELOC_DONE);
    // 重压缩
    cmp_req = (state == S_RELOC_RECOMP);
    // 分配新槽
    o_alloc_req  = (state == S_RELOC_ALLOC);
    o_alloc_size = footprint;
    // 写新页(Header + 压缩数据)
    o_ddrw_req    = (state == S_RELOC_WRITE_NEW);
    o_ddrw_ppa    = new_ppa_q;
    o_ddrw_header = new_header;
    o_ddrw_cdata  = rcd_q;
    // 原子换 L2P(新 ppa + 递增 generation)
    o_l2p_wr     = (state == S_RELOC_COMMIT);
    o_l2p_page   = cur_page;
    o_l2p_entry  = '{rsvd:7'd0, algomix:8'd0, size:footprint, ppa_ptr:new_ppa_q,
                     state:ZC_COMPRESSED, valid:1'b1};
    // 释放旧槽(commit 后)
    o_free_req  = (state == S_RELOC_DONE);
    o_free_ppa  = old_ppa_q;
    o_free_size = old_size_q;
    // 异常
    o_irq_hard_full = (state == S_RELOC_ALLOC) & i_alloc_fail;
    o_bad_page    = 1'b0;
    o_bad_page_la = cur_page;
  end
endmodule : page_reloc

`default_nettype wire
