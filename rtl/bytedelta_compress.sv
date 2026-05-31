// ============================================================================
// bytedelta_compress.sv — ByteDelta 压缩(§6.3 / compress_eval.compress_bytedelta)
//   打包格式(byte0 在 o_data[7:0],小端;Δ 相对 base=元素[0],有符号):
//     mode0 全零         : size 1
//     mode1 单 byte 重复 : size 2   data[7:0]=base byte
//     mode2 B1+63×Δ4bit  : size 34  data[7:0]=base, data[8+(i-1)*4 +:4]=Δ4 (i=1..63)
//     mode3 B2+31×Δ8bit  : size 34  data[15:0]=w16[0], data[16+(i-1)*8 +:8]=Δ8 (i=1..31)
//     mode4 B4+15×Δ16bit : size 35  data[31:0]=w32[0], data[32+(i-1)*16+:16]=Δ16(i=1..15)
// ============================================================================
`default_nettype none

module bytedelta_compress
  import zc_pkg::*;
(
  input  wire [LINE_BITS-1:0]  i_line,
  output logic [2:0]           o_mode,
  output logic [6:0]           o_size,
  output logic [LINE_BITS-1:0] o_data
);
  logic [7:0]         barr [64];
  logic [15:0]        w16  [32];
  logic signed [31:0] w32  [16];
  logic all_zero, all_same_byte, ok_b, ok_w16, ok_w32;

  always_comb begin
    for (int i=0;i<64;i++) barr[i] = i_line[i*8  +: 8];
    for (int i=0;i<32;i++) w16[i]  = i_line[i*16 +:16];
    for (int i=0;i<16;i++) w32[i]  = i_line[i*32 +:32];

    all_zero = (i_line == '0);
    all_same_byte = 1'b1;
    for (int i=1;i<64;i++) if (barr[i]!=barr[0]) all_same_byte = 1'b0;

    ok_b = 1'b1;
    for (int i=1;i<64;i++) begin
      logic signed [9:0] d; d = $signed({2'b0,barr[i]}) - $signed({2'b0,barr[0]});
      if (!(d>=-10'sd8 && d<10'sd8)) ok_b = 1'b0;
    end
    ok_w16 = 1'b1;
    for (int i=1;i<32;i++) begin
      logic signed [17:0] d; d = $signed({2'b0,w16[i]}) - $signed({2'b0,w16[0]});
      if (!(d>=-18'sd128 && d<18'sd128)) ok_w16 = 1'b0;
    end
    ok_w32 = 1'b1;
    for (int i=1;i<16;i++) begin
      logic signed [32:0] d; d = $signed(w32[i]) - $signed(w32[0]);
      if (!(d>=-33'sd32768 && d<33'sd32768)) ok_w32 = 1'b0;
    end

    begin
      logic [6:0] sz [6];
      sz[0]= all_zero      ? 7'd1  : 7'd64;
      sz[1]= all_same_byte ? 7'd2  : 7'd64;
      sz[2]= ok_b          ? 7'd34 : 7'd64;
      sz[3]= ok_w16        ? 7'd34 : 7'd64;
      sz[4]= ok_w32        ? 7'd35 : 7'd64;
      sz[5]= 7'd64;
      o_mode = 3'd5; o_size = 7'd64;
      for (int m=5;m>=0;m--) if (sz[m] <= o_size) begin o_size = sz[m]; o_mode = m[2:0]; end
    end

    // ---- 打包 ----
    o_data = '0;
    unique case (o_mode)
      3'd1: o_data[7:0] = barr[0];
      3'd2: begin o_data[7:0] = barr[0];
              for (int i=1;i<64;i++) o_data[8 +(i-1)*4  +: 4] = (barr[i]-barr[0]); end
      3'd3: begin o_data[15:0] = w16[0];
              for (int i=1;i<32;i++) o_data[16+(i-1)*8  +: 8] = (w16[i]-w16[0]); end
      3'd4: begin o_data[31:0] = w32[0];
              for (int i=1;i<16;i++) o_data[32+(i-1)*16 +:16] = (w32[i]-w32[0]); end
      default: ;
    endcase
  end
endmodule : bytedelta_compress

`default_nettype wire
