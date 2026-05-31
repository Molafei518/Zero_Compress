// ============================================================================
// tb_unit_roundtrip.sv — 压缩往返自检:compress_top → decompress_top
//   对每条向量 line:压缩后再解压,断言 还原 == 原始,且 CRC 无错。
//   自检性质:不依赖 golden 字节,只要求 compress/decompress 打包格式互逆 + CRC 链路正确。
// ============================================================================
`default_nettype none
module tb_unit_roundtrip;
  import zc_pkg::*;

  localparam int N = 128;
  logic [LINE_BITS-1:0] in_mem [N];

  logic clk = 0;
  always #0.625ns clk = ~clk;

  // compress
  logic                 c_req;
  logic [LINE_BITS-1:0] c_line;
  logic                 c_done;
  algo_e                c_algo;
  logic [2:0]           c_mode;
  logic [6:0]           c_size;
  logic [LINE_BITS-1:0] c_data;
  logic [7:0]           c_crc8;

  compress_top u_comp (
    .clk(clk), .rst_n(1'b1), .i_req(c_req), .i_line(c_line),
    .o_done(c_done), .o_algo(c_algo), .o_mode(c_mode), .o_size(c_size),
    .o_data(c_data), .o_crc8(c_crc8)
  );

  // decompress(由 TB 锁存的压缩结果驱动)
  logic                 d_req;
  algo_e                d_algo;
  logic [2:0]           d_mode;
  logic [6:0]           d_size;
  logic [LINE_BITS-1:0] d_data;
  logic [7:0]           d_crc8;
  logic                 d_done;
  logic [LINE_BITS-1:0] d_line;
  logic                 d_crc_err;

  decompress_top u_dec (
    .clk(clk), .rst_n(1'b1), .i_req(d_req), .i_algo(d_algo), .i_mode(d_mode),
    .i_size(d_size), .i_data(d_data), .i_crc8_exp(d_crc8),
    .o_done(d_done), .o_line(d_line), .o_crc_err(d_crc_err)
  );

  integer fails;
  initial begin
    fails = 0; c_req = 0; d_req = 0;
    $readmemh("../golden/vectors/compress_in.mem", in_mem);
    for (int i = 0; i < N; i++) begin
      if (in_mem[i] === 'x) break;
      // 压缩(等流水出结果)
      @(posedge clk); c_line = in_mem[i]; c_req = 1;
      @(posedge clk); c_req = 0;
      wait (c_done);
      // 锁存压缩结果 → 解压
      d_algo = c_algo; d_mode = c_mode; d_size = c_size;
      d_data = c_data; d_crc8 = c_crc8;
      @(posedge clk); d_req = 1;
      @(posedge clk); d_req = 0;
      wait (d_done);                        // 等解压流水出结果
      if (d_line !== in_mem[i]) begin
        fails++;
        $display("ROUNDTRIP MISMATCH[%0d]: algo=%0d mode=%0d size=%0d", i, c_algo, c_mode, c_size);
      end
      if (d_crc_err) begin
        fails++;
        $display("CRC ERR[%0d]: algo=%0d mode=%0d", i, c_algo, c_mode);
      end
    end
    if (fails == 0) $display("tb_unit_roundtrip: ALL PASS");
    else            $display("tb_unit_roundtrip: %0d FAIL", fails);
    $finish;
  end
endmodule
`default_nettype wire
