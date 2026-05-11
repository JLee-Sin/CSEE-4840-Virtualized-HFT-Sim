# A simple script to compile vga_ball.sv 

# Make sure you are in the correc dir
cd hw

# Make sure can get access to quartus
export QUARTUS_ROOTDIR=/home/c_espinoza/intelFPGA_lite/22.1std/quartus
export PATH="$QUARTUS_ROOTDIR/bin:$QUARTUS_ROOTDIR/sopc_builder/bin:$PATH"

# Compile 
make quartus

# Covert oc_system.sof to oc_system.rbf
make rbf

# EXTRA
# Add sopc2dts and dtc
export PATH=/home/c_espinoza/intelFPGA/20.1/embedded/host_tools/altera/device_tree:$PATH
which sopc2dts

# Generate soc_system.dtb
make dtb