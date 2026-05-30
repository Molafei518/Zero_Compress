// ============================================================================
// tb_top.sv — 全 IP UVM testbench 顶层
//   时钟/复位 + AXI/APB 接口 + DUT(cache_compress_top)+ run_test。
//   注:DUT 当前为骨架(tie-off),env 结构就位,待 DUT 内部实现后端到端可跑。
// ============================================================================
`include "uvm_macros.svh"
module tb_top;
  import uvm_pkg::*;
  import zc_pkg::*;
  import zc_dv_pkg::*;

  // ---- 时钟/复位 ----
  logic clk = 0, rst_n = 0, pclk = 0, presetn = 0;
  always #0.625ns clk  = ~clk;   // 800MHz
  always #5ns     pclk = ~pclk;  // 100MHz
  initial begin
    rst_n = 0; presetn = 0;
    repeat (10) @(posedge clk);
    rst_n = 1; presetn = 1;
  end

  // ---- 接口 ----
  zc_axi_if #(.ADDR_W(LA_ADDR_W), .DATA_W(AXI_DATA_W), .ID_W(AXI_ID_W))
    s_if (.aclk(clk), .aresetn(rst_n));
  zc_axi_if #(.ADDR_W(LA_ADDR_W), .DATA_W(AXI_DATA_W), .ID_W(DS_ID_W))
    m_if (.aclk(clk), .aresetn(rst_n));
  zc_apb_if #(.ADDR_W(12), .DATA_W(32)) apb_if (.pclk(pclk), .presetn(presetn));

  // ---- DUT ----
  wire [N_IRQ-1:0] irq;
  cache_compress_top dut (
    .clk, .rst_n, .pclk, .presetn,
    .strap_cap_ratio(2'b01),     // 1.5×
    .s_axi(s_if.slave),
    .m_axi(m_if.master),
    .apb(apb_if.slave),
    .irq(irq),
    .mbox_req(), .mbox_we(), .mbox_addr(), .mbox_wdata(),
    .mbox_rdata(32'h0), .mbox_ack(1'b0)
  );

  // ---- TODO: 下游 DDR slave 行为模型挂在 m_if(简单 memory responder)----

  // ---- UVM 启动 ----
  initial begin
    uvm_config_db#(virtual zc_axi_if)::set(null, "uvm_test_top.env.agent.*", "s_vif", s_if);
    run_test("zc_base_test");
  end

  initial begin
    $dumpfile("tb_top.vcd"); $dumpvars(0, tb_top);
    #200us; `uvm_fatal("TB", "global timeout")
  end
endmodule : tb_top
