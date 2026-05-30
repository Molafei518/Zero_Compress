// ============================================================================
// apb_cfg.sv — APB 配置/状态寄存器(寄存器映射见 docs/04_os_driver_abi.md §2)
//   设计文档:docs/rtl/33_apb_cfg.md
//   骨架:APB 握手 + 少量代表寄存器;完整映射与 CDC 同步器 TODO。
// ============================================================================
`default_nettype none

module apb_cfg
  import zc_pkg::*;
(
  input  wire                   clk,
  input  wire                   rst_n,

  // APB(简化展平;集成可换 zc_apb_if.slave)
  input  wire                   psel,
  input  wire                   penable,
  input  wire                   pwrite,
  input  wire [11:0]            paddr,
  input  wire [31:0]            pwdata,
  output logic [31:0]           prdata,
  output logic                  pready,
  output logic                  pslverr,

  input  wire [1:0]             i_strap_cap_ratio,

  // 配置输出(节选)
  output logic                  o_cfg_cache_en,
  output logic                  o_cfg_compress_en,
  output logic                  o_cfg_gc_en,
  output logic [7:0]            o_cfg_cap_ratio_x100,
  output logic [6:0]            o_cfg_soft_low,
  output logic [6:0]            o_cfg_soft_high,
  output logic [6:0]            o_cfg_hard_full,
  output logic [4:0]            o_cfg_gc_bw_limit,
  output logic [15:0]           o_cfg_oom_timeout_ms,
  output logic [1:0]            o_cfg_nca_mode,
  output logic [DPA_ADDR_W-1:0] o_cfg_l2p_base,
  output logic [DPA_ADDR_W-1:0] o_cfg_meta_base,

  // 状态/性能(节选)
  input  wire [6:0]             i_used_pct,
  input  wire [6:0]             i_frag_pct,
  input  wire [N_IRQ-1:0]       i_int_raw,
  output logic [N_IRQ-1:0]      o_int_mask,
  output logic                  o_irq_combined
);
  // 寄存器偏移(节选,完整见文档 04 §2)
  localparam logic [11:0] R_CTRL          = 12'h00C;
  localparam logic [11:0] R_CAP_RATIO     = 12'h010;
  localparam logic [11:0] R_PRESSURE_TH   = 12'h094;
  localparam logic [11:0] R_INT_MASK      = 12'h084;
  localparam logic [11:0] R_INT_STATUS    = 12'h080;

  logic [N_IRQ-1:0] int_status;

  // APB:2 拍访问,无 wait
  wire apb_wr = psel & penable & pwrite;
  wire apb_rd = psel & penable & ~pwrite;
  assign pready  = 1'b1;
  assign pslverr = 1'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      o_cfg_cache_en <= 1'b0; o_cfg_compress_en <= 1'b0; o_cfg_gc_en <= 1'b0;
      o_cfg_cap_ratio_x100 <= (i_strap_cap_ratio==2'd0)?8'd125:
                              (i_strap_cap_ratio==2'd1)?8'd150:
                              (i_strap_cap_ratio==2'd2)?8'd175:8'd200;
      o_cfg_soft_low<=7'd80; o_cfg_soft_high<=7'd95; o_cfg_hard_full<=7'd99;
      o_cfg_gc_bw_limit<=5'd5; o_cfg_oom_timeout_ms<=16'd10; o_cfg_nca_mode<=2'd1;
      o_int_mask <= '1; int_status <= '0;
    end else begin
      // 锁存上一拍的 raw 中断(level/edge 由源决定)
      int_status <= int_status | i_int_raw;
      if (apb_wr) begin
        unique case (paddr)
          R_CTRL: begin
            o_cfg_cache_en    <= pwdata[0];
            o_cfg_compress_en <= pwdata[1];
            o_cfg_gc_en       <= pwdata[2];
          end
          R_CAP_RATIO:   o_cfg_cap_ratio_x100 <= pwdata[7:0];
          R_PRESSURE_TH: begin
            o_cfg_hard_full <= pwdata[6:0];
            o_cfg_soft_high <= pwdata[14:8];
            o_cfg_soft_low  <= pwdata[22:16];
          end
          R_INT_MASK:    o_int_mask  <= pwdata[N_IRQ-1:0];
          R_INT_STATUS:  int_status  <= int_status & ~pwdata[N_IRQ-1:0]; // W1C
          default: ;
        endcase
      end
      // TODO: L2P/META base、bypass[N]、gc_bw、oom_timeout、nca_mode 写;CDC 同步器
    end
  end

  always_comb begin
    unique case (paddr)
      R_INT_STATUS: prdata = {{(32-N_IRQ){1'b0}}, int_status};
      12'h400:      prdata = {25'b0, i_used_pct};       // CURRENT_CAP_USAGE
      12'h404:      prdata = {25'b0, i_frag_pct};       // CURRENT_FRAG
      default:      prdata = 32'h0;                      // TODO: 其余只读
    endcase
  end

  assign o_irq_combined = |(int_status & ~o_int_mask);
endmodule : apb_cfg

`default_nettype wire
