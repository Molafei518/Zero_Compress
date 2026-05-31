// ============================================================================
// page_header_pack.sv — Page Header 编码(字段 → 176B blob)
//   文档 02 V2;golden = tools/page_header_codec.encode_page_header。
//   blob[ byte b ] = blob_bits[b*8 +: 8](byte0 在 LSB)。
//   布局:0x00 magic(2) 02 rsvd 04 gen(4) 08 total(2) 0A rsvd 0C crc32(4)
//         0x10 line_info(88,11b×64 LSB-first) 0x68 line_crc8(64) 0xA8 rsvd(8)
//   page_crc32 覆盖 172B = bytes[0x00..0x0B] ++ bytes[0x10..0xAF]
// ============================================================================
`default_nettype none

module page_header_pack
  import zc_pkg::*;
(
  input  wire [31:0]              i_generation,
  input  wire [15:0]              i_total_comp_size,
  input  wire line_info_t         i_info  [LINES_PER_PAGE], // 64 × 11b
  input  wire [7:0]               i_crc8  [LINES_PER_PAGE], // 64 × 8b
  output logic [HEADER_BYTES*8-1:0] o_blob
);
  localparam int unsigned INFO_BITS = LINE_INFO_W*LINES_PER_PAGE; // 704
  logic [INFO_BITS-1:0]  info_packed;
  logic [8*64-1:0]       crc8_packed;
  logic [PAGE_CRC_COV_B*8-1:0] crc_in;   // 172 byte
  logic [31:0]           crc_val;

  // line_info 打包(LSB-first:line i 占 bits[i*11 +: 11])
  always_comb begin
    for (int i = 0; i < LINES_PER_PAGE; i++)
      info_packed[i*LINE_INFO_W +: LINE_INFO_W] = i_info[i];
    for (int i = 0; i < LINES_PER_PAGE; i++)
      crc8_packed[i*8 +: 8] = i_crc8[i];
  end

  // 组装 blob(crc 字段先置 0)
  logic [HEADER_BYTES*8-1:0] blob0;
  always_comb begin
    blob0 = '0;
    blob0[15:0]        = PAGE_MAGIC;          // 0x00 magic
    // 0x02 reserved0 = 0
    blob0[32  +: 32]   = i_generation;        // 0x04
    blob0[64  +: 16]   = i_total_comp_size;   // 0x08
    // 0x0A reserved1 = 0
    blob0[96  +: 32]   = 32'h0;               // 0x0C crc32 placeholder
    blob0[128 +: INFO_BITS] = info_packed;    // 0x10 line_info(88B)
    blob0[832 +: 512]  = crc8_packed;         // 0x68 line_crc8(64B)
    // 0xA8 reserved2(8B) = 0
  end

  // CRC32 输入 = bytes[0..11] ++ bytes[16..175]
  assign crc_in = {blob0[HEADER_BYTES*8-1:128], blob0[95:0]};
  crc32 #(.NBYTES(PAGE_CRC_COV_B)) u_crc (.data(crc_in), .crc(crc_val));

  always_comb begin
    o_blob = blob0;
    o_blob[96 +: 32] = crc_val;               // 写入 page_crc32
  end
endmodule : page_header_pack

`default_nettype wire
