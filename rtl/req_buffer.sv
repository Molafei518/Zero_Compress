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
  // 单 line FSM(功能版):一笔事务 = 一个 64B 行(BEATS_PER_LINE 个 AXI beat)。
  //   多行 burst 拆分见 docs/rtl/01,留后续(本版假设 len = BEATS_PER_LINE-1)。
  // ==========================================================================
  typedef enum logic [1:0] { RB_IDLE, RB_RD_EMIT, RB_WR_COLLECT, RB_WR_EMIT } rb_state_e;
  rb_state_e state, state_n;

  localparam int unsigned BCW = (BEATS_PER_LINE <= 1) ? 1 : $clog2(BEATS_PER_LINE);

  logic [LA_ADDR_W-1:0] cur_addr;
  logic [AXI_ID_W-1:0]  cur_id;
  logic [7:0]           cur_len;
  logic [2:0]           cur_prot;
  logic [3:0]           cur_cache;
  logic [LINE_BITS-1:0] w_line;
  logic [LINE_BYTES-1:0] w_strb;
  logic [BCW:0]         beat_cnt;

  always_comb begin
    state_n     = state;
    s_arready   = 1'b0;
    s_awready   = 1'b0;
    s_wready    = 1'b0;
    o_req_valid = 1'b0;
    unique case (state)
      RB_IDLE: begin
        s_arready = 1'b1;
        s_awready = ~s_arvalid;            // 读优先(同拍只收一类)
        if (s_arvalid)      state_n = RB_RD_EMIT;
        else if (s_awvalid) state_n = RB_WR_COLLECT;
      end
      RB_RD_EMIT: begin
        o_req_valid = 1'b1;                // 读:直接发行请求
        if (i_req_ready) state_n = RB_IDLE;
      end
      RB_WR_COLLECT: begin
        s_wready = 1'b1;                   // 收 W beats
        if (s_wvalid && s_wlast) state_n = RB_WR_EMIT;
      end
      RB_WR_EMIT: begin
        o_req_valid = 1'b1;
        if (i_req_ready) state_n = RB_IDLE;
      end
      default: state_n = RB_IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= RB_IDLE; beat_cnt <= '0;
    end else begin
      state <= state_n;
      // 捕获 AR / AW
      if (state == RB_IDLE && s_arvalid) begin
        cur_addr<=s_araddr; cur_id<=s_arid; cur_len<=s_arlen; cur_prot<=s_arprot; cur_cache<=s_arcache;
      end else if (state == RB_IDLE && s_awvalid && !s_arvalid) begin
        cur_addr<=s_awaddr; cur_id<=s_awid; cur_len<=s_awlen; cur_prot<=s_awprot; cur_cache<=s_awcache;
        beat_cnt<='0; w_line<='0; w_strb<='0;
      end
      // 收 W beats:beat i → w_line[i*256 +: 256]
      if (state == RB_WR_COLLECT && s_wvalid) begin
        w_line[beat_cnt*AXI_DATA_W +: AXI_DATA_W] <= s_wdata;
        w_strb[beat_cnt*(AXI_DATA_W/8) +: (AXI_DATA_W/8)] <= s_wstrb;
        beat_cnt <= beat_cnt + 1'b1;
      end
    end
  end

  // 行请求 payload
  always_comb begin
    o_addr     = cur_addr;
    o_id       = cur_id;
    o_is_write = (state == RB_WR_EMIT);
    o_len      = cur_len;
    o_prot     = cur_prot;
    o_cache    = cur_cache;
    o_wdata    = w_line;
    o_wstrb    = (state == RB_WR_EMIT) ? w_strb : '0;
    o_offset   = cur_addr[OFFSET_W-1:0];
    o_first    = 1'b1;   // 单 line:既是首也是末
    o_last     = 1'b1;
  end

endmodule : req_buffer

`default_nettype wire
