// bytedelta_decompress.sv — ByteDelta 解码(§6.5);骨架:base+delta 还原 TODO。
`default_nettype none
module bytedelta_decompress import zc_pkg::*; (
  input  wire [2:0]            i_mode,
  input  wire [LINE_BITS-1:0]  i_data,
  output logic [LINE_BITS-1:0] o_line
);
  // TODO: mode2 byte/4bit、mode3 16b/8bit、mode4 32b/16bit delta 还原
  always_comb begin
    unique case (i_mode)
      3'd0: o_line = '0;                 // 全零
      3'd1: o_line = {64{i_data[7:0]}};  // 单 byte 重复
      default: o_line = i_data;          // TODO
    endcase
  end
endmodule
`default_nettype wire
