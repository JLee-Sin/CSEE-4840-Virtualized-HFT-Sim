# This script compiles the device driver and bouncing program,
# installs the kernel module, verify that it works, and
# runs the bounding program.

# Pull most recent changes from repo
cd ~/csee4840/CSEE-4840-Virtualized-HFT-Sim
git pull


# Compile, check and runs
cd ~/csee4840/CSEE-4840-Virtualized-HFT-Sim/sw
make
insmod HFT_drivers.ko
lsmod
./HFT_harness
rmmod HFT_drivers
