// zc_env.sv — 顶层环境:AXI agent + ref_model + scoreboard
class zc_env extends uvm_env;
  `uvm_component_utils(zc_env)
  axi_agent     agent;
  zc_ref_model  ref_m;
  zc_scoreboard scb;

  function new(string name, uvm_component parent); super.new(name,parent); endfunction

  function void build_phase(uvm_phase phase);
    agent = axi_agent::type_id::create("agent", this);
    ref_m = zc_ref_model::type_id::create("ref_m", this);
    scb   = zc_scoreboard::type_id::create("scb", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    scb.ref_m = ref_m;
    agent.mon.ap.connect(scb.axi_imp);
  endfunction
endclass
