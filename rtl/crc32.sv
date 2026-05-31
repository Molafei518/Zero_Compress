// ============================================================================
// crc32.sv — CRC-32 IEEE 802.3(refin/refout, poly 0xEDB88320, xorout 0xFFFFFFFF)
//   与 golden tools/page_header_codec.py crc32_ieee() 逐位一致。
//   组合实现:对 NBYTES 字节(byte0 在 data[7:0])串行推进。
// ============================================================================
`default_nettype none

module crc32 #(
  parameter int unsigned NBYTES = 172
) (
  input  wire [NBYTES*8-1:0] data,   // byte i 在 data[i*8 +: 8]
  output logic [31:0]        crc
);
  function automatic logic [31:0] crc32_next(input logic [31:0] c, input logic [7:0] d);
    logic [31:0] x;
    x = c ^ {24'b0, d};
    for (int i = 0; i < 8; i++)
      x = x[0] ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1);
    return x;
  endfunction

  always_comb begin
    logic [31:0] c;
    c = 32'hFFFFFFFF;
    for (int b = 0; b < NBYTES; b++)
      c = crc32_next(c, data[b*8 +: 8]);
    crc = c ^ 32'hFFFFFFFF;
  end
endmodule : crc32

`default_nettype wire
