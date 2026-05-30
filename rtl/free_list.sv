// ============================================================================
// free_list.sv — Buddy 多级 bitmap(DDR 元数据区 16MB)+ 片上段缓存
//   设计文档:docs/rtl/20_space_alloc.md §3   架构:§7.1.2
//   骨架:bitmap 段读改写 + 碎片统计 TODO。
// ============================================================================
`default_nettype none

module free_list
  import zc_pkg::*;
(
  input  wire                   clk,
  input  wire                   rst_n,
  // space_alloc 抽象口
  input  wire                   i_rd_req,
  input  wire [DPA_ADDR_W-1:0]  i_addr,
  output logic                  o_valid,
  output logic [AXI_DATA_W-1:0] o_data,
  input  wire                   i_wr_req,
  input  wire [AXI_DATA_W-1:0]  i_wdata,
  // 下游 DDR(经 m_axi,ID=IDC_META)
  output logic                  o_ddr_rd_req,
  output logic [DPA_ADDR_W-1:0] o_ddr_addr,
  input  wire                   i_ddr_valid,
  input  wire [AXI_DATA_W-1:0]  i_ddr_data,
  output logic                  o_ddr_wr_req,
  output logic [AXI_DATA_W-1:0] o_ddr_wdata,
  // 碎片率(给 pressure_mon / 性能)
  output logic [6:0]            o_frag_pct
);
  // TODO: bitmap 段片上缓存(命中免 DDR);buddy 合并的相邻 bit 检查;碎片统计
  always_comb begin
    o_valid = 1'b0; o_data = '0;
    o_ddr_rd_req = i_rd_req; o_ddr_addr = i_addr;
    o_ddr_wr_req = i_wr_req; o_ddr_wdata = i_wdata;
    o_frag_pct = 7'd0;
  end
endmodule : free_list

`default_nettype wire
