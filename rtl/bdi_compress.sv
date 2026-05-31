// ============================================================================
// bdi_compress.sv — Base-Delta-Immediate 压缩(§6.2 / compress_eval.compress_bdi)
//   mode/size 取最小(P1-C3 语义)+ o_data 打包(定长位置)。
//   打包格式(byte0 在 o_data[7:0],小端):
//     mode0 全零            : size 1   data=0
//     mode1 单 4B 重复      : size 4   data[31:0]=word0
//     mode2 base4 + 16×Δ1   : size 20  data[31:0]=base, data[32+i*8 +:8]=Δ8 (i=0..15)
//     mode3 base4 + 16×Δ2   : size 36  data[31:0]=base, data[32+i*16+:16]=Δ16
//     mode4 base8 + 8×Δ1    : size 16  data[63:0]=base, data[64+i*8 +:8]=Δ8 (i=0..7)
//     mode5 base8 + 8×Δ2    : size 24  data[63:0]=base, data[64+i*16+:16]=Δ16
//     mode6 base8 + 8×Δ4    : size 40  data[63:0]=base, data[64+i*32+:32]=Δ32
//   Δ 相对 word[0](base);Δ 为有符号,解压侧符号扩展后加 base。
// ============================================================================
`default_nettype none

module bdi_compress
  import zc_pkg::*;
(
  input  wire [LINE_BITS-1:0]  i_line,
  output logic [2:0]           o_mode,
  output logic [6:0]           o_size,
  output logic [LINE_BITS-1:0] o_data
);
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
      logic [63:0] d; d = absd(64'(w32[i]) - 64'(w32[0])); if (d > max_abs32) max_abs32 = d;
    end
    max_abs64 = '0;
    for (int i = 0; i < 8; i++) begin
      logic [63:0] d; d = absd(w64[i] - w64[0]); if (d > max_abs64) max_abs64 = d;
    end

    // 候选取最小(并列取小 mode 号)
    begin
      logic [6:0] sz [8];
      sz[0]= all_zero            ? 7'd1  : 7'd64;
      sz[1]= all_same32          ? 7'd4  : 7'd64;
      sz[2]= (max_abs32<128)     ? 7'd20 : 7'd64;
      sz[3]= (max_abs32<32768)   ? 7'd36 : 7'd64;
      sz[4]= (max_abs64<128)     ? 7'd16 : 7'd64;
      sz[5]= (max_abs64<32768)   ? 7'd24 : 7'd64;
      sz[6]= (max_abs64<64'd2147483648) ? 7'd40 : 7'd64;
      sz[7]= 7'd64;
      o_mode = 3'd7; o_size = 7'd64;
      for (int m = 7; m >= 0; m--) if (sz[m] <= o_size) begin o_size = sz[m]; o_mode = m[2:0]; end
    end

    // ---- 打包 o_data ----
    o_data = '0;
    unique case (o_mode)
      3'd1: o_data[31:0] = w32[0];
      3'd2: begin o_data[31:0] = w32[0];
              for (int i=0;i<16;i++) o_data[32 + i*8  +: 8 ] = (w32[i]-w32[0]); end
      3'd3: begin o_data[31:0] = w32[0];
              for (int i=0;i<16;i++) o_data[32 + i*16 +:16 ] = (w32[i]-w32[0]); end
      3'd4: begin o_data[63:0] = w64[0];
              for (int i=0;i<8;i++)  o_data[64 + i*8  +: 8 ] = (w64[i]-w64[0]); end
      3'd5: begin o_data[63:0] = w64[0];
              for (int i=0;i<8;i++)  o_data[64 + i*16 +:16 ] = (w64[i]-w64[0]); end
      3'd6: begin o_data[63:0] = w64[0];
              for (int i=0;i<8;i++)  o_data[64 + i*32 +:32 ] = (w64[i]-w64[0]); end
      default: ; // mode0 全零 / mode7 不可压(由 compress_top 转 NONE)
    endcase
  end
endmodule : bdi_compress

`default_nettype wire
