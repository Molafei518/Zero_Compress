// ============================================================================
// bdi_compress.sv — Base-Delta-Immediate 压缩(§6.2 / compress_eval.compress_bdi)
//   关键:收集所有可行 mode 再取最小(P1-C3 修复后语义:不可在 mode2 命中即提前返回)。
//   mode/size 判定写实;o_data 打包 TODO。
// ============================================================================
`default_nettype none

module bdi_compress
  import zc_pkg::*;
(
  input  wire [LINE_BITS-1:0]  i_line,
  output logic [2:0]           o_mode,
  output logic [6:0]           o_size,
  output logic [LINE_BITS-1:0] o_data   // TODO: {mode, base, delta_array}
);
  // 16 个 32b word / 8 个 64b word
  logic signed [31:0] w32 [16];
  logic signed [63:0] w64 [8];
  logic        all_zero, all_same32;
  logic [63:0] max_abs32, max_abs64;

  function automatic logic [63:0] absd(input logic signed [63:0] x);
    return x[63] ? (~x + 64'd1) : x;
  endfunction

  always_comb begin
    for (int i = 0; i < 16; i++) w32[i] = i_line[i*32 +: 32];
    for (int i = 0; i < 8;  i++) w64[i] = i_line[i*64 +: 64];

    all_zero   = (i_line == '0);
    all_same32 = 1'b1;
    for (int i = 1; i < 16; i++) if (w32[i] != w32[0]) all_same32 = 1'b0;

    max_abs32 = '0;
    for (int i = 0; i < 16; i++) begin
      logic [63:0] d; d = absd(64'(w32[i]) - 64'(w32[0]));
      if (d > max_abs32) max_abs32 = d;
    end
    max_abs64 = '0;
    for (int i = 0; i < 8; i++) begin
      logic [63:0] d; d = absd(w64[i] - w64[0]);
      if (d > max_abs64) max_abs64 = d;
    end

    // 各 mode 的候选 size(不满足条件记为 64=不可压),再统一取最小
    begin
      logic [6:0] sz [8];
      sz[0] = all_zero                  ? 7'd1  : 7'd64; // 全零
      sz[1] = all_same32                ? 7'd4  : 7'd64; // 单值重复
      sz[2] = (max_abs32 < 64'd128)     ? 7'd20 : 7'd64; // B4+Δ1×16
      sz[3] = (max_abs32 < 64'd32768)   ? 7'd36 : 7'd64; // B4+Δ2×16
      sz[4] = (max_abs64 < 64'd128)     ? 7'd16 : 7'd64; // B8+Δ1×8
      sz[5] = (max_abs64 < 64'd32768)   ? 7'd24 : 7'd64; // B8+Δ2×8
      sz[6] = (max_abs64 < 64'd2147483648) ? 7'd40 : 7'd64; // B8+Δ4×8
      sz[7] = 7'd64;                                     // 不可压
      // 取最小 size 对应的 mode(并列时取小 mode 号)
      o_mode = 3'd7; o_size = 7'd64;
      for (int m = 7; m >= 0; m--)
        if (sz[m] <= o_size) begin o_size = sz[m]; o_mode = m[2:0]; end
    end
    o_data = i_line; // TODO: 真打包(base + delta array)
  end
endmodule : bdi_compress

`default_nettype wire
