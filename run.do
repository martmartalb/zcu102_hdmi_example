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
# Map precompiled UVM library (optional)
# ============================================================
vmap uvm_lib /opt/fpga/uvm-1.2/uvm_lib

# ============================================================
# Compile DUT (VHDL)
# ============================================================
vcom src/rtl/bram_image_streamer.vhd

# ============================================================
# Compile Testbench (SystemVerilog)
# ============================================================
vlog -sv \
     -L uvm_lib \
     +incdir+src/tb \
     +incdir+/opt/fpga/uvm-1.2/src \
     src/tb/bram_image_streamer_tb.sv

# ============================================================
# Simulate
# ============================================================
vsim -voptargs=+acc \
     -L uvm_lib \
     -dpicpppath /usr/bin/gcc \
     work.bram_image_streamer_tb

# ============================================================
# Wave + Log
# ============================================================
log -r /*

# Clock / reset
add wave /bram_image_streamer_tb/aclk
add wave /bram_image_streamer_tb/aresetn

# AXI Stream
add wave /bram_image_streamer_tb/tvalid
add wave /bram_image_streamer_tb/tready
add wave /bram_image_streamer_tb/tdata
add wave /bram_image_streamer_tb/tlast
add wave /bram_image_streamer_tb/tuser

run -all