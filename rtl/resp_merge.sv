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
  rob_e_t rob [ROB_DEPTH];

  assign o_resp_ready = 1'b1; // TODO: ROB 满则反压

  // TODO: 入 ROB(按 id+子序);按 burst 顺序拆 beat 发 R;收齐发 B;SLVERR 注入
  always_comb begin
    o_rvalid=1'b0; o_rid='0; o_rdata='0; o_rlast=1'b0;
    o_rresp = (i_resp_code==RESP_SLVERR) ? RESP_SLVERR : RESP_OKAY;
    o_bvalid=1'b0; o_bid='0;
    o_bresp = (i_oom_tripped) ? RESP_SLVERR : RESP_OKAY;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      for (int i=0;i<ROB_DEPTH;i++) rob[i].valid <= 1'b0;
    else begin
      // TODO: push/pop ROB
      if (i_ctx_push) begin /* 登记 burst 上下文 */ end
    end
  end
endmodule : resp_merge

`default_nettype wire
