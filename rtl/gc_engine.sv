// ============================================================================
// gc_engine.sv — 后台 GC(Hole/Compaction/Defrag),限速 + 可被业务抢占
//   设计文档:docs/rtl/21_gc_engine.md   架构:§7.4
//   骨架:扫描 FSM 框架 + 令牌桶占位;GC Bitmap 访问与选页 TODO。
// ============================================================================
`default_nettype none

module gc_engine
  import zc_pkg::*;
(
  input  wire                   clk,
  input  wire                   rst_n,
  input  wire                   i_gc_en,
  input  waterlevel_e           i_waterlevel,
  input  wire                   i_alloc_shortage,
  input  wire                   i_explicit_req,
  input  wire [4:0]             i_bw_limit_pct,

  // GC Bitmap(每页 hole_ratio[3:0])抽象口
  output logic                  o_gc_bitmap_rd,
  output logic [LA_PAGE_W-1:0]  o_gc_bitmap_page,
  input  wire [3:0]             i_gc_bitmap_hole,

  // 触发 page_reloc
  output reloc_trig_e           o_reloc_trig,
  output logic [LA_PAGE_W-1:0]  o_reloc_page,
  input  wire                   i_reloc_busy,
  input  wire                   i_reloc_done,

  output logic                  o_gc_done_pulse,
  output logic [31:0]           o_bw_used
);
  typedef enum logic [2:0] { G_IDLE, G_SCAN, G_SELECT, G_WAIT, G_THROTTLE } gc_state_e;
  gc_state_e state, state_n;

  logic [LA_PAGE_W-1:0] scan_page;
  logic [15:0]          token;       // 令牌桶(限速)

  wire start = i_gc_en & ((i_waterlevel == WL_SOFT_LOW) | i_alloc_shortage | i_explicit_req);

  always_comb begin
    state_n        = state;
    o_reloc_trig   = RTRIG_NONE;
    o_reloc_page   = scan_page;
    o_gc_bitmap_rd = 1'b0;
    o_gc_done_pulse= 1'b0;
    unique case (state)
      G_IDLE:    if (start) state_n = G_SCAN;
      G_SCAN: begin
        o_gc_bitmap_rd = 1'b1;
        // TODO: 遍历页,找 hole_ratio>=4;扫完一轮 → done
        state_n = G_SELECT;
      end
      G_SELECT: begin
        // TODO: 选 Compaction(hole≥4)或 Defrag(shortage)
        o_reloc_trig = i_alloc_shortage ? RTRIG_GC_DEFRAG : RTRIG_GC_COMPACT;
        state_n = G_WAIT;
      end
      G_WAIT:    if (i_reloc_done) state_n = (token == 0) ? G_THROTTLE : G_SCAN;
      G_THROTTLE:if (token != 0)   state_n = G_SCAN;   // 令牌恢复后继续
      default:   state_n = G_IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= G_IDLE; scan_page <= '0; token <= '0; o_bw_used <= '0;
    end else begin
      state <= state_n;
      // TODO: 令牌桶按 i_bw_limit_pct 充值/消耗;scan_page 推进;o_bw_used 累计
    end
  end
endmodule : gc_engine

`default_nettype wire
