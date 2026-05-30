// ============================================================================
// tag_ram.sv — Tag 存储(N_WAY)+ set 级 pLRU + Tag SECDED
//   设计文档:docs/rtl/04_tag_ram.md   架构:§5.2 / §10.1
//   骨架:SRAM 用行为级数组占位;ECC enc/dec 留 TODO(接 ecc/tag_ecc.sv)。
// ============================================================================
`default_nettype none

module tag_ram
  import zc_pkg::*;
(
  input  wire                    clk,
  input  wire                    rst_n,

  // 读口
  input  wire                    i_rd_en,
  input  wire [IDX_W-1:0]        i_index,
  output tag_entry_t [N_WAY-1:0] o_rdata,
  output logic [PLRU_W-1:0]      o_plru,
  output logic                   o_ecc_corr,
  output logic                   o_ecc_uncorr,

  // 写口
  input  wire                    i_wr_en,
  input  wire [WAY_W-1:0]        i_wr_way,
  input  wire [IDX_W-1:0]        i_wr_index,
  input  tag_entry_t             i_wdata,

  // pLRU 写口
  input  wire                    i_plru_we,
  input  wire [IDX_W-1:0]        i_plru_wr_index,
  input  wire [PLRU_W-1:0]       i_plru_upd,

  // 维护
  input  wire                    i_inval_all
);

  // ==========================================================================
  // 存储(行为级;综合时替换为编译 SRAM + ECC 位)
  // ==========================================================================
  tag_entry_t tag_mem [N_WAY][N_SETS];
  logic [PLRU_W-1:0] plru_mem [N_SETS];
  // valid 用独立 FF 阵列以支持 flash-clear(inval_all 1 拍清)
  logic [N_WAY-1:0]  valid_bits [N_SETS];

  // ---- 读(registered 输出,1 拍延迟)----
  always_ff @(posedge clk) begin
    if (i_rd_en) begin
      for (int w = 0; w < N_WAY; w++) begin
        o_rdata[w]       <= tag_mem[w][i_index];
        o_rdata[w].valid <= valid_bits[i_index][w];
        // TODO: ECC 解码(纠 1 检 2),置 o_ecc_corr/o_ecc_uncorr
      end
      o_plru <= plru_mem[i_index];
    end
  end
  // TODO: o_ecc_corr / o_ecc_uncorr 由 ECC 解码驱动
  assign o_ecc_corr   = 1'b0;
  assign o_ecc_uncorr = 1'b0;

  // ---- 写(write-first 旁路由 pipe 侧保证或在此加比较)----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int s = 0; s < N_SETS; s++) valid_bits[s] <= '0;
    end else begin
      if (i_inval_all) begin
        for (int s = 0; s < N_SETS; s++) valid_bits[s] <= '0; // flash clear
      end else if (i_wr_en) begin
        tag_mem[i_wr_way][i_wr_index]       <= i_wdata; // TODO: 写时生成 ECC
        valid_bits[i_wr_index][i_wr_way]    <= i_wdata.valid;
      end
    end
  end

  // ---- pLRU 写 ----
  always_ff @(posedge clk) begin
    if (i_plru_we) plru_mem[i_plru_wr_index] <= i_plru_upd;
  end

endmodule : tag_ram

`default_nettype wire
