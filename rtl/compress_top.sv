// ============================================================================
// compress_top.sv — 三引擎并行 + Size 比较器 + Tie-Break + line_crc8
//   设计文档:docs/rtl/10_compress.md   架构:§6.4
//   3 级流水(§6.4 "总延迟 3-4 cycle",吞吐 1/cyc):
//     S1 ENG : 三引擎并行 → 寄存 {mode,size,data}(引擎组合,边沿捕获 i_line)
//     S2 CMP : Size 比较 + Tie-Break(Zero>ByteDelta>BDI)→ 寄存 sel
//     S3 CRC : line_crc8 over sel.data → 寄存输出,o_done 对齐
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
  // ---- 三引擎(组合,输入 i_line)----
  logic [2:0] bdi_m, zero_m, bd_m;
  logic [6:0] bdi_s, zero_s, bd_s;
  logic [LINE_BITS-1:0] bdi_d, zero_d, bd_d;
  bdi_compress       u_bdi  (.i_line(i_line), .o_mode(bdi_m),  .o_size(bdi_s),  .o_data(bdi_d));
  zero_compress      u_zero (.i_line(i_line), .o_mode(zero_m), .o_size(zero_s), .o_data(zero_d));
  bytedelta_compress u_bd   (.i_line(i_line), .o_mode(bd_m),   .o_size(bd_s),   .o_data(bd_d));

  // ---- S1 流水寄存器:捕获三引擎结果 ----
  logic v1;
  logic [2:0] s1_bdi_m, s1_zero_m, s1_bd_m;
  logic [6:0] s1_bdi_s, s1_zero_s, s1_bd_s;
  logic [LINE_BITS-1:0] s1_bdi_d, s1_zero_d, s1_bd_d, s1_line;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) v1 <= 1'b0;
    else begin
      v1 <= i_req;
      s1_bdi_m<=bdi_m; s1_bdi_s<=bdi_s; s1_bdi_d<=bdi_d;
      s1_zero_m<=zero_m; s1_zero_s<=zero_s; s1_zero_d<=zero_d;
      s1_bd_m<=bd_m; s1_bd_s<=bd_s; s1_bd_d<=bd_d;
      s1_line<=i_line;
    end
  end

  // ---- S2 比较 + Tie-Break(Zero>ByteDelta>BDI;严格更小才取,并列保持优先级)----
  algo_e                sel_algo; logic [2:0] sel_mode; logic [6:0] sel_size;
  logic [LINE_BITS-1:0] sel_data;
  always_comb begin
    sel_algo=ALGO_ZERO; sel_mode=s1_zero_m; sel_size=s1_zero_s; sel_data=s1_zero_d;
    if (s1_bd_s  < sel_size) begin sel_algo=ALGO_BYTEDELTA; sel_mode=s1_bd_m;  sel_size=s1_bd_s;  sel_data=s1_bd_d;  end
    if (s1_bdi_s < sel_size) begin sel_algo=ALGO_BDI;       sel_mode=s1_bdi_m; sel_size=s1_bdi_s; sel_data=s1_bdi_d; end
    if (sel_size >= 7'd64)   begin sel_algo=ALGO_NONE;      sel_mode=3'd0;     sel_size=7'd64;    sel_data=s1_line;  end
  end

  logic v2; algo_e s2_algo; logic [2:0] s2_mode; logic [6:0] s2_size; logic [LINE_BITS-1:0] s2_data;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) v2 <= 1'b0;
    else begin
      v2 <= v1;
      s2_algo<=sel_algo; s2_mode<=sel_mode; s2_size<=sel_size; s2_data<=sel_data;
    end
  end

  // ---- S3 CRC + 输出 ----
  logic [7:0] crc8_c;
  line_crc8 u_crc (.i_data(s2_data), .i_size(s2_size), .o_crc(crc8_c));
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) o_done <= 1'b0;
    else begin
      o_done <= v2;
      o_algo<=s2_algo; o_mode<=s2_mode; o_size<=s2_size; o_data<=s2_data; o_crc8<=crc8_c;
    end
  end
endmodule : compress_top

`default_nettype wire
