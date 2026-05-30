// bdi_decompress.sv — BDI 解码(§6.5);骨架:base+delta 累加还原 TODO。
`default_nettype none
module bdi_decompress import zc_pkg::*; (
  input  wire [2:0]            i_mode,
  input  wire [LINE_BITS-1:0]  i_data,
  output logic [LINE_BITS-1:0] o_line
);
  // TODO: 按 mode 取 base(4/8B)与 delta 宽度(1/2/4B),word[i]=base+delta[i]
  always_comb begin
    unique case (i_mode)
      3'd0: o_line = '0;          // 全零
      3'd1: o_line = {16{i_data[31:0]}}; // 单值重复(16×4B)
      default: o_line = i_data;   // TODO: mode2-6 base+delta 还原
    endcase
  end
endmodule
`default_nettype wire
