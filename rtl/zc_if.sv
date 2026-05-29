// ============================================================================
// zc_if.sv — DDR Cache+Compress IP 接口定义(AXI4 上/下游 + APB 配置)
//
//   对应架构文档 §9。用 SystemVerilog interface + modport 表达,
//   便于例化与连线;综合前若工具不支持 interface 端口,可由脚本展平。
//
//   - zc_axi_if  : 通用 AXI4(参数化 ID/ADDR/DATA 宽度)
//                  上游:Arbiter(master) → IP(slave)
//                  下游:IP(master) → Scheduler(slave)
//   - zc_apb_if  : APB 配置/状态寄存器(OS ↔ IP)
// ============================================================================

interface zc_axi_if #(
  parameter int unsigned ADDR_W = 40,
  parameter int unsigned DATA_W = 256,
  parameter int unsigned ID_W   = 10
) (
  input logic aclk,
  input logic aresetn
);
  localparam int unsigned STRB_W = DATA_W/8;

  // -- AR: Read Address --
  logic              arvalid, arready;
  logic [ID_W-1:0]   arid;
  logic [ADDR_W-1:0] araddr;
  logic [7:0]        arlen;
  logic [2:0]        arsize;
  logic [1:0]        arburst;
  logic [3:0]        arcache;
  logic [2:0]        arprot;
  logic [3:0]        arqos;
  logic [3:0]        arregion;
  logic              arlock;

  // -- R: Read Data --
  logic              rvalid, rready;
  logic [ID_W-1:0]   rid;
  logic [DATA_W-1:0] rdata;
  logic [1:0]        rresp;   // OKAY / SLVERR(压力 / CRC 错)
  logic              rlast;

  // -- AW: Write Address --
  logic              awvalid, awready;
  logic [ID_W-1:0]   awid;
  logic [ADDR_W-1:0] awaddr;
  logic [7:0]        awlen;
  logic [2:0]        awsize;
  logic [1:0]        awburst;
  logic [3:0]        awcache;
  logic [2:0]        awprot;
  logic [3:0]        awqos;

  // -- W: Write Data --
  logic              wvalid, wready;
  logic [DATA_W-1:0] wdata;
  logic [STRB_W-1:0] wstrb;
  logic              wlast;

  // -- B: Write Response --
  logic              bvalid, bready;
  logic [ID_W-1:0]   bid;
  logic [1:0]        bresp;

  // IP 作为从设备(上游:面向 Arbiter)
  modport slave (
    input  aclk, aresetn,
    input  arvalid, arid, araddr, arlen, arsize, arburst, arcache, arprot, arqos, arregion, arlock,
    output arready,
    output rvalid, rid, rdata, rresp, rlast,
    input  rready,
    input  awvalid, awid, awaddr, awlen, awsize, awburst, awcache, awprot, awqos,
    output awready,
    input  wvalid, wdata, wstrb, wlast,
    output wready,
    output bvalid, bid, bresp,
    input  bready
  );

  // IP 作为主设备(下游:面向 Scheduler/DDR)
  modport master (
    input  aclk, aresetn,
    output arvalid, arid, araddr, arlen, arsize, arburst, arcache, arprot, arqos, arregion, arlock,
    input  arready,
    input  rvalid, rid, rdata, rresp, rlast,
    output rready,
    output awvalid, awid, awaddr, awlen, awsize, awburst, awcache, awprot, awqos,
    input  awready,
    output wvalid, wdata, wstrb, wlast,
    input  wready,
    input  bvalid, bid, bresp,
    output bready
  );
endinterface : zc_axi_if


interface zc_apb_if #(
  parameter int unsigned ADDR_W = 12,
  parameter int unsigned DATA_W = 32
) (
  input logic pclk,
  input logic presetn
);
  logic              psel;
  logic              penable;
  logic              pwrite;
  logic [ADDR_W-1:0] paddr;
  logic [DATA_W-1:0] pwdata;
  logic [DATA_W-1:0] prdata;
  logic              pready;
  logic              pslverr;

  // IP 作为 APB 从设备
  modport slave (
    input  pclk, presetn,
    input  psel, penable, pwrite, paddr, pwdata,
    output prdata, pready, pslverr
  );

  modport master (
    input  pclk, presetn,
    output psel, penable, pwrite, paddr, pwdata,
    input  prdata, pready, pslverr
  );
endinterface : zc_apb_if
