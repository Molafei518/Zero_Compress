// ============================================================================
// zero_compress.sv — Zero-Value 压缩(§6.1 / compress_eval.compress_zero)
//   mode/size 判定写实;o_data 打包 TODO。
// ============================================================================
`default_nettype none

module zero_compress
  import zc_pkg::*;
(
  input  wire [LINE_BITS-1:0] i_line,
  output logic [2:0]          o_mode,
  output logic [6:0]          o_size,
  output logic [LINE_BITS-1:0] o_data   // TODO: {mode, bitmap, nonzero words}
);
  // 16 个 4B word 的非零标记
  logic [15:0] nz_mask;
  logic [4:0]  nz_cnt;
  logic        all_zero;

  always_comb begin
    nz_mask = '0;
    for (int w = 0; w < 16; w++)
      nz_mask[w] = |i_line[w*32 +: 32];
    nz_cnt   = '0;
    for (int w = 0; w < 16; w++) nz_cnt += nz_mask[w];
    all_zero = (nz_mask == '0);

    if (all_zero) begin
      o_mode = 3'd0; o_size = 7'd1;            // 全零
    end else if (nz_cnt <= 5'd8) begin
      o_mode = 3'd1; o_size = 7'(1 + 2 + 4*nz_cnt); // bitmap + 非零 word
    end else begin
      o_mode = 3'd2; o_size = 7'd64;           // 不适合
    end
    o_data = i_line; // TODO: 真打包
  end
endmodule : zero_compress

`default_nettype wire
