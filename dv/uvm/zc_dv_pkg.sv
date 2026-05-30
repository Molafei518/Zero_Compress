// ============================================================================
// zc_dv_pkg.sv — 验证环境包(UVM + DPI-C golden 导入 + 类包含)
//   DPI golden 实现:dv/dpi/zc_dpi.c(Python golden 的 C 镜像)
//   构建见 dv/sim/。
// ============================================================================
package zc_dv_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import zc_pkg::*;

  // ---- DPI-C golden(对接 dv/dpi/zc_dpi.c)----
  // tie-break: Zero > ByteDelta > BDI(与 compress_eval.py / compress_top.sv 一致)
  import "DPI-C" function int           zc_compress(input byte unsigned line[64],
                                                    output int algo, output int mode);
  import "DPI-C" function byte unsigned zc_crc8   (input byte unsigned data[64], input int len);
  import "DPI-C" function int unsigned  zc_crc32  (input byte unsigned data[],   input int len);

  // ---- 类包含 ----
  `include "axi/axi_seq_item.sv"
  `include "axi/axi_driver.sv"
  `include "axi/axi_monitor.sv"
  `include "axi/axi_agent.sv"
  `include "zc_ref_model.sv"
  `include "zc_scoreboard.sv"
  `include "zc_env.sv"
  `include "seq/seq_smoke.sv"
  `include "zc_base_test.sv"
endpackage : zc_dv_pkg
