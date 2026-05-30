// ============================================================================
// data_ram.sv — Cache 数据存储(N_WAY 并行读 + 单路字节写 + SECDED)
//   设计文档:docs/rtl/05_data_ram.md   架构:§5.3 / §10.1
//   骨架:行为级数组;ECC(32b 段)与子-line RMW 留 TODO。
// ============================================================================
`default_nettype none

module data_ram
  import zc_pkg::*;
(
  input  wire                          clk,
  input  wire                          rst_n,

  // 读口(并行读全部 way)
  input  wire                          i_rd_en,
  input  wire [IDX_W-1:0]              i_index,
  output logic [N_WAY-1:0][LINE_BITS-1:0] o_rdata,
  output logic                         o_ecc_corr,
  output logic                         o_ecc_uncorr,

  // 写口(单路,字节使能)
  input  wire                          i_wr_en,
  input  wire [WAY_W-1:0]              i_wr_way,
  input  wire [IDX_W-1:0]              i_wr_index,
  input  wire [LINE_BITS-1:0]          i_wdata,
  input  wire [LINE_BYTES-1:0]         i_wstrb
);

  // 存储(行为级;综合替换为编译 SRAM + ECC)
  logic [LINE_BITS-1:0] data_mem [N_WAY][N_SETS];

  // ---- 读:registered 输出,1 拍 ----
  always_ff @(posedge clk) begin
    if (i_rd_en)
      for (int w = 0; w < N_WAY; w++)
        o_rdata[w] <= data_mem[w][i_index]; // TODO: ECC 解码
  end
  assign o_ecc_corr   = 1'b0; // TODO
  assign o_ecc_uncorr = 1'b0; // TODO

  // ---- 写:字节使能合并(子-line);整段对齐时无需 RMW ----
  always_ff @(posedge clk) begin
    if (i_wr_en) begin
      for (int b = 0; b < LINE_BYTES; b++)
        if (i_wstrb[b])
          data_mem[i_wr_way][i_wr_index][b*8 +: 8] <= i_wdata[b*8 +: 8];
      // TODO: 对受影响的 32-bit ECC 段做 RMW 重算
    end
  end

endmodule : data_ram

`default_nettype wire
