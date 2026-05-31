// ============================================================================
// decompress_top.sv — CRC 校验 + algo 分发 + MUX 还原 64B
//   设计文档:docs/rtl/11_decompress.md   架构:§6.5 / §6.6 / §10.2
// ============================================================================
`default_nettype none

module decompress_top
  import zc_pkg::*;
(
  input  wire                   clk,
  input  wire                   rst_n,
  input  wire                   i_req,
  input  wire algo_e            i_algo,
  input  wire [2:0]             i_mode,
  input  wire [6:0]             i_size,
  input  wire [LINE_BITS-1:0]   i_data,
  input  wire [7:0]             i_crc8_exp,
  output logic                  o_done,
  output logic [LINE_BITS-1:0]  o_line,
  output logic                  o_crc_err
);
  // ---- CRC 校验 ----
  logic crc_ok, crc_err;
  crc_check u_crc (
    .i_valid(i_req), .i_data(i_data), .i_size(i_size),
    .i_crc_exp(i_crc8_exp), .o_crc_ok(crc_ok), .o_crc_err(crc_err)
  );

  // ---- 三解码器(未选中可由综合 clock-gate)----
  logic [LINE_BITS-1:0] bdi_line, zero_line, bd_line;
  bdi_decompress       u_bdi  (.i_mode(i_mode), .i_data(i_data), .o_line(bdi_line));
  zero_decompress      u_zero (.i_mode(i_mode), .i_data(i_data), .o_line(zero_line));
  bytedelta_decompress u_bd   (.i_mode(i_mode), .i_data(i_data), .o_line(bd_line));

  logic [LINE_BITS-1:0] mux_line;
  always_comb begin
    unique case (i_algo)
      ALGO_BDI:       mux_line = bdi_line;
      ALGO_ZERO:      mux_line = zero_line;
      ALGO_BYTEDELTA: mux_line = bd_line;
      ALGO_NONE:      mux_line = i_data;      // 原始直通(前 64B)
      default:        mux_line = '0;
    endcase
  end

  // ---- 输出寄存(req→done;CRC 错随结果带出,数据无效)----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin o_done <= 1'b0; o_crc_err <= 1'b0; end
    else begin
      o_done    <= i_req;
      o_crc_err <= crc_err;          // §10.7:失败不静默零填充,由 mshr/reloc 处理
      if (i_req) o_line <= mux_line;
    end
  end
endmodule : decompress_top

`default_nettype wire
