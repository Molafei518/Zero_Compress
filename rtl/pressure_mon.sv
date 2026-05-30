// ============================================================================
// pressure_mon.sv — 容量水位监控 + 压力中断 + OOM 计时
//   设计文档:docs/rtl/30_pressure_mon.md   架构:§3.3;文档 04 §3
// ============================================================================
`default_nettype none

module pressure_mon
  import zc_pkg::*;
#(
  parameter int unsigned HYST = 2  // 滞回%
) (
  input  wire             clk,
  input  wire             rst_n,
  input  wire [6:0]       i_used_pct,
  input  wire [6:0]       i_th_soft_low,
  input  wire [6:0]       i_th_soft_high,
  input  wire [6:0]       i_th_hard_full,
  input  wire [15:0]      i_oom_timeout_ms,
  input  wire [11:0]      i_clk_mhz,
  input  wire             i_os_relieved,
  output waterlevel_e     o_waterlevel,
  output logic            o_irq_pressure,
  output logic            o_irq_hard_full,
  output logic            o_oom_tripped
);
  waterlevel_e wl, wl_q;
  logic [31:0] oom_timer;

  // 水位(带简单滞回:升用阈值,降需低于阈值-HYST)
  always_comb begin
    if      (i_used_pct >= i_th_hard_full) wl = WL_HARD_FULL;
    else if (i_used_pct >= i_th_soft_high) wl = WL_SOFT_HIGH;
    else if (i_used_pct >= i_th_soft_low)  wl = WL_SOFT_LOW;
    else                                   wl = WL_NORMAL;
    // 滞回:仅当明显低于当前级阈值才降(TODO: 精确按 wl_q 比较 -HYST)
  end

  assign o_waterlevel   = wl_q;
  assign o_irq_pressure = (wl_q == WL_SOFT_HIGH) || (wl_q == WL_HARD_FULL);
  assign o_irq_hard_full= (wl_q == WL_HARD_FULL);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wl_q <= WL_NORMAL; oom_timer <= '0; o_oom_tripped <= 1'b0;
    end else begin
      wl_q <= wl;
      // OOM 计时
      if (wl == WL_HARD_FULL && !i_os_relieved) begin
        if (oom_timer == 0) begin
          // 装载 timeout(ms × MHz × 1000 周期);TODO: 精确乘法/分段计数
          oom_timer <= i_oom_timeout_ms * i_clk_mhz * 32'd1000;
        end else if (oom_timer == 32'd1) begin
          o_oom_tripped <= 1'b1;     // 超时锁存
          oom_timer <= 32'd0;
        end else begin
          oom_timer <= oom_timer - 1'b1;
        end
      end else begin
        oom_timer     <= '0;
        if (i_os_relieved || wl != WL_HARD_FULL) o_oom_tripped <= 1'b0;
      end
    end
  end
endmodule : pressure_mon

`default_nettype wire
