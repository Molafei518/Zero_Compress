// ============================================================================
// ecc_secded.sv — 通用 SECDED(Hamming + 整体奇偶),纠 1 检 2
//   设计文档:docs/rtl/34_ecc_secded.md   架构:§10.1
//   tag/data/meta 按各自 DATA_W 例化。骨架:H 矩阵与 enc/dec 留 TODO。
// ============================================================================
`default_nettype none

module ecc_secded #(
  parameter int unsigned DATA_W = 32,
  // 校验位数:满足 2^r >= DATA_W + r + 1,再 +1 整体奇偶。常见:32→7, 64→8, 27→6(+1)
  parameter int unsigned ECC_W  = 7
) (
  // 编码
  input  wire [DATA_W-1:0] i_enc_data,
  output logic [ECC_W-1:0] o_enc_code,
  // 解码
  input  wire [DATA_W-1:0] i_dec_data,
  input  wire [ECC_W-1:0]  i_dec_code,
  output logic [DATA_W-1:0] o_dec_data,
  output logic             o_corr,
  output logic             o_uncorr
);
  // ---- 编码(TODO: 用 Hamming 生成矩阵 H 计算校验位 + 整体奇偶)----
  always_comb begin
    o_enc_code = '0; // TODO: H · i_enc_data
  end

  // ---- 解码(TODO: syndrome 定位 + 纠正 + 双错检测)----
  always_comb begin
    logic [ECC_W-1:0] syndrome;
    syndrome   = '0;           // TODO: H · i_dec_data ⊕ i_dec_code
    o_dec_data = i_dec_data;   // TODO: 单 bit 错时按 syndrome 翻转纠正
    o_corr     = 1'b0;         // TODO: syndrome!=0 且整体奇偶翻转
    o_uncorr   = 1'b0;         // TODO: syndrome!=0 且整体奇偶未翻转
  end
endmodule : ecc_secded

`default_nettype wire
