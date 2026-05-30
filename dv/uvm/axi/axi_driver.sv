// axi_driver.sv — 驱动上游 AXI(IP 的 slave 口),master BFM
//   骨架:AW/W/AR 通道时序;完整 burst/握手 TODO。经 virtual interface 操作 zc_axi_if。
class axi_driver extends uvm_driver #(axi_seq_item);
  `uvm_component_utils(axi_driver)
  virtual zc_axi_if vif;

  function new(string name, uvm_component parent); super.new(name,parent); endfunction

  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual zc_axi_if)::get(this, "", "s_vif", vif))
      `uvm_fatal("AXI_DRV", "no s_vif")
  endfunction

  task run_phase(uvm_phase phase);
    @(posedge vif.aresetn);
    forever begin
      axi_seq_item tr;
      seq_item_port.get_next_item(tr);
      if (tr.is_write) drive_write(tr); else drive_read(tr);
      seq_item_port.item_done();
    end
  endtask

  task drive_write(axi_seq_item tr);
    // TODO: AW 握手 + W beats(BEATS_PER_LINE)+ 等 B
    @(posedge vif.aclk);
    `uvm_info("AXI_DRV", $sformatf("WRITE addr=%0h", tr.addr), UVM_HIGH)
  endtask

  task drive_read(axi_seq_item tr);
    // TODO: AR 握手 + 收 R beats → tr.rdata
    @(posedge vif.aclk);
    `uvm_info("AXI_DRV", $sformatf("READ addr=%0h", tr.addr), UVM_HIGH)
  endtask
endclass
