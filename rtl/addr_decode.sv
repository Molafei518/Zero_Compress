// ============================================================================
// addr_decode.sv — 路径判定 NORMAL / BYPASS / NCA
//   设计文档:docs/rtl/02_addr_decode.md   架构:§2.4 / §10.3
// ============================================================================
`default_nettype none

module addr_decode
  import zc_pkg::*;
(
  input  wire                   clk,
  input  wire                   rst_n,

  // (A) <- req_buffer
  input  wire                   i_req_valid,
  output wire                   o_req_ready,
  input  wire [LA_ADDR_W-1:0]   i_addr,
  input  wire [AXI_ID_W-1:0]    i_id,
  input  wire                   i_is_write,
  input  wire [2:0]             i_prot,
  input  wire [3:0]             i_cache,
  input  wire [LINE_BITS-1:0]   i_wdata,
  input  wire [LINE_BYTES-1:0]  i_wstrb,
  input  wire [OFFSET_W-1:0]    i_offset,

  // 配置 <- apb_cfg
  input  wire [LA_ADDR_W-1:0]   i_cfg_bypass_start [N_BYPASS_REGION],
  input  wire [LA_ADDR_W-1:0]   i_cfg_bypass_end   [N_BYPASS_REGION],
  input  wire [1:0]             i_cfg_nca_mode,

  // (B) -> cache_pipe_ctrl
  output logic                  o_req_valid,
  input  wire                   i_req_ready,
  output logic [LA_ADDR_W-1:0]  o_addr,
  output logic [AXI_ID_W-1:0]   o_id,
  output logic                  o_is_write,
  output logic [LINE_BITS-1:0]  o_wdata,
  output logic [LINE_BYTES-1:0] o_wstrb,
  output logic [OFFSET_W-1:0]   o_offset,
  output req_path_e             o_path
);

  // 流控:1 拍寄存,下游 ready 时可收
  wire fire_in = i_req_valid & o_req_ready;
  assign o_req_ready = i_req_ready | ~o_req_valid;

  // ---- 组合判定 ----
  logic in_bypass;
  always_comb begin
    in_bypass = 1'b0;
    for (int k = 0; k < N_BYPASS_REGION; k++)
      if (i_addr >= i_cfg_bypass_start[k] && i_addr < i_cfg_bypass_end[k])
        in_bypass = 1'b1;
  end

  wire is_secure = ~i_prot[1];        // AxPROT[1]: 0=Secure
  wire is_device = ~i_cache[1];       // 简化:非 Modifiable ≈ Device

  req_path_e path_c;
  always_comb begin
    if (in_bypass)                              path_c = PATH_BYPASS;
    else if (is_secure && i_cfg_nca_mode == 0)  path_c = PATH_BYPASS;
    else if (is_device || (is_secure && i_cfg_nca_mode == 1)) path_c = PATH_NCA;
    else                                        path_c = PATH_NORMAL;
  end

  // ---- 寄一拍 ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) o_req_valid <= 1'b0;
    else if (i_req_ready)  o_req_valid <= i_req_valid;
  end

  always_ff @(posedge clk) begin
    if (fire_in) begin
      o_addr     <= i_addr;
      o_id       <= i_id;
      o_is_write <= i_is_write;
      o_wdata    <= i_wdata;
      o_wstrb    <= i_wstrb;
      o_offset   <= i_offset;
      o_path     <= path_c;
    end
  end

endmodule : addr_decode

`default_nettype wire
