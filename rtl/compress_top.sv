// ============================================================================
// compress_top.sv — 三引擎并行 + Size 比较器 + Tie-Break + line_crc8
//   设计文档:docs/rtl/10_compress.md   架构:§6.4
//   骨架:引擎组合输出 + 选最小 + CRC;req→done 浅流水(此处组合 + 1 拍寄存示意)。
// ============================================================================
`default_nettype none

module compress_top
  import zc_pkg::*;
(
  input  wire                   clk,
  input  wire                   rst_n,
  input  wire                   i_req,
  input  wire [LINE_BITS-1:0]   i_line,
  output logic                  o_done,
  output algo_e                 o_algo,
  output logic [2:0]            o_mode,
  output logic [6:0]            o_size,
  output logic [LINE_BITS-1:0]  o_data,
  output logic [7:0]            o_crc8
);
  // ---- 三引擎(组合)----
  logic [2:0] bdi_mode, zero_mode, bd_mode;
  logic [6:0] bdi_size, zero_size, bd_size;
  logic [LINE_BITS-1:0] bdi_data, zero_data, bd_data;

  bdi_compress       u_bdi  (.i_line(i_line), .o_mode(bdi_mode),  .o_size(bdi_size),  .o_data(bdi_data));
  zero_compress      u_zero (.i_line(i_line), .o_mode(zero_mode), .o_size(zero_size), .o_data(zero_data));
  bytedelta_compress u_bd   (.i_line(i_line), .o_mode(bd_mode),   .o_size(bd_size),   .o_data(bd_data));

  // ---- Size 比较 + Tie-Break:Zero > ByteDelta > BDI(解压延迟低者优先)----
  algo_e                sel_algo;
  logic [2:0]           sel_mode;
  logic [6:0]           sel_size;
  logic [LINE_BITS-1:0] sel_data;
  always_comb begin
    // 默认取 Zero
    sel_algo=ALGO_ZERO;      sel_mode=zero_mode; sel_size=zero_size; sel_data=zero_data;
    // ByteDelta 严格更小才取(并列时 Zero 已优先)
    if (bd_size  < sel_size) begin sel_algo=ALGO_BYTEDELTA; sel_mode=bd_mode;  sel_size=bd_size;  sel_data=bd_data;  end
    // BDI 严格更小才取
    if (bdi_size < sel_size) begin sel_algo=ALGO_BDI;       sel_mode=bdi_mode; sel_size=bdi_size; sel_data=bdi_data; end
    // 不可压
    if (sel_size >= 7'd64)   begin sel_algo=ALGO_NONE;      sel_mode=3'd0;     sel_size=7'd64;    sel_data=i_line;   end
  end

  // ---- CRC8(覆盖压缩 byte 序列)----
  logic [7:0] crc8_c;
  line_crc8 u_crc (.i_data(sel_data), .i_size(sel_size), .o_crc(crc8_c));

  // ---- 输出寄存(req→done 1 拍示意;综合后 3-4 cyc 由引擎流水决定)----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) o_done <= 1'b0;
    else begin
      o_done <= i_req;
      if (i_req) begin
        o_algo<=sel_algo; o_mode<=sel_mode; o_size<=sel_size; o_data<=sel_data; o_crc8<=crc8_c;
      end
    end
  end
endmodule : compress_top

`default_nettype wire
