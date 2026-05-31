// ============================================================================
// tb_unit_compress.sv — compress_top 单元 TB(向量驱动)
//   读 compress_in.mem / compress_exp.mem,比对 {algo,mode,size}。
//   exp 打包 = {algo[1:0], mode[2:0], size[6:0]}(12 bit)。
//   注:compress_top 当前为骨架(各引擎 mode/size 已写实,o_data 打包为 TODO),
//       本 TB 比对 algo/mode/size(已可验证),不比对压缩字节。
// ============================================================================
`default_nettype none
module tb_unit_compress;
  import zc_pkg::*;

  localparam int N = 128;
  logic [LINE_BITS-1:0] in_mem  [N];
  logic [11:0]          exp_mem [N];

  logic                 clk = 0;
  always #0.625ns clk = ~clk;

  logic                 req;
  logic [LINE_BITS-1:0] line;
  logic                 done;
  algo_e                algo;
  logic [2:0]           mode;
  logic [6:0]           size;
  logic [LINE_BITS-1:0] cdata;
  logic [7:0]           crc8;

  compress_top dut (
    .clk(clk), .rst_n(1'b1), .i_req(req), .i_line(line),
    .o_done(done), .o_algo(algo), .o_mode(mode), .o_size(size),
    .o_data(cdata), .o_crc8(crc8)
  );

  integer fails;
  logic [11:0] got_packed;
  initial begin
    fails = 0;
    req = 0;
    $readmemh("../golden/vectors/compress_in.mem",  in_mem);
    $readmemh("../golden/vectors/compress_exp.mem", exp_mem);
    for (int i = 0; i < N; i++) begin
      if (in_mem[i] === 'x) break;
      @(posedge clk); line = in_mem[i]; req = 1;
      @(posedge clk); req = 0;
      wait (done);                     // 等流水出结果(对流水深度鲁棒)
      // exp 打包 = algo | mode<<2 | size<<5
      got_packed = (algo & 2'h3) | (mode << 2) | (size << 5);
      if (got_packed !== exp_mem[i]) begin
        fails++;
        $display("COMPRESS MISMATCH[%0d]: got algo=%0d mode=%0d size=%0d packed=%03x exp=%03x",
                 i, algo, mode, size, got_packed, exp_mem[i]);
      end
    end
    if (fails == 0) $display("tb_unit_compress: ALL PASS");
    else            $display("tb_unit_compress: %0d FAIL", fails);
    $finish;
  end
endmodule
`default_nettype wire
