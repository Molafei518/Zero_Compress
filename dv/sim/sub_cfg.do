# sub_cfg.do — apb_cfg + pressure_mon 子系统(从 dv/sim/ 执行)
#   vsim -c -do sub_cfg.do
vlib work
vlog -sv ../../rtl/zc_pkg.sv ../../rtl/pressure_mon.sv ../../rtl/apb_cfg.sv ../uvm/tb_sub_cfg.sv
vsim -c work.tb_sub_cfg
run -all
quit -f
