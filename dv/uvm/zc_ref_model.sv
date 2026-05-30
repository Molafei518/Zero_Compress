// zc_ref_model.sv — 参考模型:透明内存语义 + DPI 压缩预测
//   端到端正确性基准:写后读必须一致(压缩对 Master 透明)。
//   DPI golden 用于压缩率/算法分布的统计对比(可选)。
class zc_ref_model extends uvm_component;
  `uvm_component_utils(zc_ref_model)

  // LA 页对齐的 line 存储(透明内存):key = addr
  bit [zc_pkg::LINE_BITS-1:0] mem [bit [zc_pkg::LA_ADDR_W-1:0]];

  // 统计
  longint unsigned tot_orig, tot_comp;

  function new(string name, uvm_component parent); super.new(name,parent); endfunction

  function void write_line(bit [zc_pkg::LA_ADDR_W-1:0] addr,
                           bit [zc_pkg::LINE_BITS-1:0] data,
                           bit [zc_pkg::LINE_BYTES-1:0] strb);
    bit [zc_pkg::LINE_BITS-1:0] cur = mem.exists(addr) ? mem[addr] : '0;
    for (int b = 0; b < zc_pkg::LINE_BYTES; b++)
      if (strb[b]) cur[b*8 +: 8] = data[b*8 +: 8];
    mem[addr] = cur;
    update_stats(cur);
  endfunction

  // 期望读数据(未写过的页 = 零填充语义,§3 Unmapped)
  function bit [zc_pkg::LINE_BITS-1:0] read_line(bit [zc_pkg::LA_ADDR_W-1:0] addr);
    return mem.exists(addr) ? mem[addr] : '0;
  endfunction

  // 用 DPI golden 累计压缩率(透明性不依赖它,仅统计)
  function void update_stats(bit [zc_pkg::LINE_BITS-1:0] line);
    byte unsigned barr[64];
    int algo, mode, size;
    for (int b = 0; b < 64; b++) barr[b] = line[b*8 +: 8];
    size = zc_compress(barr, algo, mode);
    tot_orig += 64;
    tot_comp += size;
  endfunction

  function void report_phase(uvm_phase phase);
    if (tot_comp != 0)
      `uvm_info("REF", $sformatf("golden compression ratio = %0.3f (orig=%0d comp=%0d)",
                real'(tot_orig)/real'(tot_comp), tot_orig, tot_comp), UVM_LOW)
  endfunction
endclass
