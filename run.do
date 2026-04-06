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

# Clock / reset
add wave /*

run -all