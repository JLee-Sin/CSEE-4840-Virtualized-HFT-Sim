# Pull most recent changes from repo
cd ~/csee4840/CSEE-4840-Virtualized-HFT-Sim
git pull

# Compile, check and run
cd ~/csee4840/CSEE-4840-Virtualized-HFT-Sim/sw
make

# Only insert if not already loaded
if ! lsmod | grep -q '^HFT_drivers '; then
    insmod HFT_drivers.ko
fi

lsmod
./HFT_harness

# Leave loaded for now
# rmmod HFT_drivers