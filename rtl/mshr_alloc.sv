// ============================================================================
// mshr_alloc.sv — miss/evict 引擎,PPA 经 space_alloc 真实分配(替代 identity 映射)
//   相比 mshr_meta:evict 时
//     ① 读 victim 页 L2P → ② 若已映射,free 旧槽 → ③ 按压缩 footprint alloc 新槽
//     ④ 真实 ppa 写 DDR(Header+数据)+ 写 L2P(entry.ppa_ptr=新槽, size=footprint)
//   footprint = HEADER_BYTES + comp_size(单行/页;真实多行为 Header+Σline)。
//   fetch 用 L2P 真实 ppa 读 DDR。内含 page_header_pack/unpack(真实元数据)。
//   简化:单条;buddy 合并/Slab 归后续;空间不足(alloc_fail)→ 简化为标记(真实走 reloc/IRQ)。
// ============================================================================
`default_nettype none

module mshr_alloc
  import zc_pkg::*;
(
  input  wire                   clk,
  input  wire                   rst_n,

  input  wire                   i_alloc,
  input  wire [LA_ADDR_W-1:0]   i_addr,
  input  wire                   i_is_write,
  input  wire [WAY_W-1:0]       i_victim_way,
  input  wire                   i_victim_valid,
  input  wire                   i_victim_dirty,
  input  wire [TAG_W-1:0]       i_victim_tag,
  input  wire [LINE_BITS-1:0]   i_victim_data,
  output logic                  o_busy,

  // compress(evict)
  output logic                  o_cmp_req,
  output logic [LINE_BITS-1:0]  o_cmp_line,
  input  wire                   i_cmp_done,
  input  wire algo_e            i_cmp_algo,
  input  wire [2:0]             i_cmp_mode,
  input  wire [6:0]             i_cmp_size,
  input  wire [LINE_BITS-1:0]   i_cmp_data,
  input  wire [7:0]             i_cmp_crc8,

  // decompress(fill)
  output logic                  o_dec_req,
  output algo_e                 o_dec_algo,
  output logic [2:0]            o_dec_mode,
  output logic [6:0]            o_dec_size,
  output logic [LINE_BITS-1:0]  o_dec_data,
  output logic [7:0]            o_dec_crc8,
  input  wire                   i_dec_done,
  input  wire [LINE_BITS-1:0]   i_dec_line,
  input  wire                   i_dec_crc_err,

  // L2P(查 / 写)
  output logic                  o_l2p_rd,
  output logic [LA_PAGE_W-1:0]  o_l2p_page,
  input  wire                   i_l2p_valid,
  input  l2p_entry_t            i_l2p_entry,
  output logic                  o_l2p_wr,
  output logic [LA_PAGE_W-1:0]  o_l2p_wr_page,
  output l2p_entry_t            o_l2p_wr_entry,

  // space_alloc(分配 / 释放)
  output logic                  o_alloc_req,
  output logic [12:0]           o_alloc_size,
  input  wire                   i_alloc_ack,
  input  wire                   i_alloc_fail,
  input  wire [31:0]            i_alloc_ppa,
  output logic                  o_free_req,
  output logic [31:0]           o_free_ppa,
  output logic [12:0]           o_free_size,

  // DDR(按 PPA 存 Header[176B] + 压缩数据)
  output logic                  o_ddrw_req,
  output logic [31:0]           o_ddrw_ppa,
  output logic [HEADER_BYTES*8-1:0] o_ddrw_header,
  output logic [LINE_BITS-1:0]  o_ddrw_cdata,
  input  wire                   i_ddrw_done,
  output logic                  o_ddrr_req,
  output logic [31:0]           o_ddrr_ppa,
  input  wire                   i_ddrr_valid,
  input  wire [HEADER_BYTES*8-1:0] i_ddrr_header,
  input  wire [LINE_BITS-1:0]   i_ddrr_cdata,

  // fill → pipe
  output logic                  o_fill_valid,
  output logic [IDX_W-1:0]      o_fill_index,
  output logic [WAY_W-1:0]      o_fill_way,
  output logic [TAG_W-1:0]      o_fill_tag,
  output logic [LINE_BITS-1:0]  o_fill_data,
  output logic                  o_fill_dirty,
  input  wire                   i_fill_ready,

  output logic                  o_irq_decomp_err,
  output logic                  o_irq_hard_full
);
  typedef enum logic [3:0] {
    S_IDLE, S_EV_COMP, S_EV_VL2P, S_EV_FREE, S_EV_ALLOC, S_EV_WR, S_EV_L2PWR,
    S_L2P_RD, S_DDR_RD, S_DECOMP, S_FILL, S_FILL_ZERO, S_DONE
  } st_e;
  st_e state;

  logic [LA_ADDR_W-1:0] addr_q;
  logic [WAY_W-1:0]     way_q;
  logic [TAG_W-1:0]     vtag_q;
  logic [LINE_BITS-1:0] vdata_q;
  algo_e                eca_q; logic [2:0] ecm_q; logic [6:0] ecs_q;
  logic [LINE_BITS-1:0] ecd_q; logic [7:0] ecc_q;
  logic [HEADER_BYTES*8-1:0] hdr_q; logic [LINE_BITS-1:0] cdata_q, line_q;
  // 新分配 ppa + 旧槽(free 用)
  logic [31:0]          new_ppa_q;
  logic                 old_valid_q; logic [31:0] old_ppa_q; logic [12:0] old_size_q;

  wire [IDX_W-1:0]     idx        = cache_index(addr_q);
  wire [LA_ADDR_W-1:0] vict_addr  = {vtag_q, idx, {OFFSET_W{1'b0}}};
  wire [LA_PAGE_W-1:0] vict_page  = la_page_num(vict_addr);
  wire [LA_PAGE_W-1:0] miss_page  = la_page_num(addr_q);
  wire [12:0]          footprint  = 13'(HEADER_BYTES) + 13'(ecs_q);

  // Page Header 打包(evict)
  line_info_t pk_info [LINES_PER_PAGE]; logic [7:0] pk_crc8 [LINES_PER_PAGE];
  always_comb begin
    for (int i=0;i<LINES_PER_PAGE;i++) begin
      pk_info[i]='{size_minus1:6'd0,mode:3'd0,algo:ALGO_ZERO}; pk_crc8[i]=8'd0;
    end
    pk_info[0]='{size_minus1:6'(ecs_q-7'd1),mode:ecm_q,algo:eca_q}; pk_crc8[0]=ecc_q;
  end
  logic [HEADER_BYTES*8-1:0] ev_header;
  page_header_pack u_pack (.i_generation(32'd0), .i_total_comp_size(16'(ecs_q)),
                           .i_info(pk_info), .i_crc8(pk_crc8), .o_blob(ev_header));
  // Page Header 解包(fetch)
  line_info_t up_info [LINES_PER_PAGE]; logic [7:0] up_crc8 [LINES_PER_PAGE];
  page_header_unpack u_unpack (.i_blob(hdr_q), .o_generation(), .o_total_comp_size(),
                               .o_info(up_info), .o_crc8(up_crc8), .o_magic_ok(), .o_crc_ok());
  wire algo_e fl_algo = up_info[0].algo;
  wire [2:0]  fl_mode = up_info[0].mode;
  wire [6:0]  fl_size = 7'(up_info[0].size_minus1) + 7'd1;
  wire [7:0]  fl_crc8 = up_crc8[0];

  assign o_busy = (state != S_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin state<=S_IDLE; o_irq_decomp_err<=0; o_irq_hard_full<=0; end
    else begin
      o_irq_decomp_err<=0; o_irq_hard_full<=0;
      unique case (state)
        S_IDLE: if (i_alloc) begin
          addr_q<=i_addr; way_q<=i_victim_way; vtag_q<=i_victim_tag; vdata_q<=i_victim_data;
          state <= (i_victim_valid & i_victim_dirty) ? S_EV_COMP : S_L2P_RD;
        end
        S_EV_COMP: if (i_cmp_done) begin
          eca_q<=i_cmp_algo; ecm_q<=i_cmp_mode; ecs_q<=i_cmp_size; ecd_q<=i_cmp_data; ecc_q<=i_cmp_crc8;
          state<=S_EV_VL2P;
        end
        S_EV_VL2P: if (i_l2p_valid) begin    // 读 victim 页旧映射(为 free)
          old_valid_q<=i_l2p_entry.valid; old_ppa_q<=i_l2p_entry.ppa_ptr; old_size_q<=i_l2p_entry.size;
          state <= i_l2p_entry.valid ? S_EV_FREE : S_EV_ALLOC;
        end
        S_EV_FREE: state <= S_EV_ALLOC;       // free 旧槽(组合输出,1 拍)
        S_EV_ALLOC: begin
          if (i_alloc_ack)  begin new_ppa_q<=i_alloc_ppa; state<=S_EV_WR; end
          else if (i_alloc_fail) begin o_irq_hard_full<=1'b1; state<=S_DONE; end // 简化:真实走 reloc/压力
        end
        S_EV_WR:   if (i_ddrw_done) state<=S_EV_L2PWR;
        S_EV_L2PWR: state <= S_L2P_RD;        // 写 L2P(组合,1 拍)
        S_L2P_RD:  if (i_l2p_valid) state <= i_l2p_entry.valid ? S_DDR_RD : S_FILL_ZERO;
        S_DDR_RD:  if (i_ddrr_valid) begin hdr_q<=i_ddrr_header; cdata_q<=i_ddrr_cdata; state<=S_DECOMP; end
        S_DECOMP:  if (i_dec_done) begin
          line_q<=i_dec_line; if (i_dec_crc_err) o_irq_decomp_err<=1'b1; state<=S_FILL;
        end
        S_FILL_ZERO: if (i_fill_ready) state<=S_DONE;
        S_FILL:      if (i_fill_ready) state<=S_DONE;
        S_DONE: state<=S_IDLE;
        default: state<=S_IDLE;
      endcase
    end
  end

  always_comb begin
    // compress(evict)
    o_cmp_req  = (state==S_EV_COMP); o_cmp_line = vdata_q;
    // space_alloc:free 旧槽 / alloc 新槽
    o_free_req  = (state==S_EV_FREE);
    o_free_ppa  = old_ppa_q;
    o_free_size = old_size_q;
    o_alloc_req = (state==S_EV_ALLOC);
    o_alloc_size= footprint;
    // DDR 写(evict):真实 ppa
    o_ddrw_req    = (state==S_EV_WR);
    o_ddrw_ppa    = new_ppa_q;
    o_ddrw_header = ev_header;
    o_ddrw_cdata  = ecd_q;
    // L2P 写(evict)
    o_l2p_wr       = (state==S_EV_L2PWR);
    o_l2p_wr_page  = vict_page;
    o_l2p_wr_entry = '{rsvd:7'd0, algomix:8'd0, size:footprint, ppa_ptr:new_ppa_q,
                       state:ZC_COMPRESSED, valid:1'b1};
    // L2P 读:evict 阶段读 victim 页;fetch 阶段读 miss 页
    o_l2p_rd   = (state==S_EV_VL2P) || (state==S_L2P_RD);
    o_l2p_page = (state==S_EV_VL2P) ? vict_page : miss_page;
    // DDR 读(fetch)
    o_ddrr_req = (state==S_DDR_RD);
    o_ddrr_ppa = i_l2p_entry.ppa_ptr;
    // decompress
    o_dec_req  = (state==S_DECOMP);
    o_dec_algo = fl_algo; o_dec_mode = fl_mode; o_dec_size = fl_size;
    o_dec_data = cdata_q; o_dec_crc8 = fl_crc8;
    // fill
    o_fill_valid = (state==S_FILL) || (state==S_FILL_ZERO);
    o_fill_index = idx; o_fill_way = way_q; o_fill_tag = cache_tag(addr_q);
    o_fill_data  = (state==S_FILL_ZERO) ? '0 : line_q;
    o_fill_dirty = 1'b0;
  end
endmodule : mshr_alloc

`default_nettype wire
