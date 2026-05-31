// ============================================================================
// tb_sub_cfg.sv — apb_cfg + pressure_mon 子系统(容量反馈 + OS 接口)
//   验证:① APB 写/读 CTRL、PRESSURE_TH;② 驱动 used_pct 过 NORMAL→SOFT_LOW→
//         SOFT_HIGH→HARD_FULL,检查 waterlevel + irq_pressure/hard_full
//         ③ irq raw → int_status;APB 读 INT_STATUS;INT_MASK 门控 o_irq_combined
//         ④ W1C:降水位后写 1 清除 → 读回 0
// ============================================================================
`default_nettype none
module tb_sub_cfg;
  import zc_pkg::*;

  logic clk=0, rst_n=0;
  always #0.625ns clk=~clk;

  // APB
  logic psel, penable, pwrite; logic [11:0] paddr; logic [31:0] pwdata, prdata; logic pready, pslverr;
  // cfg 输出
  logic cache_en, compress_en, gc_en; logic [7:0] cap_ratio;
  logic [6:0] th_low, th_high, th_hard; logic [4:0] gc_bw; logic [15:0] oom_ms; logic [1:0] nca;
  logic [DPA_ADDR_W-1:0] l2p_base, meta_base;
  logic [N_IRQ-1:0] int_mask; logic irq_comb;
  // pressure
  logic [6:0] used_pct; waterlevel_e wl; logic irq_pr, irq_hf, oom_trip;
  logic [N_IRQ-1:0] int_raw;

  apb_cfg u_cfg (
    .clk,.rst_n,.psel,.penable,.pwrite,.paddr,.pwdata,.prdata,.pready,.pslverr,
    .i_strap_cap_ratio(2'd1),
    .o_cfg_cache_en(cache_en),.o_cfg_compress_en(compress_en),.o_cfg_gc_en(gc_en),
    .o_cfg_cap_ratio_x100(cap_ratio),.o_cfg_soft_low(th_low),.o_cfg_soft_high(th_high),.o_cfg_hard_full(th_hard),
    .o_cfg_gc_bw_limit(gc_bw),.o_cfg_oom_timeout_ms(oom_ms),.o_cfg_nca_mode(nca),
    .o_cfg_l2p_base(l2p_base),.o_cfg_meta_base(meta_base),
    .i_used_pct(used_pct),.i_frag_pct(7'd0),.i_int_raw(int_raw),.o_int_mask(int_mask),.o_irq_combined(irq_comb)
  );
  pressure_mon u_pm (
    .clk,.rst_n,.i_used_pct(used_pct),
    .i_th_soft_low(th_low),.i_th_soft_high(th_high),.i_th_hard_full(th_hard),
    .i_oom_timeout_ms(oom_ms),.i_clk_mhz(12'd800),.i_os_relieved(1'b1),
    .o_waterlevel(wl),.o_irq_pressure(irq_pr),.o_irq_hard_full(irq_hf),.o_oom_tripped(oom_trip)
  );
  // pressure → 中断源(其余源 tie 0)
  always_comb begin
    int_raw = '0;
    int_raw[IRQ_PRESSURE]  = irq_pr;
    int_raw[IRQ_HARD_FULL] = irq_hf;
  end

  // APB 任务
  task automatic apb_w(input logic [11:0] a, input logic [31:0] d);
    @(posedge clk); psel<=1; penable<=0; pwrite<=1; paddr<=a; pwdata<=d;
    @(posedge clk); penable<=1;
    @(posedge clk); psel<=0; penable<=0; pwrite<=0;
    @(posedge clk);   // settle:写的 NBA 结果可见
  endtask
  task automatic apb_r(input logic [11:0] a, output logic [31:0] d);
    @(posedge clk); psel<=1; penable<=0; pwrite<=0; paddr<=a;
    @(posedge clk); penable<=1; #1 d=prdata;
    @(posedge clk); psel<=0; penable<=0;
  endtask
  task automatic set_used(input logic [6:0] u); used_pct<=u; repeat(3)@(posedge clk); endtask

  integer fails; logic [31:0] rdata;
  initial begin
    fails=0; psel=0; penable=0; pwrite=0; used_pct=0;
    rst_n=0; repeat(5)@(posedge clk); rst_n=1; repeat(3)@(posedge clk);

    // ① ID 读
    apb_r(12'h000, rdata); if (rdata!==32'h5A43_0001) begin fails++; $display("FAIL: ID=%h",rdata); end
    // CTRL 写/读
    apb_w(12'h00C, 32'h7);            // cache|compress|gc en
    apb_r(12'h00C, rdata); if (rdata[2:0]!==3'b111) begin fails++; $display("FAIL: CTRL=%h",rdata); end
    if (!(cache_en&&compress_en&&gc_en)) begin fails++; $display("FAIL: cfg en 未生效"); end

    // ② 配阈值:low=70 high=80 hard=90
    apb_w(12'h094, (32'd70<<16)|(32'd80<<8)|32'd90);
    if (th_low!==7'd70||th_high!==7'd80||th_hard!==7'd90) begin fails++; $display("FAIL: thresh %0d/%0d/%0d",th_low,th_high,th_hard); end

    // ③ 水位扫描
    set_used(7'd50); if (wl!==WL_NORMAL)    begin fails++; $display("FAIL: 50→wl=%0d",wl); end
    set_used(7'd75); if (wl!==WL_SOFT_LOW)  begin fails++; $display("FAIL: 75→wl=%0d",wl); end
    set_used(7'd85); if (wl!==WL_SOFT_HIGH) begin fails++; $display("FAIL: 85→wl=%0d",wl); end
    if (!irq_pr) begin fails++; $display("FAIL: 85pct 无 irq_pressure"); end
    set_used(7'd95); if (wl!==WL_HARD_FULL) begin fails++; $display("FAIL: 95→wl=%0d",wl); end
    if (!irq_hf) begin fails++; $display("FAIL: 95pct 无 irq_hard_full"); end

    // ④ int_status 锁存(raw 已置位);读 INT_STATUS
    repeat(2)@(posedge clk);
    apb_r(12'h080, rdata);
    if (!rdata[IRQ_PRESSURE] || !rdata[IRQ_HARD_FULL]) begin fails++; $display("FAIL: INT_STATUS=%h",rdata); end

    // INT_MASK 默认全屏蔽 → irq_combined=0;解屏蔽 → =1
    if (irq_comb) begin fails++; $display("FAIL: 默认应屏蔽 irq_combined"); end
    apb_w(12'h084, 32'h0);            // 解除屏蔽
    repeat(2)@(posedge clk);
    if (!irq_comb) begin fails++; $display("FAIL: 解屏蔽后 irq_combined 应为 1"); end

    // ⑤ W1C:先降水位(raw 撤销)→ 写 1 清除 → 读回 0
    set_used(7'd10); repeat(2)@(posedge clk);   // NORMAL,raw=0
    apb_w(12'h080, 32'hF);                       // W1C 清全部
    apb_r(12'h080, rdata);
    if (rdata[N_IRQ-1:0]!==0) begin fails++; $display("FAIL: W1C 后 INT_STATUS=%h",rdata); end

    if (fails==0) $display("tb_sub_cfg: ALL PASS");
    else          $display("tb_sub_cfg: %0d FAIL", fails);
    $finish;
  end
  initial begin #50us; $display("tb_sub_cfg: TIMEOUT"); $finish; end
endmodule
`default_nettype wire
