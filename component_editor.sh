# A simple script to get the Component Editor going

cd hw

export QUARTUS_ROOTDIR=/home/c_espinoza/intelFPGA_lite/22.1std/quartus
export PATH="$QUARTUS_ROOTDIR/bin:$QUARTUS_ROOTDIR/sopc_builder/bin:$PATH"

qsys-edit soc_system.qsys
