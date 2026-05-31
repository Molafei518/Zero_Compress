// ============================================================================
// tb_sub_l2p.sv — l2p_meta_cache + l2p_dma 子系统(L2P 片上缓存)
//   验证:① 写 entry → 读回(命中)  ② 同 block 内多 entry 共享缓存行
//         ③ 冲突淘汰:写穿已落 DDR;淘汰后重读 → miss → dma 取回 → 值正确
//   DDR L2P 表模型:block 粒度(512b),按字节地址键。N_BLOCK=4 便于触发冲突。
// ============================================================================
`default_nettype none
module tb_sub_l2p;
  import zc_pkg::*;
  localparam int NB = 4;

  logic clk=0, rst_n=0;
  always #0.625ns clk=~clk;

  logic        rd; logic [LA_PAGE_W-1:0] rd_pg; logic rd_v; l2p_entry_t rd_e;
  logic        wr; logic [LA_PAGE_W-1:0] wr_pg; l2p_entry_t wr_e; logic wr_done;
  logic        dma_rd_req; logic [LA_PAGE_W-4:0] dma_rd_blk; logic dma_rd_v; logic [511:0] dma_rd_blk_d;
  logic        dma_wr_req; logic [LA_PAGE_W-4:0] dma_wr_blk; logic [511:0] dma_wr_blk_d; logic dma_wr_done;
  logic        ddr_rd_req; logic [DPA_ADDR_W-1:0] ddr_rd_addr; logic ddr_rd_v; logic [511:0] ddr_rd_blk;
  logic        ddr_wr_req; logic [DPA_ADDR_W-1:0] ddr_wr_addr; logic [511:0] ddr_wr_blk; logic ddr_wr_done;

  l2p_meta_cache #(.N_BLOCK(NB)) u_cache (
    .clk,.rst_n,.i_rd(rd),.i_rd_page(rd_pg),.o_rd_valid(rd_v),.o_rd_entry(rd_e),
    .i_wr(wr),.i_wr_page(wr_pg),.i_wr_entry(wr_e),.o_wr_done(wr_done),
    .o_dma_rd_req(dma_rd_req),.o_dma_rd_blk(dma_rd_blk),.i_dma_rd_valid(dma_rd_v),.i_dma_rd_block(dma_rd_blk_d),
    .o_dma_wr_req(dma_wr_req),.o_dma_wr_blk(dma_wr_blk),.o_dma_wr_block(dma_wr_blk_d),.i_dma_wr_done(dma_wr_done),
    .o_perf_hit(),.o_perf_miss());
  l2p_dma u_dma (
    .clk,.rst_n,.i_rd_req(dma_rd_req),.i_rd_blk(dma_rd_blk),.o_rd_valid(dma_rd_v),.o_rd_block(dma_rd_blk_d),
    .i_wr_req(dma_wr_req),.i_wr_blk(dma_wr_blk),.i_wr_block(dma_wr_blk_d),.o_wr_done(dma_wr_done),.o_busy(),
    .i_cfg_l2p_base(32'h0),
    .o_ddr_rd_req(ddr_rd_req),.o_ddr_rd_addr(ddr_rd_addr),.i_ddr_rd_valid(ddr_rd_v),.i_ddr_rd_block(ddr_rd_blk),
    .o_ddr_wr_req(ddr_wr_req),.o_ddr_wr_addr(ddr_wr_addr),.o_ddr_wr_block(ddr_wr_blk),.i_ddr_wr_done(ddr_wr_done));

  // ---- DDR L2P 表模型(按字节地址键 512b 块)----
  logic [511:0] ddr_store [bit[DPA_ADDR_W-1:0]];
  logic dr_busy; logic [1:0] dr_cnt; logic dw_busy; logic [1:0] dw_cnt;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin ddr_rd_v<=0; dr_busy<=0; end
    else begin ddr_rd_v<=0;
      if (ddr_rd_req && !dr_busy) begin dr_busy<=1; dr_cnt<=2; end
      else if (dr_busy) begin if (dr_cnt==0) begin ddr_rd_blk<=ddr_store.exists(ddr_rd_addr)?ddr_store[ddr_rd_addr]:512'd0; ddr_rd_v<=1; dr_busy<=0; end else dr_cnt<=dr_cnt-1; end
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin ddr_wr_done<=0; dw_busy<=0; end
    else begin ddr_wr_done<=0;
      if (ddr_wr_req && !dw_busy) begin dw_busy<=1; dw_cnt<=2; end
      else if (dw_busy) begin if (dw_cnt==0) begin ddr_store[ddr_wr_addr]=ddr_wr_blk; ddr_wr_done<=1; dw_busy<=0; end else dw_cnt<=dw_cnt-1; end
    end
  end

  // ---- 辅助 ----
  function automatic l2p_entry_t mke(input logic [31:0] ppa);
    return '{rsvd:7'd0, algomix:8'd0, size:13'd180, ppa_ptr:ppa, state:ZC_COMPRESSED, valid:1'b1};
  endfunction
  task automatic l2p_write(input logic [LA_PAGE_W-1:0] pg, input logic [31:0] ppa);
    @(posedge clk); wr<=1; wr_pg<=pg; wr_e<=mke(ppa);
    @(posedge clk); wr<=0;
    wait (wr_done); @(posedge clk);
  endtask
  task automatic l2p_read(input logic [LA_PAGE_W-1:0] pg, output l2p_entry_t e);
    @(posedge clk); rd<=1; rd_pg<=pg;
    @(posedge clk); rd<=0;
    wait (rd_v); e=rd_e; @(posedge clk);
  endtask

  integer fails; l2p_entry_t e;
  // 页:A=0,B=1(同 blk0);C=32(blk4 → idx0 与 blk0 冲突,NB=4)
  initial begin
    fails=0; rd=0; wr=0;
    rst_n=0; repeat(5)@(posedge clk); rst_n=1; repeat(3)@(posedge clk);

    // ① 写 A,B(同 block);读回命中
    l2p_write(28'd0, 32'hAA);
    l2p_write(28'd1, 32'hBB);
    l2p_read(28'd0, e); if (e.ppa_ptr!==32'hAA) begin fails++; $display("FAIL: read A ppa=%h",e.ppa_ptr); end
    l2p_read(28'd1, e); if (e.ppa_ptr!==32'hBB) begin fails++; $display("FAIL: read B ppa=%h",e.ppa_ptr); end

    // ② 写 C(blk4,与 blk0 同 cache idx → 淘汰 blk0;blk0 已 write-through)
    l2p_write(28'd32, 32'hCC);
    l2p_read(28'd32, e); if (e.ppa_ptr!==32'hCC) begin fails++; $display("FAIL: read C ppa=%h",e.ppa_ptr); end

    // ③ 重读 A → cache idx0 现为 blk4(tag 不符)→ miss → dma 取回 blk0 → 应得 AA
    l2p_read(28'd0, e); if (e.ppa_ptr!==32'hAA) begin fails++; $display("FAIL: refetch A ppa=%h(write-through 失效?)",e.ppa_ptr); end
    // B 也在 blk0,refetch 应得 BB
    l2p_read(28'd1, e); if (e.ppa_ptr!==32'hBB) begin fails++; $display("FAIL: refetch B ppa=%h",e.ppa_ptr); end

    if (fails==0) $display("tb_sub_l2p: ALL PASS");
    else          $display("tb_sub_l2p: %0d FAIL", fails);
    $finish;
  end
  initial begin #80us; $display("tb_sub_l2p: TIMEOUT"); $finish; end
endmodule
`default_nettype wire
