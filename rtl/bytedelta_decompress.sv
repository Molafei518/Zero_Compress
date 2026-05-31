// ============================================================================
// bytedelta_decompress.sv — ByteDelta 解码(bytedelta_compress 的逆)
//   元素[0]=base;元素[i]=base+signext(Δ[i-1]);格式见 bytedelta_compress.sv。
// ============================================================================
`default_nettype none

module bytedelta_decompress
  import zc_pkg::*;
(
  input  wire [2:0]            i_mode,
  input  wire [LINE_BITS-1:0]  i_data,
  output logic [LINE_BITS-1:0] o_line
);
  always_comb begin
    logic [7:0]  bbase; logic [15:0] w16base; logic [31:0] w32base;
    o_line  = '0;
    bbase   = i_data[7:0];
    w16base = i_data[15:0];
    w32base = i_data[31:0];
    unique case (i_mode)
      3'd0: o_line = '0;
      3'd1: for (int i=0;i<64;i++) o_line[i*8 +:8] = bbase;
      3'd2: begin
        o_line[7:0] = bbase;
        for (int i=1;i<64;i++)
          o_line[i*8 +:8] = bbase + 8'(signed'(i_data[8+(i-1)*4 +:4]));
      end
      3'd3: begin
        o_line[15:0] = w16base;
        for (int i=1;i<32;i++)
          o_line[i*16 +:16] = w16base + 16'(signed'(i_data[16+(i-1)*8 +:8]));
      end
      3'd4: begin
        o_line[31:0] = w32base;
        for (int i=1;i<16;i++)
          o_line[i*32 +:32] = w32base + 32'(signed'(i_data[32+(i-1)*16 +:16]));
      end
      default: o_line = i_data;
    endcase
  end
endmodule : bytedelta_decompress

`default_nettype wire
