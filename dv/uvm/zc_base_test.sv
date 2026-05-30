// zc_base_test.sv — 基础测试 + 冒烟/随机派生
class zc_base_test extends uvm_test;
  `uvm_component_utils(zc_base_test)
  zc_env env;
  function new(string name, uvm_component parent); super.new(name,parent); endfunction

  function void build_phase(uvm_phase phase);
    env = zc_env::type_id::create("env", this);
  endfunction

  task run_phase(uvm_phase phase);
    seq_smoke seq = seq_smoke::type_id::create("seq");
    phase.raise_objection(this);
    seq.start(env.agent.sqr);
    phase.drop_objection(this);
  endtask
endclass

class test_rand_rw extends zc_base_test;
  `uvm_component_utils(test_rand_rw)
  function new(string name, uvm_component parent); super.new(name,parent); endfunction
  task run_phase(uvm_phase phase);
    seq_rand_rw seq = seq_rand_rw::type_id::create("seq");
    phase.raise_objection(this);
    seq.start(env.agent.sqr);
    phase.drop_objection(this);
  endtask
endclass
