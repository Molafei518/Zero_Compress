// axi_monitor.sv — 观测上游 AXI 完成的事务,广播到 scoreboard
class axi_monitor extends uvm_monitor;
  `uvm_component_utils(axi_monitor)
  virtual zc_axi_if vif;
  uvm_analysis_port #(axi_seq_item) ap;

  function new(string name, uvm_component parent);
    super.new(name,parent); ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual zc_axi_if)::get(this, "", "s_vif", vif))
      `uvm_fatal("AXI_MON", "no s_vif")
  endfunction

  task run_phase(uvm_phase phase);
    @(posedge vif.aresetn);
    forever begin
      axi_seq_item tr = axi_seq_item::type_id::create("tr");
      // TODO: 采样 AR/R 与 AW/W/B,组装完成事务后 ap.write(tr)
      @(posedge vif.aclk);
      // ap.write(tr);
    end
  endtask
endclass
