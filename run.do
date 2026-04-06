transcript on
set NoQuitOnFinish 1

# ============================================================
# Clean previous library
# ============================================================
if {[file exists work]} {
    vdel -lib work -all
}

vlib work
vmap work work

# ============================================================
# Map libraries
# ============================================================
vmap uvm_lib /opt/fpga/uvm-1.2/uvm_lib
vmap xpm ./simlib/xpm

# ============================================================
# Compile DUT (VHDL)
# ============================================================
vcom src/rtl/bram_image_streamer.vhd
vcom src/rtl/ddr4_frame_buffer.vhd

# ============================================================
# Compile additional sources
# ============================================================
vlog /opt/fpga/amd/2025.2/data/verilog/src/glbl.v

# ============================================================
# Compile Testbench (SystemVerilog)
# ============================================================
vlog -sv \
     -L uvm_lib \
     +incdir+src/tb \
     +incdir+/opt/fpga/uvm-1.2/src \
     src/tb/ddr4_frame_buffer_tb.sv

# ============================================================
# Simulate
# ============================================================
vsim -voptargs=+acc \
     -L uvm_lib \
     -dpicpppath /usr/bin/gcc \
     work.ddr4_frame_buffer_tb \
     work.glbl

# ============================================================
# Wave + Log
# ============================================================
log -r /*

# Clock / reset / switches

add wave /ddr4_frame_buffer_tb/hdmi_clk
add wave /ddr4_frame_buffer_tb/mig_clk
add wave /ddr4_frame_buffer_tb/hdmi_resetn
add wave /ddr4_frame_buffer_tb/mig_rst
add wave /ddr4_frame_buffer_tb/init_calib_complete
add wave /ddr4_frame_buffer_tb/sw_save

# AXI Stream
add wave -radix hexadecimal /ddr4_frame_buffer_tb/s_axis_tdata
add wave /ddr4_frame_buffer_tb/s_axis_tvalid
add wave /ddr4_frame_buffer_tb/s_axis_tlast
add wave /ddr4_frame_buffer_tb/s_axis_tuser
add wave /ddr4_frame_buffer_tb/s_axis_tready

# MIG interface
add wave /ddr4_frame_buffer_tb/app_addr
add wave /ddr4_frame_buffer_tb/app_cmd
add wave /ddr4_frame_buffer_tb/app_en
add wave -radix hexadecimal /ddr4_frame_buffer_tb/app_wdf_data
add wave /ddr4_frame_buffer_tb/app_wdf_end
add wave /ddr4_frame_buffer_tb/app_wdf_wren
add wave /ddr4_frame_buffer_tb/app_rdy
add wave /ddr4_frame_buffer_tb/app_wdf_rdy

# Debug
add wave /ddr4_frame_buffer_tb/wr_count


run -all