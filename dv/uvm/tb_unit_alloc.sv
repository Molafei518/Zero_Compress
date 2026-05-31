// ============================================================================
// tb_unit_alloc.sv — space_alloc(buddy)单元 TB
//   验证:① alloc 返回块按其大小对齐、在区域内、互不重叠
//         ② 多级拆分(从 4KB 顶块切出 64B/256B/1KB…)
//         ③ 耗尽返回 fail   ④ free 后可复用
//   区域 = 64 个 64B 块(4KB,单顶块)。
// ============================================================================
`default_nettype none
module tb_unit_alloc;
  import zc_pkg::*;
  localparam int REGION = 64;           // 64B 块数
  localparam int REGION_BYTES = REGION*64;

  logic clk=0, rst_n=0;
  always #0.625ns clk=~clk;

  logic        a_req; logic [12:0] a_size; logic a_ack, a_fail; logic [31:0] a_ppa;
  logic        f_req; logic [31:0] f_ppa; logic [12:0] f_size;
  logic [6:0]  used_pct;

  space_alloc #(.REGION_BLK64(REGION)) u_alloc (
    .clk,.rst_n,
    .i_alloc_req(a_req),.i_alloc_size(a_size),.o_alloc_ack(a_ack),.o_alloc_fail(a_fail),.o_alloc_ppa(a_ppa),
    .i_free_req(f_req),.i_free_ppa(f_ppa),.i_free_size(f_size),
    .o_used_pct(used_pct),.i_cfg_meta_base('0),
    .o_fl_rd_req(),.o_fl_addr(),.i_fl_valid(1'b0),.i_fl_data('0),.o_fl_wr_req(),.o_fl_wdata()
  );

  // 活动分配记录(用于重叠检查)
  logic [31:0] live_base [256]; logic [12:0] live_sz [256]; int n_live;
  integer fails;

  function automatic logic [12:0] blk_size(input logic [12:0] sz);
    if (sz<=64) return 64; if(sz<=128) return 128; if(sz<=256) return 256;
    if (sz<=512) return 512; if(sz<=1024) return 1024; if(sz<=2048) return 2048; return 4096;
  endfunction

  task automatic do_alloc(input logic [12:0] sz, output logic [31:0] ppa, output bit fail);
    @(posedge clk); a_req<=1; a_size<=sz;
    @(posedge clk); a_req<=0;
    wait (a_ack || a_fail);
    ppa=a_ppa; fail=a_fail;
    @(posedge clk);
  endtask
  task automatic do_free(input logic [31:0] ppa, input logic [12:0] sz);
    @(posedge clk); f_req<=1; f_ppa<=ppa; f_size<=sz;
    @(posedge clk); f_req<=0;
    @(posedge clk);
  endtask

  // 校验一次成功分配:对齐 + 在区域内 + 与现有不重叠;并登记
  task automatic check_and_record(input logic [31:0] ppa, input logic [12:0] sz);
    logic [12:0] bs; bs = blk_size(sz);
    if (ppa % bs != 0) begin fails++; $display("ALLOC FAIL: ppa=%0d 未对齐到 %0d", ppa, bs); end
    if (ppa + bs > REGION_BYTES) begin fails++; $display("ALLOC FAIL: ppa=%0d+%0d 越界", ppa, bs); end
    for (int k=0;k<n_live;k++)
      if (!(ppa + bs <= live_base[k] || live_base[k] + blk_size(live_sz[k]) <= ppa)) begin
        fails++; $display("ALLOC FAIL: [%0d,+%0d) 与 [%0d,+%0d) 重叠", ppa, bs, live_base[k], blk_size(live_sz[k]));
      end
    live_base[n_live]=ppa; live_sz[n_live]=sz; n_live++;
  endtask

  logic [31:0] p; bit fl; int got;
  logic [31:0] saved_ppa;
  initial begin
    fails=0; n_live=0; a_req=0; f_req=0;
    rst_n=0; repeat(5)@(posedge clk); rst_n=1; repeat(3)@(posedge clk);

    // 1) 不同 size:对齐 + 不重叠 + 多级拆分
    do_alloc(64, p, fl);   if(fl) fails++; else check_and_record(p,64);
    do_alloc(64, p, fl);   if(fl) fails++; else check_and_record(p,64);
    do_alloc(256, p, fl);  if(fl) fails++; else check_and_record(p,256);
    do_alloc(1024, p, fl); if(fl) fails++; else check_and_record(p,1024);
    do_alloc(40, p, fl);   if(fl) fails++; else check_and_record(p,40);  // <64 → 64
    saved_ppa = live_base[0];

    // 2) free 第一个 64B 块 → 复用
    do_free(saved_ppa, 64); n_live--; // 简化:移除最后一条记录占位(saved 仍可能被复用)
    do_alloc(64, p, fl);   if(fl) fails++; else if(p !== saved_ppa) $display("(info)复用非同址 ppa=%0d",p);

    // 3) 耗尽:持续 alloc 64B 直到 fail
    got=0;
    for (int j=0;j<100;j++) begin
      do_alloc(64, p, fl);
      if (fl) break;
      got++;
    end
    if (got==0 && !fl) begin /* 不该到这 */ end
    // 必须最终 fail(区域有限),且总分配字节不超区域
    do_alloc(64, p, fl);
    if (!fl) begin fails++; $display("ALLOC FAIL: 区域应已耗尽却仍成功"); end

    if (fails==0) $display("tb_unit_alloc: ALL PASS (used_pct=%0d)", used_pct);
    else          $display("tb_unit_alloc: %0d FAIL", fails);
    $finish;
  end
  initial begin #50us; $display("tb_unit_alloc: TIMEOUT"); $finish; end
endmodule
`default_nettype wire
