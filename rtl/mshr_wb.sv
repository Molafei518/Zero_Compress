// ============================================================================
// mshr_wb.sv — 带写回(Evict)的 miss 引擎(单条),用于写读闭环集成验证
//   流程(架构 §8.4 读 Miss + Evict 子集):
//     pipe miss(i_alloc)
//       → [victim 脏] EVICT_COMP 压缩 victim → EVICT_WR 写压缩 DDR
//       → FETCH 读 DDR 压缩行(新行;未映射返回零行)→ DECOMP 解压 → FILL 回填
//   write-allocate:fill 后由上层重发写(write-hit 置 dirty);本引擎对读/写一致处理。
//   简化(留后续,见 mshr.sv):假设 L2P 命中、{algo..crc8} 随 DDR 数据返回、单条无合并、无 reloc。
//   CRC 错:o_irq_decomp_err(§10.7,禁静默)。
// ============================================================================
`default_nettype none

module mshr_wb
  import zc_pkg::*;
(
  input  wire                   clk,
  input  wire                   rst_n,

  // from cache_pipe_ctrl(miss)
  input  wire                   i_alloc,
  input  wire [LA_ADDR_W-1:0]   i_addr,
  input  wire                   i_is_write,
  input  wire [WAY_W-1:0]       i_victim_way,
  input  wire                   i_victim_valid,
  input  wire                   i_victim_dirty,
  input  wire [TAG_W-1:0]       i_victim_tag,
  input  wire [LINE_BITS-1:0]   i_victim_data,
  output logic                  o_busy,

  // compress(evict)
  output logic                  o_cmp_req,
  output logic [LINE_BITS-1:0]  o_cmp_line,
  input  wire                   i_cmp_done,
  input  wire algo_e            i_cmp_algo,
  input  wire [2:0]             i_cmp_mode,
  input  wire [6:0]             i_cmp_size,
  input  wire [LINE_BITS-1:0]   i_cmp_data,
  input  wire [7:0]             i_cmp_crc8,

  // DDR 写(压缩行)
  output logic                  o_ddrw_req,
  output logic [LA_ADDR_W-1:0]  o_ddrw_addr,
  output algo_e                 o_ddrw_algo,
  output logic [2:0]            o_ddrw_mode,
  output logic [6:0]            o_ddrw_size,
  output logic [LINE_BITS-1:0]  o_ddrw_data,
  output logic [7:0]            o_ddrw_crc8,
  input  wire                   i_ddrw_done,

  // DDR 读(压缩行)
  output logic                  o_ddrr_req,
  output logic [LA_ADDR_W-1:0]  o_ddrr_addr,
  input  wire                   i_ddrr_valid,
  input  wire algo_e            i_ddrr_algo,
  input  wire [2:0]             i_ddrr_mode,
  input  wire [6:0]             i_ddrr_size,
  input  wire [LINE_BITS-1:0]   i_ddrr_data,
  input  wire [7:0]             i_ddrr_crc8,

  // decompress(fill)
  output logic                  o_dec_req,
  output algo_e                 o_dec_algo,
  output logic [2:0]            o_dec_mode,
  output logic [6:0]            o_dec_size,
  output logic [LINE_BITS-1:0]  o_dec_data,
  output logic [7:0]            o_dec_crc8,
  input  wire                   i_dec_done,
  input  wire [LINE_BITS-1:0]   i_dec_line,
  input  wire                   i_dec_crc_err,

  // fill → pipe
  output logic                  o_fill_valid,
  output logic [IDX_W-1:0]      o_fill_index,
  output logic [WAY_W-1:0]      o_fill_way,
  output logic [TAG_W-1:0]      o_fill_tag,
  output logic [LINE_BITS-1:0]  o_fill_data,
  output logic                  o_fill_dirty,
  input  wire                   i_fill_ready,

  output logic                  o_irq_decomp_err
);
  typedef enum logic [3:0] {
    W_IDLE, W_EVICT_COMP, W_EVICT_WR, W_FETCH, W_DECOMP, W_FILL, W_DONE
  } st_e;
  st_e state;

  logic [LA_ADDR_W-1:0] addr_q;
  logic [WAY_W-1:0]     way_q;
  logic [TAG_W-1:0]     vtag_q;
  logic [LINE_BITS-1:0] vdata_q;
  logic                 vdirty_q, is_wr_q;
  // 捕获压缩(evict)结果
  algo_e                eca_q; logic [2:0] ecm_q; logic [6:0] ecs_q;
  logic [LINE_BITS-1:0] ecd_q; logic [7:0] ecc_q;
  // 捕获 fetch 的压缩行
  algo_e                fca_q; logic [2:0] fcm_q; logic [6:0] fcs_q;
  logic [LINE_BITS-1:0] fcd_q; logic [7:0] fcc_q;
  logic [LINE_BITS-1:0] line_q;

  wire [IDX_W-1:0] idx = cache_index(addr_q);
  // victim 的 LA 行地址(同 set)
  wire [LA_ADDR_W-1:0] victim_addr = {vtag_q, idx, {OFFSET_W{1'b0}}};

  assign o_busy = (state != W_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= W_IDLE; o_irq_decomp_err <= 1'b0;
    end else begin
      o_irq_decomp_err <= 1'b0;
      unique case (state)
        W_IDLE: if (i_alloc) begin
          addr_q<=i_addr; way_q<=i_victim_way; vtag_q<=i_victim_tag;
          vdata_q<=i_victim_data; vdirty_q<=i_victim_valid & i_victim_dirty; is_wr_q<=i_is_write;
          state <= (i_victim_valid & i_victim_dirty) ? W_EVICT_COMP : W_FETCH;
        end
        W_EVICT_COMP: if (i_cmp_done) begin
          eca_q<=i_cmp_algo; ecm_q<=i_cmp_mode; ecs_q<=i_cmp_size; ecd_q<=i_cmp_data; ecc_q<=i_cmp_crc8;
          state <= W_EVICT_WR;
        end
        W_EVICT_WR: if (i_ddrw_done) state <= W_FETCH;
        W_FETCH: if (i_ddrr_valid) begin
          fca_q<=i_ddrr_algo; fcm_q<=i_ddrr_mode; fcs_q<=i_ddrr_size; fcd_q<=i_ddrr_data; fcc_q<=i_ddrr_crc8;
          state <= W_DECOMP;
        end
        W_DECOMP: if (i_dec_done) begin
          line_q <= i_dec_line;
          if (i_dec_crc_err) o_irq_decomp_err <= 1'b1;
          state <= W_FILL;
        end
        W_FILL: if (i_fill_ready) state <= W_DONE;
        W_DONE: state <= W_IDLE;
        default: state <= W_IDLE;
      endcase
    end
  end

  always_comb begin
    // compress(evict)
    o_cmp_req  = (state == W_EVICT_COMP);
    o_cmp_line = vdata_q;
    // DDR 写
    o_ddrw_req  = (state == W_EVICT_WR);
    o_ddrw_addr = victim_addr;
    o_ddrw_algo = eca_q; o_ddrw_mode = ecm_q; o_ddrw_size = ecs_q;
    o_ddrw_data = ecd_q; o_ddrw_crc8 = ecc_q;
    // DDR 读
    o_ddrr_req  = (state == W_FETCH);
    o_ddrr_addr = addr_q;
    // decompress
    o_dec_req  = (state == W_DECOMP);
    o_dec_algo = fca_q; o_dec_mode = fcm_q; o_dec_size = fcs_q;
    o_dec_data = fcd_q; o_dec_crc8 = fcc_q;
    // fill
    o_fill_valid = (state == W_FILL);
    o_fill_index = idx;
    o_fill_way   = way_q;
    o_fill_tag   = cache_tag(addr_q);
    o_fill_data  = line_q;
    o_fill_dirty = 1'b0;           // write-allocate 由上层重发写置 dirty
  end
endmodule : mshr_wb

`default_nettype wire
