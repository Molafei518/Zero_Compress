// ============================================================================
// line_crc8.sv — 压缩 Line 的 CRC-8/SAE-J1850 生成
//   设计文档:docs/rtl/10_compress.md §3.4   架构:§10.2
//   与 golden model tools/page_header_codec.py crc8() 逐位一致(poly=0x1D,init=0xFF)。
// ============================================================================
`default_nettype none

module line_crc8
  import zc_pkg::*;
(
  input  wire [LINE_BITS-1:0] i_data,   // 压缩 byte 序列(左对齐,byte0 在 [7:0])
  input  wire [6:0]           i_size,   // 有效字节数 1..64
  output logic [7:0]          o_crc
);
  // 单字节 CRC 推进(MSB-first)
  function automatic logic [7:0] crc8_next(input logic [7:0] crc, input logic [7:0] data);
    logic [7:0] c;
    c = crc ^ data;
    for (int i = 0; i < 8; i++)
      c = c[7] ? ((c << 1) ^ CRC8_POLY) : (c << 1);
    return c;
  endfunction

  always_comb begin
    logic [7:0] crc;
    crc = CRC8_INIT;
    for (int b = 0; b < 64; b++)
      if (b < i_size)                      // 仅覆盖有效字节(不含 padding)
        crc = crc8_next(crc, i_data[b*8 +: 8]);
    o_crc = crc;
  end
endmodule : line_crc8

`default_nettype wire
