// ============================================================================
// page_header_unpack.sv — Page Header 解码(176B blob → 字段 + 校验)
//   golden = tools/page_header_codec.decode_page_header。
//   o_magic_ok:magic==0xCC55;o_crc_ok:重算 page_crc32 == 存储值。
// ============================================================================
`default_nettype none

module page_header_unpack
  import zc_pkg::*;
(
  input  wire [HEADER_BYTES*8-1:0] i_blob,
  output logic [31:0]              o_generation,
  output logic [15:0]              o_total_comp_size,
  output line_info_t               o_info [LINES_PER_PAGE],
  output logic [7:0]               o_crc8 [LINES_PER_PAGE],
  output logic                     o_magic_ok,
  output logic                     o_crc_ok
);
  localparam int unsigned INFO_BITS = LINE_INFO_W*LINES_PER_PAGE;

  logic [PAGE_CRC_COV_B*8-1:0] crc_in;
  logic [31:0]                 crc_calc, crc_stored;

  always_comb begin
    o_magic_ok        = (i_blob[15:0] == PAGE_MAGIC);
    o_generation      = i_blob[32 +: 32];
    o_total_comp_size = i_blob[64 +: 16];
    crc_stored        = i_blob[96 +: 32];
    for (int i = 0; i < LINES_PER_PAGE; i++)
      o_info[i] = i_blob[128 + i*LINE_INFO_W +: LINE_INFO_W];
    for (int i = 0; i < LINES_PER_PAGE; i++)
      o_crc8[i] = i_blob[832 + i*8 +: 8];
  end

  // 重算 CRC32(同 pack:bytes[0..11] ++ bytes[16..175])
  assign crc_in = {i_blob[HEADER_BYTES*8-1:128], i_blob[95:0]};
  crc32 #(.NBYTES(PAGE_CRC_COV_B)) u_crc (.data(crc_in), .crc(crc_calc));

  assign o_crc_ok = (crc_calc == crc_stored);
endmodule : page_header_unpack

`default_nettype wire
