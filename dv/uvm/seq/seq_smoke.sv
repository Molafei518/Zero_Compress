// seq_smoke.sv — 冒烟序列:写一批 line 再读回(端到端透明性)
class seq_smoke extends uvm_sequence #(axi_seq_item);
  `uvm_object_utils(seq_smoke)
  rand int unsigned n_lines = 64;
  function new(string name="seq_smoke"); super.new(name); endfunction

  task body();
    bit [zc_pkg::LA_ADDR_W-1:0] addrs [$];
    // 写阶段
    repeat (n_lines) begin
      axi_seq_item w = axi_seq_item::type_id::create("w");
      assert(w.randomize() with { is_write == 1; });
      addrs.push_back(w.addr);
      start_item(w); finish_item(w);
    end
    // 读回阶段(同地址)
    foreach (addrs[i]) begin
      axi_seq_item r = axi_seq_item::type_id::create("r");
      assert(r.randomize() with { is_write == 0; addr == addrs[i]; });
      start_item(r); finish_item(r);
    end
  endtask
endclass

// 随机读写混合序列
class seq_rand_rw extends uvm_sequence #(axi_seq_item);
  `uvm_object_utils(seq_rand_rw)
  rand int unsigned n = 200;
  function new(string name="seq_rand_rw"); super.new(name); endfunction
  task body();
    repeat (n) begin
      axi_seq_item t = axi_seq_item::type_id::create("t");
      assert(t.randomize());
      start_item(t); finish_item(t);
    end
  endtask
endclass
