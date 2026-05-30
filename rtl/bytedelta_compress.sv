// ============================================================================
// bytedelta_compress.sv — ByteDelta 压缩(§6.3 / compress_eval.compress_bytedelta)
//   mode/size 判定写实;o_data 打包 TODO。
// ============================================================================
`default_nettype none

module bytedelta_compress
  import zc_pkg::*;
(
  input  wire [LINE_BITS-1:0]  i_line,
  output logic [2:0]           o_mode,
  output logic [6:0]           o_size,
  output logic [LINE_BITS-1:0] o_data   // TODO: {mode, base, delta_array}
);
  logic [7:0]  byte_arr [64];
  logic [15:0] w16 [32];
  logic signed [31:0] w32 [16];
  logic all_zero, all_same_byte, ok_b, ok_w16, ok_w32;

  always_comb begin
    for (int i = 0; i < 64; i++) byte_arr[i] = i_line[i*8  +: 8];
    for (int i = 0; i < 32; i++) w16[i]      = i_line[i*16 +: 16];
    for (int i = 0; i < 16; i++) w32[i]      = i_line[i*32 +: 32];

    all_zero      = (i_line == '0);
    all_same_byte = 1'b1;
    for (int i = 1; i < 64; i++) if (byte_arr[i] != byte_arr[0]) all_same_byte = 1'b0;

    // mode2: 相邻 byte 相对 base 的 Δ ∈ [-8, 8)
    ok_b = 1'b1;
    for (int i = 1; i < 64; i++) begin
      logic signed [9:0] d; d = $signed({2'b0, byte_arr[i]}) - $signed({2'b0, byte_arr[0]});
      if (!(d >= -10'sd8 && d < 10'sd8)) ok_b = 1'b0;
    end
    // mode3: 16b word Δ ∈ [-128,128)
    ok_w16 = 1'b1;
    for (int i = 1; i < 32; i++) begin
      logic signed [17:0] d; d = $signed({2'b0, w16[i]}) - $signed({2'b0, w16[0]});
      if (!(d >= -18'sd128 && d < 18'sd128)) ok_w16 = 1'b0;
    end
    // mode4: 32b word Δ ∈ [-32768,32768)
    ok_w32 = 1'b1;
    for (int i = 1; i < 16; i++) begin
      logic signed [32:0] d; d = $signed(w32[i]) - $signed(w32[0]);
      if (!(d >= -33'sd32768 && d < 33'sd32768)) ok_w32 = 1'b0;
    end

    // 候选取最小(并列取小 mode)
    begin
      logic [6:0] sz [6];
      sz[0] = all_zero      ? 7'd1  : 7'd64;
      sz[1] = all_same_byte ? 7'd2  : 7'd64;
      sz[2] = ok_b          ? 7'd34 : 7'd64;
      sz[3] = ok_w16        ? 7'd34 : 7'd64;
      sz[4] = ok_w32        ? 7'd35 : 7'd64;
      sz[5] = 7'd64;
      o_mode = 3'd5; o_size = 7'd64;
      for (int m = 5; m >= 0; m--)
        if (sz[m] <= o_size) begin o_size = sz[m]; o_mode = m[2:0]; end
    end
    o_data = i_line; // TODO: 真打包
  end
endmodule : bytedelta_compress

`default_nettype wire
