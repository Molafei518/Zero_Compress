// ============================================================================
// zero_decompress.sv — Zero 解码(zero_compress 的逆)
//   mode1:按 bitmap 还原非零 word,其余补零;格式见 zero_compress.sv。
// ============================================================================
`default_nettype none

module zero_decompress
  import zc_pkg::*;
(
  input  wire [2:0]            i_mode,
  input  wire [LINE_BITS-1:0]  i_data,
  output logic [LINE_BITS-1:0] o_line
);
  always_comb begin
    logic [15:0] bitmap; logic [8:0] off;
    o_line = '0;
    unique case (i_mode)
      3'd0: o_line = '0;
      3'd1: begin
        bitmap = i_data[23:8];
        off    = 9'd3;
        for (int w=0; w<16; w++)
          if (bitmap[w]) begin
            o_line[w*32 +: 32] = i_data[off*8 +: 32];
            off += 9'd4;
          end // else 保持 0
      end
      default: o_line = i_data;
    endcase
  end
endmodule : zero_decompress

`default_nettype wire
