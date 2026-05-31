// ============================================================================
// bdi_decompress.sv — BDI 解码(bdi_compress 的逆,定长位置)
//   word[i] = base + signext(Δ[i]);格式见 bdi_compress.sv。
// ============================================================================
`default_nettype none

module bdi_decompress
  import zc_pkg::*;
(
  input  wire [2:0]            i_mode,
  input  wire [LINE_BITS-1:0]  i_data,
  output logic [LINE_BITS-1:0] o_line
);
  always_comb begin
    logic signed [31:0] b32; logic signed [63:0] b64;
    o_line = '0;
    b32 = i_data[31:0];
    b64 = i_data[63:0];
    unique case (i_mode)
      3'd0: o_line = '0;                                   // 全零
      3'd1: for (int i=0;i<16;i++) o_line[i*32 +:32] = b32;// 单值重复
      3'd2: for (int i=0;i<16;i++)
              o_line[i*32 +:32] = b32 + 32'(signed'(i_data[32+i*8  +: 8]));
      3'd3: for (int i=0;i<16;i++)
              o_line[i*32 +:32] = b32 + 32'(signed'(i_data[32+i*16 +:16]));
      3'd4: for (int i=0;i<8;i++)
              o_line[i*64 +:64] = b64 + 64'(signed'(i_data[64+i*8  +: 8]));
      3'd5: for (int i=0;i<8;i++)
              o_line[i*64 +:64] = b64 + 64'(signed'(i_data[64+i*16 +:16]));
      3'd6: for (int i=0;i<8;i++)
              o_line[i*64 +:64] = b64 + 64'(signed'(i_data[64+i*32 +:32]));
      default: o_line = i_data;                            // mode7 不应到此
    endcase
  end
endmodule : bdi_decompress

`default_nettype wire
