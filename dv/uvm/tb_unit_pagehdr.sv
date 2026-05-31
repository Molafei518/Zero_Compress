// ============================================================================
// tb_unit_pagehdr.sv — Page Header 编解码对拍 golden
//   golden blob → unpack(校验 magic/crc)→ repack → 断言 == golden blob。
//   验证:176B 布局、line_info LSB-first 打包、CRC32(覆盖 172B)三者与 golden 一致。
// ============================================================================
`default_nettype none
module tb_unit_pagehdr;
  import zc_pkg::*;

  localparam int NC = 2; // pagehdr_blob.mem 中的用例数(all_zero, mixed)
  logic [HEADER_BYTES*8-1:0] blob_mem [NC];

  logic [HEADER_BYTES*8-1:0] blob, blob2;
  logic [31:0]      gen;
  logic [15:0]      total;
  line_info_t       info_w [LINES_PER_PAGE];
  logic [7:0]       crc8_w [LINES_PER_PAGE];
  logic             magic_ok, crc_ok;

  page_header_unpack u_unpack (
    .i_blob(blob), .o_generation(gen), .o_total_comp_size(total),
    .o_info(info_w), .o_crc8(crc8_w), .o_magic_ok(magic_ok), .o_crc_ok(crc_ok)
  );
  page_header_pack u_pack (
    .i_generation(gen), .i_total_comp_size(total),
    .i_info(info_w), .i_crc8(crc8_w), .o_blob(blob2)
  );

  integer fails;
  initial begin
    fails = 0;
    $readmemh("../golden/vectors/pagehdr_blob.mem", blob_mem);
    for (int k = 0; k < NC; k++) begin
      blob = blob_mem[k];
      #1;
      if (!magic_ok) begin fails++; $display("PAGEHDR[%0d]: magic FAIL", k); end
      if (!crc_ok)   begin fails++; $display("PAGEHDR[%0d]: CRC32 FAIL", k); end
      if (blob2 !== blob) begin
        fails++; $display("PAGEHDR[%0d]: REPACK MISMATCH (gen=%0d total=%0d)", k, gen, total);
      end
    end
    if (fails == 0) $display("tb_unit_pagehdr: ALL PASS");
    else            $display("tb_unit_pagehdr: %0d FAIL", fails);
    $finish;
  end
endmodule
`default_nettype wire
