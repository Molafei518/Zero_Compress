// ============================================================================
// zc_pkg.sv — DDR Cache+Compress IP 全局参数与类型冻结包
//
//   对应架构文档:cache_compress_ip_architecture.md §3/§5/§9/§12
//   本包是所有 RTL 模块的单一事实源(single source of truth):
//     - 综合期配置参数(默认值 = 出厂冻结值)
//     - 派生参数(由配置参数推导,禁止在别处重算)
//     - 数据结构 typedef(L2P Entry / Page Header 字段 / 各 FSM 状态枚举)
//     - 总线内部 ID 编码、IRQ 位定义
//
//   修改配置:覆盖 §1 的 localparam 即可,派生参数自动跟随。
//   ABI 级结构(L2P Entry / Page Header)修改需 rev 文档 02。
// ============================================================================
package zc_pkg;

  // ==========================================================================
  // 1. 综合期配置参数(默认 = 冻结值,见架构 §12)
  // ==========================================================================
  // -- 地址空间 --
  localparam int unsigned LA_ADDR_W   = 40;   // Master 逻辑地址位宽(申报空间)
  localparam int unsigned PPA_ADDR_W  = 32;   // IP 内部伪物理地址(= DDR 容量 4GB)
  localparam int unsigned DPA_ADDR_W  = 32;   // DDR 物理地址(本方案 PPA==DPA)

  // -- AXI --
  localparam int unsigned AXI_DATA_W  = 256;  // 上/下游 AXI 数据位宽(单 beat)
  localparam int unsigned AXI_ID_W    = 10;   // 上游 AXI ID 位宽
  localparam int unsigned AXI_LEN_W   = 8;    // AXI4 burst len
  localparam int unsigned AXI_SIZE_W  = 3;
  localparam int unsigned AXI_BURST_W = 2;

  // -- Cache --
  localparam int unsigned CACHE_BYTES = 128*1024; // Cache 总容量
  localparam int unsigned N_WAY       = 4;        // 路数
  localparam int unsigned LINE_BYTES  = 64;       // Cache Line 字节
  localparam int unsigned MSHR_DEPTH  = 8;        // Outstanding Miss 深度

  // -- Meta Cache(L2P + Page Header 共池)--
  localparam int unsigned META_BYTES      = 16*1024; // Meta Cache 容量
  localparam int unsigned META_N_WAY      = 2;
  localparam int unsigned L2P_BLOCK_BYTES = 64;      // 一个 L2P Block = 8 个 Entry

  // -- 元数据粒度 --
  localparam int unsigned PAGE_BYTES   = 4096; // L2P 映射粒度(= OS Page)
  localparam int unsigned HEADER_BYTES = 176;  // Page Header(文档 02 V2)

  // -- 容量 / 压力(默认值,运行时可经 APB 改)--
  localparam int unsigned CAP_RATIO_X100 = 150; // 1.50×
  localparam int unsigned SOFT_LOW_PCT   = 80;
  localparam int unsigned SOFT_HIGH_PCT  = 95;
  localparam int unsigned HARD_FULL_PCT  = 99;

  // -- Bypass / 重定位 / 性能 --
  localparam int unsigned N_BYPASS_REGION = 8;
  localparam int unsigned RELOC_FIFO_DEPTH = 8;  // 待处理 reloc 排队(文档 03 §5.4)
  localparam int unsigned N_PERF_CNT       = 32;

  // ==========================================================================
  // 2. 派生参数(禁止在别处重算,统一引用本包)
  // ==========================================================================
  localparam int unsigned BEAT_BYTES     = AXI_DATA_W/8;            // 32
  localparam int unsigned LINE_BITS      = LINE_BYTES*8;           // 512
  localparam int unsigned BEATS_PER_LINE = LINE_BYTES/BEAT_BYTES;  // 2
  localparam int unsigned BYTE_STRB_W    = AXI_DATA_W/8;           // wstrb

  // Cache 几何:总 Line 数 / 每路 Line 数 / set 数
  localparam int unsigned N_LINES   = CACHE_BYTES/LINE_BYTES;      // 2048
  localparam int unsigned N_SETS    = N_LINES/N_WAY;              // 512
  localparam int unsigned IDX_W     = $clog2(N_SETS);            // 9
  localparam int unsigned OFFSET_W  = $clog2(LINE_BYTES);        // 6
  localparam int unsigned TAG_W     = LA_ADDR_W - IDX_W - OFFSET_W; // 25
  localparam int unsigned WAY_W     = $clog2(N_WAY);             // 2
  localparam int unsigned PLRU_W    = N_WAY-1;                   // 3 (tree-pLRU)

  // 页内划分
  localparam int unsigned PAGE_OFFSET_W = $clog2(PAGE_BYTES);    // 12
  localparam int unsigned LINES_PER_PAGE= PAGE_BYTES/LINE_BYTES; // 64
  localparam int unsigned LINE_IDX_W    = $clog2(LINES_PER_PAGE);// 6  (页内 bits[11:6])
  localparam int unsigned LA_PAGE_W     = LA_ADDR_W-PAGE_OFFSET_W;//28 (LA 页号)

  localparam int unsigned MSHR_IDX_W = $clog2(MSHR_DEPTH);       // 3

  // 下游 ID:= 上游 ID + 3 bit 类别前缀(架构 §9.2)
  localparam int unsigned DS_ID_W = AXI_ID_W + 3;               // 13

  // ==========================================================================
  // 3. Page Header 常量(文档 02 V2,与 tools/page_header_codec.py 对齐)
  // ==========================================================================
  localparam logic [15:0] PAGE_MAGIC      = 16'hCC55;
  localparam int unsigned LINE_INFO_W     = 11;  // {algo[1:0],mode[2:0],size_minus1[5:0]}
  localparam int unsigned LINE_INFO_BITS  = LINE_INFO_W*LINES_PER_PAGE; // 704 = 88B
  localparam int unsigned LINE_CRC8_BITS  = 8*LINES_PER_PAGE;           // 512 = 64B
  localparam int unsigned PAGE_CRC_COV_B  = 172; // page_crc32 覆盖字节数(0x00-0x0B+0x10-0xAF)
  localparam logic [7:0]  CRC8_POLY       = 8'h1D; // SAE-J1850
  localparam logic [7:0]  CRC8_INIT       = 8'hFF;
  // 不可压退化页固定占用
  localparam int unsigned UNCOMP_SLOT_B   = PAGE_BYTES + HEADER_BYTES; // 4272

  // ==========================================================================
  // 4. 枚举与数据结构
  // ==========================================================================

  // -- 压缩算法 id(架构 §6.4)--
  typedef enum logic [1:0] {
    ALGO_BDI       = 2'b00,
    ALGO_ZERO      = 2'b01,
    ALGO_BYTEDELTA = 2'b10,
    ALGO_NONE      = 2'b11   // 不可压,原始 64B 直通
  } algo_e;

  // -- L2P Entry State(架构 §3.2.2)--
  typedef enum logic [2:0] {
    ZC_UNMAPPED      = 3'b000, // 零填充语义
    ZC_COMPRESSED    = 3'b001,
    ZC_UNCOMPRESSED  = 3'b010,
    ZC_BYPASS        = 3'b011, // NCA
    ZC_PENDING       = 3'b100, // 正在重定位
    ZC_ERROR         = 3'b101  // 压缩/解压故障
  } l2p_state_e;

  // -- L2P Entry(8 byte,LSB=valid;布局见附录 B.1)--
  typedef struct packed {
    logic [6:0]   rsvd;     // [63:57]
    logic [7:0]   algomix;  // [56:49]  4 算法 × 2 bit 占比档位(GC/统计)
    logic [12:0]  size;     // [48:36]  压缩后字节 0~4272
    logic [31:0]  ppa_ptr;  // [35:4]   64B 对齐 → 实际字节 = ppa_ptr<<6
    l2p_state_e   state;    // [3:1]
    logic         valid;    // [0]
  } l2p_entry_t;

  // -- 单条 Line 元信息(Page Header line_info 解包后)--
  typedef struct packed {
    logic [5:0] size_minus1; // 实际 size = +1,1~64
    logic [2:0] mode;
    algo_e      algo;
  } line_info_t; // 11 bit

  // -- Cache Tag Entry(架构 §5.2;ECC 由 tag_ecc 旁路携带)--
  typedef struct packed {
    logic [TAG_W-1:0] tag;
    logic             dirty;
    logic             valid;
  } tag_entry_t;

  // -- Cache 主流水阶段 --
  typedef enum logic [1:0] {
    PIPE_REQ  = 2'd0,
    PIPE_TAG  = 2'd1,
    PIPE_DATA = 2'd2,
    PIPE_RESP = 2'd3
  } pipe_stage_e;

  // -- MSHR 状态(架构 §5.4)--
  typedef enum logic [3:0] {
    MSHR_IDLE       = 4'd0,
    MSHR_L2P_LOOKUP = 4'd1,
    MSHR_EVICT_PEND = 4'd2,
    MSHR_COMP_PEND  = 4'd3,
    MSHR_ALLOC_PEND = 4'd4,
    MSHR_DDR_WRITE  = 4'd5,
    MSHR_FILL_REQ   = 4'd6,
    MSHR_FILL_DECOMP= 4'd7,
    MSHR_DONE       = 4'd8
  } mshr_state_e;

  // -- 整页重定位 FSM(文档 03 §2,9 状态)--
  typedef enum logic [3:0] {
    S_RELOC_IDLE          = 4'd0,
    S_RELOC_LOCK          = 4'd1,
    S_RELOC_COLLECT_PLAN  = 4'd2,
    S_RELOC_COLLECT_FETCH = 4'd3,
    S_RELOC_RECOMP        = 4'd4,
    S_RELOC_ALLOC         = 4'd5,
    S_RELOC_WRITE_NEW     = 4'd6,
    S_RELOC_COMMIT        = 4'd7,
    S_RELOC_DONE          = 4'd8
  } reloc_state_e;

  // -- 重定位触发源(文档 03 §1,优先级见 §6)--
  typedef enum logic [2:0] {
    RTRIG_NONE         = 3'd0,
    RTRIG_HEADER_REPAIR= 3'd1, // P0 数据完整性
    RTRIG_EVICT_OVF    = 3'd2, // P1
    RTRIG_WRITE_FAIL   = 3'd3, // P1
    RTRIG_GC_COMPACT   = 3'd4, // P3 可抢占
    RTRIG_GC_DEFRAG    = 3'd5  // P3 可抢占
  } reloc_trig_e;

  // -- 下游 ID 类别前缀(架构 §9.2,DS_ID = {class[2:0], sub_id})--
  typedef enum logic [2:0] {
    IDC_MASTER = 3'b000, // 直通 master id
    IDC_EVICT  = 3'b100,
    IDC_RELOC  = 3'b101,
    IDC_GC     = 3'b110,
    IDC_META   = 3'b111  // L2P / Header DMA
  } ds_id_class_e;

  // -- 地址解码后的请求类别(addr_decode 输出)--
  typedef enum logic [1:0] {
    PATH_NORMAL = 2'd0, // 走 Cache + 压缩
    PATH_BYPASS = 2'd1, // no-cache no-compress 区间
    PATH_NCA    = 2'd2  // Device/Strong-Order:跳 Cache,仍过压缩通路
  } req_path_e;

  // -- 容量水位等级(pressure_mon)--
  typedef enum logic [1:0] {
    WL_NORMAL    = 2'd0,
    WL_SOFT_LOW  = 2'd1, // 启动后台 GC
    WL_SOFT_HIGH = 2'd2, // IRQ_PRESSURE
    WL_HARD_FULL = 2'd3  // IRQ_HARD_FULL
  } waterlevel_e;

  // ==========================================================================
  // 5. 中断位(INT_STATUS,文档 04 §3)
  // ==========================================================================
  localparam int unsigned IRQ_PRESSURE   = 0;
  localparam int unsigned IRQ_HARD_FULL  = 1;
  localparam int unsigned IRQ_DECOMP_ERR = 2;
  localparam int unsigned IRQ_GC_DONE    = 3;
  localparam int unsigned N_IRQ          = 4;

  // ==========================================================================
  // 6. 地址分解辅助函数(纯组合,供各模块统一调用)
  // ==========================================================================
  function automatic logic [LA_PAGE_W-1:0] la_page_num(input logic [LA_ADDR_W-1:0] la);
    return la[LA_ADDR_W-1:PAGE_OFFSET_W];
  endfunction

  function automatic logic [LINE_IDX_W-1:0] la_line_idx(input logic [LA_ADDR_W-1:0] la);
    return la[PAGE_OFFSET_W-1:OFFSET_W];
  endfunction

  function automatic logic [IDX_W-1:0] cache_index(input logic [LA_ADDR_W-1:0] la);
    return la[OFFSET_W +: IDX_W];
  endfunction

  function automatic logic [TAG_W-1:0] cache_tag(input logic [LA_ADDR_W-1:0] la);
    return la[LA_ADDR_W-1 -: TAG_W];
  endfunction

  // PPA Ptr(64B 对齐)→ 字节地址
  function automatic logic [PPA_ADDR_W-1:0] ppa_to_byte(input logic [31:0] ppa_ptr);
    return {ppa_ptr[PPA_ADDR_W-1-6:0], 6'b0};
  endfunction

endpackage : zc_pkg
