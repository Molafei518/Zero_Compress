// zc_scoreboard.sv — 端到端比对:读返回 == 参考模型写入(透明性)
`uvm_analysis_imp_decl(_axi)
class zc_scoreboard extends uvm_component;
  `uvm_component_utils(zc_scoreboard)
  uvm_analysis_imp_axi #(axi_seq_item, zc_scoreboard) axi_imp;
  zc_ref_model ref_m;
  int unsigned n_pass, n_fail;

  function new(string name, uvm_component parent);
    super.new(name,parent); axi_imp = new("axi_imp", this);
  endfunction

  // 来自 monitor 的完成事务
  function void write_axi(axi_seq_item tr);
    if (tr.is_write) begin
      ref_m.write_line(tr.addr, tr.wdata, tr.wstrb);
    end else begin
      bit [zc_pkg::LINE_BITS-1:0] exp = ref_m.read_line(tr.addr);
      if (tr.rdata === exp) begin
        n_pass++;
        `uvm_info("SCB", $sformatf("READ ok addr=%0h", tr.addr), UVM_HIGH)
      end else begin
        n_fail++;
        `uvm_error("SCB", $sformatf("READ MISMATCH addr=%0h exp=%0h got=%0h",
                                    tr.addr, exp, tr.rdata))
      end
    end
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SCB", $sformatf("pass=%0d fail=%0d", n_pass, n_fail), UVM_LOW)
    if (n_fail != 0) `uvm_error("SCB", "scoreboard had mismatches")
  endfunction
endclass
