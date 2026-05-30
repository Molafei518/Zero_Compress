// axi_seq_item.sv — AXI 事务项(读/写,整 line 粒度)
class axi_seq_item extends uvm_sequence_item;
  rand bit                     is_write;
  rand bit [zc_pkg::LA_ADDR_W-1:0] addr;
  rand bit [zc_pkg::AXI_ID_W-1:0]  id;
  rand bit [7:0]               len;     // AXI burst len(beats-1)
  rand bit [2:0]               size;
  rand bit [zc_pkg::LINE_BITS-1:0] wdata;
  rand bit [zc_pkg::LINE_BYTES-1:0] wstrb;
  // 响应(monitor 回填)
  bit [zc_pkg::LINE_BITS-1:0]  rdata;
  bit [1:0]                    resp;

  constraint c_align { addr[5:0] == 6'b0; }      // 64B 对齐(单 line 默认)
  constraint c_len   { len inside {[0:15]}; size == 3'd5; } // ≤16 beat,32B/beat
  constraint c_strb  { is_write -> wstrb != '0; }

  `uvm_object_utils_begin(axi_seq_item)
    `uvm_field_int(is_write, UVM_ALL_ON)
    `uvm_field_int(addr,     UVM_ALL_ON)
    `uvm_field_int(id,       UVM_ALL_ON)
    `uvm_field_int(wdata,    UVM_ALL_ON)
    `uvm_field_int(rdata,    UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name="axi_seq_item"); super.new(name); endfunction
endclass
