// ============================================================================
// req_buffer.sv — 上游 AXI 请求缓冲 + burst 拆分(每 64B 行一个子请求)
//
//   设计文档:docs/rtl/01_req_buffer.md   架构:§4.1 / §8.7 / §9.1
//   端口冻结骨架:skid/W-FIFO/splitter FSM 的内部逻辑以 TODO 标记。
// ============================================================================
`default_nettype none

module req_buffer
  import zc_pkg::*;
(
  input  wire                   clk,
  input  wire                   rst_n,

  // ---- 上游 AXI4(IP=slave)。此处展平关键信号,便于骨架;
  //      集成时可改接 zc_axi_if.slave。 ----
  input  wire                   s_arvalid,
  output logic                  s_arready,
  input  wire [AXI_ID_W-1:0]    s_arid,
  input  wire [LA_ADDR_W-1:0]   s_araddr,
  input  wire [7:0]             s_arlen,
  input  wire [2:0]             s_arsize,
  input  wire [1:0]             s_arburst,
  input  wire [3:0]             s_arcache,
  input  wire [2:0]             s_arprot,

  input  wire                   s_awvalid,
  output logic                  s_awready,
  input  wire [AXI_ID_W-1:0]    s_awid,
  input  wire [LA_ADDR_W-1:0]   s_awaddr,
  input  wire [7:0]             s_awlen,
  input  wire [2:0]             s_awsize,
  input  wire [3:0]             s_awcache,
  input  wire [2:0]             s_awprot,

  input  wire                   s_wvalid,
  output logic                  s_wready,
  input  wire [AXI_DATA_W-1:0]  s_wdata,
  input  wire [AXI_DATA_W/8-1:0] s_wstrb,
  input  wire                   s_wlast,

  // ---- (A) → addr_decode ----
  output logic                  o_req_valid,
  input  wire                   i_req_ready,
  output logic [LA_ADDR_W-1:0]  o_addr,
  output logic [AXI_ID_W-1:0]   o_id,
  output logic                  o_is_write,
  output logic [7:0]            o_len,
  output logic [2:0]            o_prot,
  output logic [3:0]            o_cache,
  output logic [LINE_BITS-1:0]  o_wdata,
  output logic [LINE_BYTES-1:0] o_wstrb,
  output logic [OFFSET_W-1:0]   o_offset,
  output logic                  o_first,
  output logic                  o_last
);

  // ==========================================================================
  // burst 拆分 FSM
  // ==========================================================================
  typedef enum logic [1:0] { S_IDLE, S_SPLIT_RD, S_SPLIT_WR } split_state_e;
  split_state_e state, state_n;

  logic [LA_ADDR_W-1:0] cur_addr;       // 当前子请求行地址
  logic [8:0]           lines_left;     // 还剩多少行
  logic [AXI_ID_W-1:0]  cur_id;
  logic [7:0]           cur_len;
  logic [2:0]           cur_prot;
  logic [3:0]           cur_cache;

  // 计算一个 burst 覆盖多少个 64B 行(TODO: 精确按 addr+size*len 跨行数)
  // function automatic [8:0] burst_n_lines(input [LA_ADDR_W-1:0] a,
  //                                         input [7:0] len, input [2:0] size);

  // ==========================================================================
  // W 数据组装:BEATS_PER_LINE 个 beat 拼成一个 512b line(TODO)
  // ==========================================================================
  // logic [LINE_BITS-1:0]  w_line;  logic [LINE_BYTES-1:0] w_line_strb;
  // logic [$clog2(BEATS_PER_LINE):0] beat_cnt;

  // ==========================================================================
  // 控制(骨架)
  // ==========================================================================
  always_comb begin
    state_n   = state;
    s_arready = 1'b0;
    s_awready = 1'b0;
    s_wready  = 1'b0;
    o_req_valid = 1'b0;
    unique case (state)
      S_IDLE: begin
        // 读优先级 > 写(可配);收下后进入拆分
        s_arready = 1'b1;
        s_awready = ~s_arvalid; // 简化:同拍只收一类
        if (s_arvalid)      state_n = S_SPLIT_RD;
        else if (s_awvalid) state_n = S_SPLIT_WR;
      end
      S_SPLIT_RD: begin
        o_req_valid = 1'b1;
        if (i_req_ready && lines_left == 9'd1) state_n = S_IDLE;
      end
      S_SPLIT_WR: begin
        // 需 W FIFO 攒够一行再发(TODO)
        o_req_valid = 1'b1; // 占位
        if (i_req_ready && lines_left == 9'd1) state_n = S_IDLE;
      end
      default: state_n = S_IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      lines_left <= '0;
      cur_addr   <= '0;
    end else begin
      state <= state_n;
      // TODO: 锁存 id/len/prot/cache;首拍算 lines_left 与 cur_addr;
      //       每发一个子请求 cur_addr += LINE_BYTES; lines_left--;
    end
  end

  // 子请求 payload(骨架)
  always_comb begin
    o_addr     = cur_addr;
    o_id       = cur_id;
    o_is_write = (state == S_SPLIT_WR);
    o_len      = cur_len;
    o_prot     = cur_prot;
    o_cache    = cur_cache;
    o_wdata    = '0;   // TODO: w_line
    o_wstrb    = '0;   // TODO: w_line_strb(读时全 0)
    o_offset   = cur_addr[OFFSET_W-1:0];
    o_first    = 1'b0; // TODO
    o_last     = (lines_left == 9'd1);
  end

endmodule : req_buffer

`default_nettype wire
