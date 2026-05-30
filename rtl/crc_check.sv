// ============================================================================
// crc_check.sv — 解压前 CRC8 校验
//   设计文档:docs/rtl/11_decompress.md §4   架构:§10.2 / §10.7
//   失败 → o_crc_err(触发 IRQ_DECOMP_ERR + SLVERR;禁止静默零填充)。
// ============================================================================
`default_nettype none

module crc_check
  import zc_pkg::*;
(
  input  wire                 i_valid,
  input  wire [LINE_BITS-1:0] i_data,
  input  wire [6:0]           i_size,
  input  wire [7:0]           i_crc_exp,
  output logic                o_crc_ok,
  output logic                o_crc_err
);
  logic [7:0] calc;
  // 复用与 line_crc8 相同的多项式(必须与 golden model 一致)
  line_crc8 u_crc (.i_data(i_data), .i_size(i_size), .o_crc(calc));

  always_comb begin
    o_crc_ok  = i_valid & (calc == i_crc_exp);
    o_crc_err = i_valid & (calc != i_crc_exp);
  end
endmodule : crc_check

`default_nettype wire
