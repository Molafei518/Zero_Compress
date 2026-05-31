// ============================================================================
// resp_merge.sv — 响应合并 + Reorder Buffer + AXI R/B 成帧
//   设计文档:docs/rtl/31_resp_merge.md   架构:§4.1 / §8.7
//   骨架:端口冻结 + ROB 框架;成帧/抽取/保序 TODO。
// ============================================================================
`default_nettype none

module resp_merge
  import zc_pkg::*;
#(
  parameter int unsigned ROB_DEPTH = 16
) (
  input  wire                   clk,
  input  wire                   rst_n,

  // 上游响应入(pipe/mshr/reloc 汇聚)
  input  wire                   i_resp_valid,
  output logic                  o_resp_ready,
  input  wire [AXI_ID_W-1:0]    i_resp_id,
  input  wire                   i_resp_is_write,
  input  wire [LINE_BITS-1:0]   i_resp_data,
  input  wire [OFFSET_W-1:0]    i_resp_offset,
  input  wire [1:0]             i_resp_code,

  // burst 上下文登记(来自 req_buffer)
  input  wire                   i_ctx_push,
  input  wire [AXI_ID_W-1:0]    i_ctx_id,
  input  wire [7:0]             i_ctx_len,
  input  wire [2:0]             i_ctx_size,
  input  wire                   i_ctx_first,
  input  wire                   i_ctx_last,

  input  wire                   i_oom_tripped,

  // 上游 AXI R
  output logic                  o_rvalid,
  input  wire                   i_rready,
  output logic [AXI_ID_W-1:0]   o_rid,
  output logic [AXI_DATA_W-1:0] o_rdata,
  output logic [1:0]            o_rresp,
  output logic                  o_rlast,
  // 上游 AXI B
  output logic                  o_bvalid,
  input  wire                   i_bready,
  output logic [AXI_ID_W-1:0]   o_bid,
  output logic [1:0]            o_bresp
);
  localparam logic [1:0] RESP_OKAY = 2'b00, RESP_SLVERR = 2'b10;

  // ROB(行为级占位)
  typedef struct packed {
    logic                 valid;
    logic [AXI_ID_W-1:0]  id;
    logic                 is_write;
    logic [1:0]           code;
    logic [LINE_BITS-1:0] data;
  } rob_e_t;

  // ==========================================================================
  // 单 line 功能版:一笔响应 = 一个 64B 行 → 读发 BEATS_PER_LINE 个 R beat / 写发 B。
  //   多 outstanding 重排(ROB)留后续(docs/rtl/31)。i_ctx_* 暂未使用。
  // ==========================================================================
  localparam int unsigned BCW = (BEATS_PER_LINE <= 1) ? 1 : $clog2(BEATS_PER_LINE);
  typedef enum logic [1:0] { RM_IDLE, RM_R, RM_B } rm_state_e;
  rm_state_e state;

  rob_e_t              cur;
  logic [BCW:0]        beat;

  assign o_resp_ready = (state == RM_IDLE);

  // R 通道
  always_comb begin
    o_rvalid = (state == RM_R);
    o_rid    = cur.id;
    o_rdata  = cur.data[beat*AXI_DATA_W +: AXI_DATA_W];
    o_rlast  = (beat == BEATS_PER_LINE-1);
    o_rresp  = (cur.code == RESP_SLVERR) ? RESP_SLVERR : RESP_OKAY;
    // B 通道
    o_bvalid = (state == RM_B);
    o_bid    = cur.id;
    o_bresp  = (cur.code == RESP_SLVERR || i_oom_tripped) ? RESP_SLVERR : RESP_OKAY;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= RM_IDLE; beat <= '0;
    end else begin
      unique case (state)
        RM_IDLE: if (i_resp_valid) begin
          cur.id<=i_resp_id; cur.is_write<=i_resp_is_write;
          cur.code<=i_resp_code; cur.data<=i_resp_data;
          beat <= '0;
          state <= i_resp_is_write ? RM_B : RM_R;
        end
        RM_R: if (i_rready) begin
          if (beat == BEATS_PER_LINE-1) state <= RM_IDLE;
          else beat <= beat + 1'b1;
        end
        RM_B: if (i_bready) state <= RM_IDLE;
        default: state <= RM_IDLE;
      endcase
    end
  end
endmodule : resp_merge

`default_nettype wire
