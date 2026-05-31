// ============================================================================
// zero_compress.sv — Zero-Value 压缩(§6.1 / compress_eval.compress_zero)
//   打包格式(小端):
//     mode0 全零 : size 1   data=0
//     mode1 稀疏 : size 3+4*nz
//        data[7:0]   = 0 (reserved,占 "+1")
//        data[23:8]  = bitmap16(bit w = 第 w 个 4B word 非零)
//        从 byte3 起依次放非零 word(4B,word 序),变长拼接
//     mode2 不适合(size 64,由 compress_top 转 NONE 或落选)
// ============================================================================
`default_nettype none

module zero_compress
  import zc_pkg::*;
(
  input  wire [LINE_BITS-1:0]  i_line,
  output logic [2:0]           o_mode,
  output logic [6:0]           o_size,
  output logic [LINE_BITS-1:0] o_data
);
  logic [15:0] nz_mask;
  logic [4:0]  nz_cnt;
  logic        all_zero;

  always_comb begin
    nz_mask = '0;
    for (int w=0; w<16; w++) nz_mask[w] = |i_line[w*32 +: 32];
    nz_cnt = '0;
    for (int w=0; w<16; w++) nz_cnt += nz_mask[w];
    all_zero = (nz_mask == '0);

    if (all_zero)            begin o_mode=3'd0; o_size=7'd1; end
    else if (nz_cnt <= 5'd8) begin o_mode=3'd1; o_size=7'(3 + 4*nz_cnt); end
    else                     begin o_mode=3'd2; o_size=7'd64; end

    // ---- 打包 ----
    o_data = '0;
    if (o_mode == 3'd1) begin
      logic [8:0] off;                 // byte 偏移
      o_data[23:8] = nz_mask;          // bitmap(byte1..2)
      off = 9'd3;
      for (int w=0; w<16; w++)
        if (nz_mask[w]) begin
          o_data[off*8 +: 32] = i_line[w*32 +: 32];
          off += 9'd4;
        end
    end
  end
endmodule : zero_compress

`default_nettype wire
