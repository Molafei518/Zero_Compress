// ============================================================================
// tb_unit_crc8.sv — line_crc8 单元 TB(向量驱动,DUT 已实现可直接对拍)
//   读 dv/golden/vectors/crc8_*.mem,逐条比对 rtl/line_crc8.sv 输出。
//   无需 UVM/DPI;任何 SV 仿真器可跑。
// ============================================================================
`default_nettype none
module tb_unit_crc8;
  import zc_pkg::*;

  localparam int N = 128;  // 与 gen_vectors --n 对齐
  logic [LINE_BITS-1:0] in_mem  [N];
  logic [6:0]           len_mem [N];
  logic [7:0]           exp_mem [N];

  logic [LINE_BITS-1:0] data;
  logic [6:0]           len;
  logic [7:0]           crc;

  line_crc8 dut (.i_data(data), .i_size(len), .o_crc(crc));

  integer fails;
  initial begin
    fails = 0;
    $readmemh("../golden/vectors/crc8_in.mem",  in_mem);
    $readmemh("../golden/vectors/crc8_len.mem", len_mem);
    $readmemh("../golden/vectors/crc8_exp.mem", exp_mem);
    for (int i = 0; i < N; i++) begin
      if (in_mem[i] === 'x) break;          // 文件不足 N 条时停
      data = in_mem[i]; len = len_mem[i];
      #1;                                    // 组合稳定
      if (crc !== exp_mem[i]) begin
        fails++;
        $display("CRC8 MISMATCH[%0d]: len=%0d got=%02x exp=%02x", i, len, crc, exp_mem[i]);
      end
    end
    if (fails == 0) $display("tb_unit_crc8: ALL PASS");
    else            $display("tb_unit_crc8: %0d FAIL", fails);
    $finish;
  end
endmodule
`default_nettype wire
