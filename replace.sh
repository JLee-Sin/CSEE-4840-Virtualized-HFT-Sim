# This is a simple script that replaces the soc_system.rbf and 
# soc_system.dtb files to the sd card’s boot partition.

# Make sure to bring up the ethernet connection
ifup eth0

# Pull the latest updated from Github
cd ~/csee4840/CSEE-4840-Virtualized-HFT-Sim
git pull 

# Mount boot sd card and remove old files
echo "Mounting SD card and removing old files"
mount /dev/mmcblk0p1 /mnt 
cd /mnt
rm soc_system.rbf 
rm soc_system.dtb

# Copy the new files
echo "Copying new files"
cd ~/csee4840/CSEE-4840-Virtualized-HFT-Sim/hw/output_files
cp soc_system.rbf /mnt
cd ~/csee4840/CSEE-4840-Virtualized-HFT-Sim/hw
cp soc_system.dtb /mnt

# Reboot
echo "Rebooting"
reboot