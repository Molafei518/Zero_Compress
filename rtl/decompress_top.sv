// ============================================================================
// decompress_top.sv — CRC 校验 + algo 分发 + MUX 还原 64B
//   设计文档:docs/rtl/11_decompress.md   架构:§6.5 / §6.6 / §10.2
//   2 级流水(§6.5 "2-3 cycle"):
//     S1 : crc_check + 锁存输入(crc_err 随结果带出)
//     S2 : 三解码器 MUX 还原 → 寄存输出,o_done 对齐
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
  // ---- S1:CRC 校验 + 锁存输入 ----
  logic crc_ok, crc_err;
  crc_check u_crc (
    .i_valid(i_req), .i_data(i_data), .i_size(i_size),
    .i_crc_exp(i_crc8_exp), .o_crc_ok(crc_ok), .o_crc_err(crc_err)
  );

  logic                 v1;
  algo_e                s1_algo; logic [2:0] s1_mode;
  logic [LINE_BITS-1:0] s1_data; logic s1_crc_err;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) v1 <= 1'b0;
    else begin
      v1 <= i_req;
      s1_algo<=i_algo; s1_mode<=i_mode; s1_data<=i_data; s1_crc_err<=crc_err;
    end
  end

  // ---- S2:三解码器 + MUX(组合)→ 寄存输出 ----
  logic [LINE_BITS-1:0] bdi_line, zero_line, bd_line, mux_line;
  bdi_decompress       u_bdi  (.i_mode(s1_mode), .i_data(s1_data), .o_line(bdi_line));
  zero_decompress      u_zero (.i_mode(s1_mode), .i_data(s1_data), .o_line(zero_line));
  bytedelta_decompress u_bd   (.i_mode(s1_mode), .i_data(s1_data), .o_line(bd_line));
  always_comb begin
    unique case (s1_algo)
      ALGO_BDI:       mux_line = bdi_line;
      ALGO_ZERO:      mux_line = zero_line;
      ALGO_BYTEDELTA: mux_line = bd_line;
      ALGO_NONE:      mux_line = s1_data;   // 原始直通
      default:        mux_line = '0;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin o_done <= 1'b0; o_crc_err <= 1'b0; end
    else begin
      o_done    <= v1;
      o_crc_err <= s1_crc_err;          // §10.7:失败不静默零填充
      o_line    <= mux_line;
    end
  end
endmodule : decompress_top

`default_nettype wire
