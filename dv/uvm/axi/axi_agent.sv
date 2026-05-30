// axi_agent.sv — AXI agent(sequencer + driver + monitor)
typedef uvm_sequencer #(axi_seq_item) axi_sequencer;

class axi_agent extends uvm_agent;
  `uvm_component_utils(axi_agent)
  axi_sequencer sqr;
  axi_driver    drv;
  axi_monitor   mon;

  function new(string name, uvm_component parent); super.new(name,parent); endfunction

  function void build_phase(uvm_phase phase);
    mon = axi_monitor::type_id::create("mon", this);
    if (get_is_active() == UVM_ACTIVE) begin
      sqr = axi_sequencer::type_id::create("sqr", this);
      drv = axi_driver::type_id::create("drv", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    if (get_is_active() == UVM_ACTIVE)
      drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass
