// ============================================================================
// mshr_min.sv — 最小 read-miss 引擎(单条),用于 miss 链集成验证
//   流程(架构 §8.2 的读 Miss 子集):
//     pipe miss(i_alloc)→ FETCH 读 DDR 压缩行 → DECOMP 解压 → FILL 回填 cache
//   简化(留后续,见 mshr.sv 全功能 9 态 FSM):
//     - 假设 L2P 命中(地址直达;不经 l2p_meta_cache/l2p_dma)
//     - 压缩行的 {algo,mode,size,crc8} 由 DDR 模型随数据一并返回(实际取自 Page Header)
//     - 不处理 evict / write-allocate / 同地址合并 / reloc
//   CRC 错:o_irq_decomp_err(§10.7,禁静默零填充)。
// ============================================================================
`default_nettype none

module mshr_min
  import zc_pkg::*;
(
  input  wire                   clk,
  input  wire                   rst_n,

  // from cache_pipe_ctrl(miss)
  input  wire                   i_alloc,
  input  wire [LA_ADDR_W-1:0]   i_addr,
  input  wire [WAY_W-1:0]       i_victim_way,
  input  wire                   i_victim_valid,
  output logic                  o_busy,

  // to DDR 压缩页模型(读压缩行 + 元信息)
  output logic                  o_ddr_req,
  output logic [LA_ADDR_W-1:0]  o_ddr_addr,
  input  wire                   i_ddr_valid,
  input  wire algo_e            i_ddr_algo,
  input  wire [2:0]             i_ddr_mode,
  input  wire [6:0]             i_ddr_size,
  input  wire [LINE_BITS-1:0]   i_ddr_data,
  input  wire [7:0]             i_ddr_crc8,

  // to decompress_top
  output logic                  o_dec_req,
  output algo_e                 o_dec_algo,
  output logic [2:0]            o_dec_mode,
  output logic [6:0]            o_dec_size,
  output logic [LINE_BITS-1:0]  o_dec_data,
  output logic [7:0]            o_dec_crc8,
  input  wire                   i_dec_done,
  input  wire [LINE_BITS-1:0]   i_dec_line,
  input  wire                   i_dec_crc_err,

  // to cache_pipe_ctrl fill
  output logic                  o_fill_valid,
  output logic [IDX_W-1:0]      o_fill_index,
  output logic [WAY_W-1:0]      o_fill_way,
  output logic [TAG_W-1:0]      o_fill_tag,
  output logic [LINE_BITS-1:0]  o_fill_data,
  output logic                  o_fill_dirty,
  input  wire                   i_fill_ready,

  output logic                  o_irq_decomp_err
);
  typedef enum logic [2:0] { M_IDLE, M_FETCH, M_DECOMP, M_FILL, M_DONE } st_e;
  st_e state;

  logic [LA_ADDR_W-1:0] addr_q;
  logic [WAY_W-1:0]     way_q;
  // 捕获压缩行元信息 + 解压结果
  algo_e                algo_q; logic [2:0] mode_q; logic [6:0] size_q;
  logic [LINE_BITS-1:0] cdata_q, line_q; logic [7:0] crc_q;

  assign o_busy = (state != M_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= M_IDLE; o_irq_decomp_err <= 1'b0;
    end else begin
      o_irq_decomp_err <= 1'b0;
      unique case (state)
        M_IDLE: if (i_alloc) begin
          addr_q <= i_addr; way_q <= i_victim_way; state <= M_FETCH;
        end
        M_FETCH: if (i_ddr_valid) begin
          algo_q<=i_ddr_algo; mode_q<=i_ddr_mode; size_q<=i_ddr_size;
          cdata_q<=i_ddr_data; crc_q<=i_ddr_crc8; state <= M_DECOMP;
        end
        M_DECOMP: if (i_dec_done) begin
          line_q <= i_dec_line;
          if (i_dec_crc_err) o_irq_decomp_err <= 1'b1; // 上报,不静默
          state <= M_FILL;
        end
        M_FILL: if (i_fill_ready) state <= M_DONE;
        M_DONE: state <= M_IDLE;
        default: state <= M_IDLE;
      endcase
    end
  end

  // ---- 输出 ----
  always_comb begin
    // DDR 读
    o_ddr_req  = (state == M_FETCH);
    o_ddr_addr = addr_q;
    // 解压(M_DECOMP 持续请求,直到 done)
    o_dec_req  = (state == M_DECOMP);
    o_dec_algo = algo_q; o_dec_mode = mode_q; o_dec_size = size_q;
    o_dec_data = cdata_q; o_dec_crc8 = crc_q;
    // 回填
    o_fill_valid = (state == M_FILL);
    o_fill_index = cache_index(addr_q);
    o_fill_way   = way_q;
    o_fill_tag   = cache_tag(addr_q);
    o_fill_data  = line_q;
    o_fill_dirty = 1'b0;
  end
endmodule : mshr_min

`default_nettype wire
