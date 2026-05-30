// ============================================================================
// perf_counter.sv — 32 × 32-bit 性能计数器
//   设计文档:docs/rtl/32_perf_counter.md   架构:§14.1;文档 04 §6
// ============================================================================
`default_nettype none

module perf_counter
  import zc_pkg::*;
(
  input  wire                     clk,
  input  wire                     rst_n,
  input  wire                     i_en,
  input  wire                     i_reset,
  input  wire [N_PERF_CNT-1:0]    i_inc,
  input  wire [4:0]               i_rd_idx,
  output logic [31:0]             o_rd_val,
  output logic                    o_overflow
);
  logic [31:0] cnt [N_PERF_CNT];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int k=0;k<N_PERF_CNT;k++) cnt[k] <= '0;
      o_overflow <= 1'b0;
    end else if (i_reset) begin
      for (int k=0;k<N_PERF_CNT;k++) cnt[k] <= '0;
      o_overflow <= 1'b0;
    end else if (i_en) begin
      for (int k=0;k<N_PERF_CNT;k++)
        if (i_inc[k]) begin
          if (cnt[k] == 32'hFFFF_FFFF) o_overflow <= 1'b1; // 回绕
          cnt[k] <= cnt[k] + 1'b1;
        end
    end
  end

  assign o_rd_val = cnt[i_rd_idx];
endmodule : perf_counter

`default_nettype wire
