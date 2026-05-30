// zero_decompress.sv — Zero 解码(§6.5);骨架:还原逻辑 TODO。
`default_nettype none
module zero_decompress import zc_pkg::*; (
  input  wire [2:0]            i_mode,
  input  wire [LINE_BITS-1:0]  i_data,
  output logic [LINE_BITS-1:0] o_line
);
  always_comb begin
    unique case (i_mode)
      3'd0: o_line = '0;            // 全零
      default: o_line = i_data;     // TODO: mode1 bitmap 展开非零 word,余补零
    endcase
  end
endmodule
`default_nettype wire
